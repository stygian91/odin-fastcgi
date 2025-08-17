package fcgi

import "core:io"
import "core:log"
import "core:os"
import "core:strings"

VERSION :: 1

Error :: union #shared_nil {
	io.Error,
	Fcgi_Error,
}

Fcgi_Error :: enum {
	None,
	Unknown_Record_Type,
	Invalid_Record,
}

@(private)
PADDING_BUF := [256]u8{}

RWC :: io.Read_Write_Closer

// TODO: use arena
on_client_accepted :: proc(client: RWC) {
	defer {
		io.close(client)
		io.flush(client)
	}

	header: Header

	for {
		// TODO: build up state, don't just throw the records away
		rec, recv_err := receive_record(client)
		if recv_err != nil {
			// TODO: disambiguate errors and add more info to log
			log.errorf("Error while processing request: %s", recv_err)
			if recv_err == .EOF {return}
		}

		if rec.header.type == .Params {
			header = rec.header
			break
		}
	}

	// TODO: set up proper callback instead of placeholder response
	sb: strings.Builder
	strings.write_string(&sb, "Content-Type: text/plain\r\n\r\nfoobar")

	if e := send_stdout(client, header, sb); e != nil {
		log.errorf("Error while sending stdout: %s", e)
	}

	if e := send_end_request(client, header); e != nil {
		log.errorf("Error while sending end request: %s", e)
	}
}

@(require_results)
receive_record :: proc(client: RWC) -> (record: Record, err: Error) {
	header: Header
	_ = io.read_ptr(client, &header, size_of(header)) or_return

	body := receive_body(client, header) or_return

	// TODO: move this type of logic up
	// if recv_body_err != nil {
	// 	if recv_body_err == .Unknown_Record_Type {
	// 		if e := send_unkown_type_response(client, header); e != nil {
	// 			log.errorf("Error while sending \"Unknown type\" response: %s", e)
	// 		}
	// 	}
	//
	// 	err = recv_body_err
	// 	return
	// }

	record.header = header
	record.body = body

	// log.debugf("Received record: %+v", record)

	return
}

@(require_results)
receive_body :: proc(client: RWC, header: Header) -> (body: Body, err: Error) {
	defer if header.padding_length > 0 {
		io.read_at_least(client, PADDING_BUF[:], int(header.padding_length))
	}

	content_len := int(combine_u16(header.content_length_b1, header.content_length_b0))
	log.debugf("receive_body: %+v", header)

	#partial switch header.type {
	case .Begin_Request:
		validate_content_length(content_len, size_of(Begin_Request_Body)) or_return
		b: Begin_Request_Body
		_ = io.read_ptr(client, &b, content_len) or_return
		body = b

	case .Params, .Stdin:
		buf := make([dynamic]u8, content_len)
		_ = io.read_at_least(client, buf[:], content_len) or_return
		body = cast(Raw_Body)buf

	case:
		buf := make([dynamic]u8, content_len)
		io.read_at_least(client, buf[:], content_len)
		err = .Unknown_Record_Type
	}

	return
}

@(require_results)
send_stdout :: proc(client: RWC, header_in: Header, sb: strings.Builder) -> (err: Error) {
	// TODO: if the data is larger than max u16 len - split it

	h := Header {
		request_id_b1 = header_in.request_id_b1,
		request_id_b0 = header_in.request_id_b0,
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
send_end_request :: proc(client: RWC, header_in: Header) -> (err: Error) {
	header_out := Header {
		version           = VERSION,
		request_id_b1     = header_in.request_id_b1,
		request_id_b0     = header_in.request_id_b0,
		type              = .End_Request,
		content_length_b0 = u8(size_of(End_Request_Body)),
	}
	body := End_Request_Body{}

	_ = io.write_ptr(client, &header_out, size_of(Header)) or_return
	_ = io.write_ptr(client, &body, size_of(End_Request_Body)) or_return

	return
}

send_unkown_type :: proc(client: RWC, header_in: Header) -> (err: Error) {
	header_out := Header {
		version           = VERSION,
		type              = .Unknown_Type,
		request_id_b1     = header_in.request_id_b1,
		request_id_b0     = header_in.request_id_b0,
		content_length_b0 = size_of(Unknown_Type_Body),
	}

	body := Unknown_Type_Body {
		type = header_in.type,
	}

	_ = io.write_ptr(client, &header_out, size_of(header_out)) or_return
	_ = io.write_ptr(client, &body, size_of(body)) or_return

	return
}
