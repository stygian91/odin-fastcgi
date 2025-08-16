package platform

import "core:io"

// Called when a new client was received in a worker process
Received_Proc :: proc(client: io.Read_Write_Closer)

run :: proc() {
	_run()
}
