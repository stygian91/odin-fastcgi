package fcgi

import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:strconv"
import "core:strings"

import "../config"
import t "../types"

Error :: t.Error
Fcgi_Error :: t.Fcgi_Error
Serialize_Error :: t.Serialize_Error
Request :: t.Request
Header :: t.Header
Record_Type :: t.Record_Type
Record :: t.Record
Body :: t.Body
Begin_Request_Body :: t.Begin_Request_Body
Request_Flag :: t.Request_Flag
Role :: t.Role
End_Request_Body :: t.End_Request_Body
Raw_Body :: t.Raw_Body
Protocol_Status :: t.Protocol_Status
FCGI_MAX_CONNS :: t.FCGI_MAX_CONNS
FCGI_MAX_REQS :: t.FCGI_MAX_REQS
FCGI_MPXS_CONNS :: t.FCGI_MPXS_CONNS
ALLOWED_FCGI_GET_VALUES :: t.ALLOWED_FCGI_GET_VALUES
Unknown_Type_Body :: t.Unknown_Type_Body
Http_Header :: t.Http_Header
Response :: t.Response
On_Request :: t.On_Request

VERSION :: 1

@(private)
CONTENT_BUF_SIZE :: (1 << 16) - 1

@(private)
CONTENT_BUF := [CONTENT_BUF_SIZE]u8{}

@(private)
PADDING_BUF := [255]u8{}

RWC :: io.Read_Write_Closer

PARAMS_INITIAL_RESERVE :: 40

on_client_accepted :: proc(client: RWC, alloc: mem.Allocator, on_request: On_Request) {
	context.allocator = alloc

	cleanup :: proc(client: RWC, alloc: mem.Allocator, keep: bool) {
		if !keep {io.close(client)}
		io.flush(client)
		mem.free_all(alloc)
	}

	for {
		keep := process_request(client, alloc, on_request)
		cleanup(client, alloc, keep)
		if !keep {break}
	}
}

process_request :: proc(
	client: RWC,
	alloc: mem.Allocator,
	on_request: On_Request,
) -> (
	keep: bool,
) {
	params, p_alloc_err := make(map[string]string, PARAMS_INITIAL_RESERVE)
	if p_alloc_err != nil {
		log.errorf("Allocation error while creating params map: %s", p_alloc_err)
		return
	}

	request := Request {
		// we preallocate the size based on rough estimate of how many params are usually in a request
		// the estimate is based on observation of a request sent from nginx
		// the map can grow if need be
		params = params,
	}

	for {
		done, read_err := read_record_into_request(client, &request)
		if read_err != nil {
			log.errorf("Error while reading record into request: %s", read_err)
			// TODO: disambiguate errors and add more info to log
			// TODO: sending any potential responses back to the web server
			return
		}

		if done {break}
	}

	if request.is_get_values {
		if e := send_get_value_results(client, request); e != nil {
			log.errorf("Error while sending Get_Value_Results: %s", e)
		} else {
			log.info("Sent Get_Value_Results")
		}

		return
	}

	response := on_request(&request)
	if response.status == .None {
		response.status = .Ok
	}

	if e := send_stdout(client, request.id, &response); e != nil {
		log.errorf("error in send_stdout: %s", e)
		return
	}

	if e := send_end_request(client, request.id); e != nil {
		log.errorf("error in send_end_request: %s", e)
		return
	}

	keep = .Keep_Conn in request.flags
	return
}

@(require_results)
read_record_into_request :: proc(client: RWC, req: ^Request) -> (done: bool, err: Error) {
	header: Header
	_ = io.read_ptr(client, &header, size_of(Header)) or_return
	content_len := int(combine_u16(header.content_length_b1, header.content_length_b0))

	defer if header.padding_length > 0 {
		rem := int(header.padding_length)
		if n2, e := io.read_full(client, PADDING_BUF[:rem]); e != nil {
			log.errorf("error while reading padding: %s; read n bytes: %d", e, n2)
		}
	}

	#partial switch header.type {
	case .Begin_Request:
		validate_content_length(content_len, size_of(Begin_Request_Body)) or_return
		b: Begin_Request_Body
		_ = io.read_ptr(client, &b, content_len) or_return
		req.id = combine_u16(header.request_id_b1, header.request_id_b0)
		// the protocol uses 2 bytes for the roles but there are currently only 3 roles
		req.role = cast(Role)b.role_b0
		req.flags = b.flags

	case .Params:
		buf := make([dynamic]u8, content_len) or_return
		_ = io.read_full(client, buf[:]) or_return
		parse_params(buf[:], &req.params)

	case .Stdin:
		buf := make([dynamic]u8, content_len) or_return
		_ = io.read_full(client, buf[:]) or_return
		old_len := len(req.stdin)
		resize(&req.stdin, old_len + content_len) or_return
		copy(req.stdin[old_len:], buf[:])

	case .Get_Values:
		buf := make([dynamic]u8, content_len) or_return
		_ = io.read_full(client, buf[:]) or_return
		parse_params(buf[:], &req.params)
		done = true

	case:
		_ = io.read_full(client, CONTENT_BUF[:content_len]) or_return
		err = .Unknown_Record_Type
	}

	if header.type == .Stdin && content_len == 0 {
		done = true
	}

	return
}

