package fcgi

import "core:io"

// called in main process
on_client_accepted :: proc(client: io.Read_Write_Closer) {
	defer io.close(client)
}
