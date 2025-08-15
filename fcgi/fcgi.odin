package fcgi

import "core:io"
import "core:os"
import "core:log"

// TODO: use arena
on_client_accepted :: proc(client: io.Read_Write_Closer) {
	defer io.close(client)

	h := os.Handle(uintptr(client.data))
	log.infof("worker received client fd: %+v", h)

	header: Record_Header

	if _, e := os.read_ptr(h, &header, size_of(header)); e != nil {
		log.errorf("Error while reading record header: %s", e)
		return
	}

	// if _, e := io.read_ptr(client, &header, size_of(header)); e != nil {
	// 	log.errorf("Error while reading record header: %s", e)
	// 	return
	// }

	// log.infof("Received record header: %+v", header)
}