send_get_value_results :: proc(client: RWC, req: Request) -> (err: Error) {
	res_values := map[string]string{}

	buf := [10]u8{}
	if FCGI_MAX_REQS in req.params {
		res_values[FCGI_MAX_REQS] = strconv.itoa(buf[:], config.GLOBAL_CONFIG.worker_count)
	}

	if FCGI_MPXS_CONNS in req.params {
		res_values[FCGI_MPXS_CONNS] = "0"
	}

	if FCGI_MAX_CONNS in req.params {
		res_values[FCGI_MAX_CONNS] = "1"
	}

	header := Header {
		version = VERSION,
		type    = .Get_Values_Result,
	}

	header.request_id_b1, header.request_id_b0 = split_u16(req.id)

	content_builder: strings.Builder
	serialize_map(&content_builder, res_values) or_return

	content_len := len(content_builder.buf)
	header.content_length_b1, header.content_length_b0 = split_u16(u16(content_len))

	_ = io.write_ptr(client, &header, size_of(Header)) or_return
	_ = io.write_full(client, content_builder.buf[:]) or_return

	return
}

@(require_results)
send_headers :: proc(client: RWC, req_id: u16, response: ^Response) -> (err: Error) {
	req_id_b1, req_id_b0 := split_u16(req_id)

	h := Header {
		request_id_b1 = req_id_b1,
		request_id_b0 = req_id_b0,
		version       = VERSION,
		type          = .Stdout,
	}

	hb: strings.Builder
	defer delete(hb.buf)

	fmt.sbprintf(&hb, "Status: %d\r\n", response.status)

	for header in response.headers {
		key, _ := remove_new_lines(header.key, context.allocator)
		is_valid_header_name(key) or_continue

		val, _ := remove_new_lines(header.value, context.allocator)
		fmt.sbprintf(&hb, "%s: %s\r\n", key, val)
	}
	strings.write_string(&hb, "\r\n")

	h_len := len(hb.buf)
	chunk_count := h_len / CONTENT_BUF_SIZE
	if h_len % CONTENT_BUF_SIZE > 0 {
		chunk_count += 1
	}

	for i in 0 ..< chunk_count {
		chunk_start := i * CONTENT_BUF_SIZE
		chunk_end := chunk_start + CONTENT_BUF_SIZE
		if chunk_end > h_len {
			chunk_end = h_len
		}

		chunk := hb.buf[chunk_start:chunk_end]
		h.content_length_b1, h.content_length_b0 = split_u16(u16(len(chunk)))
		_ = io.write_ptr(client, &h, size_of(h)) or_return
		_ = io.write_full(client, chunk) or_return

		log.debugf("sent header chunk #%d of size: %d", i, len(chunk))
	}

	return
}

@(require_results)
send_stdout :: proc(client: RWC, req_id: u16, response: ^Response) -> (err: Error) {
	req_id_b1, req_id_b0 := split_u16(req_id)

	h := Header {
		request_id_b1 = req_id_b1,
		request_id_b0 = req_id_b0,
		version       = VERSION,
		type          = .Stdout,
	}

	send_headers(client, req_id, response) or_return

	chunk_count := len(response.body) / CONTENT_BUF_SIZE
	if len(response.body) % CONTENT_BUF_SIZE > 0 {
		chunk_count += 1
	}

	for i in 0 ..< chunk_count {
		chunk_start := i * CONTENT_BUF_SIZE
		chunk_end := chunk_start + CONTENT_BUF_SIZE
		if chunk_end > len(response.body) {
			chunk_end = len(response.body)
		}

		chunk := response.body[chunk_start:chunk_end]
		h.content_length_b1, h.content_length_b0 = split_u16(u16(len(chunk)))
		_ = io.write_ptr(client, &h, size_of(h)) or_return
		_ = io.write_full(client, chunk) or_return

		log.debugf("sent body chunk #%d of size: %d", i, len(chunk))
	}

	h.content_length_b1, h.content_length_b0 = 0, 0
	_ = io.write_ptr(client, &h, size_of(h)) or_return

	return
}

send_end_request :: proc(
	client: RWC,
	req_id: u16,
	protcol_status: Protocol_Status = .Request_Complete,
) -> (
	err: Error,
) {
	req_id_b1, req_id_b0 := split_u16(req_id)

	header_out := Header {
		version           = VERSION,
		request_id_b1     = req_id_b1,
		request_id_b0     = req_id_b0,
		type              = .End_Request,
		content_length_b0 = u8(size_of(End_Request_Body)),
	}
	body := End_Request_Body {
		protocol_status = protcol_status,
	}

	_ = io.write_ptr(client, &header_out, size_of(Header)) or_return
	_ = io.write_ptr(client, &body, size_of(End_Request_Body)) or_return

	return
}

send_unkown_type :: proc(client: RWC, req_id: u16, type: Record_Type) -> (err: Error) {
	req_id_b1, req_id_b0 := split_u16(req_id)

	header_out := Header {
		version           = VERSION,
		type              = .Unknown_Type,
		request_id_b1     = req_id_b1,
		request_id_b0     = req_id_b0,
		content_length_b0 = size_of(Unknown_Type_Body),
	}

	body := Unknown_Type_Body {
		type = type,
	}

	_ = io.write_ptr(client, &header_out, size_of(header_out)) or_return
	_ = io.write_ptr(client, &body, size_of(body)) or_return

	return
}
