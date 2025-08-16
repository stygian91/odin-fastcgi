package fcgi

import "core:io"
import "core:log"
import "core:os"

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

@(private)
CONTENT_BUF_LEN :: 1 << 16

@(private)
CONTENT_BUF := [CONTENT_BUF_LEN]u8{}

RWC :: io.Read_Write_Closer

// TODO: use arena
on_client_accepted :: proc(client: RWC) {
	defer io.close(client)

	record, recv_err := receive_record(client)
	if recv_err != nil {
		// TODO: disambiguate errors and add more info to log
		log.errorf("Error while processing request: %s", recv_err)
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

	log.debugf("Received record: %+v", record)

	return
}

@(require_results)
receive_body :: proc(client: RWC, header: Header) -> (body: Body, err: Error) {
	defer if header.padding_length > 0 {
		io.read_at_least(client, PADDING_BUF[:], int(header.padding_length))
	}

	content_len := int(combine_u16(header.content_length_b1, header.content_length_b0))

	#partial switch header.type {
	case .Begin_Request:
		validate_content_length(content_len, size_of(Begin_Request_Body)) or_return
		b: Begin_Request_Body
		_ = io.read_ptr(client, &b, content_len) or_return
		body = b
		return

	case:
		io.read_at_least(client, CONTENT_BUF[:], content_len)
		err = .Unknown_Record_Type
		return
	}

	return
}

send_unkown_type_response :: proc(client: RWC, header_in: Header) -> (err: Error) {
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
