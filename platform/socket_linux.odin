package platform

import "base:runtime"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:sys/posix"
import "core:sys/unix"

import c "../config"

@(private)
Socket :: distinct int
@(private)
Error :: union #shared_nil {
	runtime.Allocator_Error,
	posix.Errno,
	os.Error,
}
@(private)
Socket_Length :: posix.socklen_t

@(require_results)
accept_loop :: proc(cfg: ^c.Config, on_accept: Accept_Proc) -> (err: Error) {
	serv_sock := create_and_listen(cfg.sock_path, cfg.backlog) or_return

	for {
		client_rwc, accept_err := accept_and_stream(serv_sock)
		if accept_err != nil {
			log.errorf("Accept error: %s", accept_err)
			continue
		}

		on_accept(client_rwc)
	}
}

@(require_results)
socket :: proc(path: string) -> (sock: Socket, err: Error) {
	result := unix.sys_socket(os.AF_UNIX, os.SOCK_STREAM, 0)
	if result < 0 {
		return 0, posix.get_errno()
	}
	return Socket(result), nil
}

@(require_results)
create_and_listen :: proc(path: string, backlog: int) -> (sock: Socket, err: Error) {
	sock = socket(path) or_return
	addr := posix.sockaddr_un{}
	init_address(&addr, path) or_return

	if os.exists(path) {
		os.remove(path) or_return
	}

	os.bind(cast(os.Socket)sock, cast(^os.SOCKADDR)&addr, size_of(addr)) or_return
	os.listen(cast(os.Socket)sock, backlog) or_return

	return
}

@(require_results)
accept_and_stream :: proc(sock: Socket) -> (rwc: io.Read_Write_Closer, err: Error) {
	cl_sock := os.accept(cast(os.Socket)sock, nil, nil) or_return

	stream := os.stream_from_handle(cast(os.Handle)cl_sock)
	rwc = io.to_read_write_closer(stream)

	return
}

@(require_results)
init_address :: proc(addr: ^posix.sockaddr_un, path: string) -> Error {
	if len(path) >= len(addr.sun_path) {
		return posix.Errno.EINVAL
	}

	addr.sun_family = .UNIX
	raw_str := transmute(runtime.Raw_String)path
	mem.copy(&addr.sun_path, raw_str.data, len(path))
	addr.sun_path[len(path)] = 0

	return nil
}
