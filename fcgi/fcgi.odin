package fcgi

import "core:mem"
import "core:io"
import vmem "core:mem/virtual"
import "core:log"
import "core:strconv"
import "core:strings"

import "../config"

VERSION :: 1

@(private)
CONTENT_BUF_SIZE :: 1 << 16

@(private)
CONTENT_BUF := [CONTENT_BUF_SIZE]u8{}

@(private)
PADDING_BUF := [256]u8{}

RWC :: io.Read_Write_Closer

PARAMS_INITIAL_RESERVE :: 40

on_client_accepted :: proc(client: RWC, alloc: mem.Allocator) {
	context.allocator = alloc

	defer {
		io.close(client)
		io.flush(client)
		mem.free_all(alloc)
	}

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
			// TODO: handle memory errors
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

	log.infof("Received request with URI: %s", request.params["REQUEST_URI"] or_else "/")

	body_str := strings.clone_from_bytes(request.stdin[:])
	sb: strings.Builder
	strings.write_string(&sb, "Content-Type: text/plain\r\n\r\n")
	strings.write_string(&sb, strings.reverse(body_str))

	if e := send_stdout(client, request.id, sb); e != nil {
		log.errorf("error in send_stdout: %s", e)
		return
	}

	if e := send_end_request(client, request.id); e != nil {
		log.errorf("error in send_end_request: %s", e)
		return
	}

	// TODO: set up proper callback instead of placeholder response
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
		// if the protocol uses 2 bytes for the roles but there are currently only 3 roles
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

	header := Header{
		version = VERSION,
		type = .Get_Values_Result,
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
send_stdout :: proc(client: RWC, req_id: u16, sb: strings.Builder) -> (err: Error) {
	// TODO: if the data is larger than max u16 len - split it
	req_id_b1, req_id_b0 := split_u16(req_id)

	h := Header {
		request_id_b1 = req_id_b1,
		request_id_b0 = req_id_b0,
		version       = VERSION,
		type          = .Stdout,
	}

	h.content_length_b1, h.content_length_b0 = split_u16(u16(len(sb.buf)))

	_ = io.write_ptr(client, &h, size_of(h)) or_return
	_ = io.write_full(client, sb.buf[:]) or_return

	h.content_length_b1, h.content_length_b0 = 0, 0
	_ = io.write_ptr(client, &h, size_of(h)) or_return

	log.debugf("sent stdout: %s", sb.buf)

	return
}

// TODO: statuses?
send_end_request :: proc(client: RWC, req_id: u16) -> (err: Error) {
	req_id_b1, req_id_b0 := split_u16(req_id)

	header_out := Header {
		version           = VERSION,
		request_id_b1     = req_id_b1,
		request_id_b0     = req_id_b0,
		type              = .End_Request,
		content_length_b0 = u8(size_of(End_Request_Body)),
	}
	body := End_Request_Body{}

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
