package platform

import "base:runtime"
import "core:io"
import "core:mem"
import "core:os"
import "core:sys/posix"
import "core:sys/unix"

@(private)
Socket :: distinct int
@(private)
Error :: posix.Errno
@(private)
Socket_Length :: posix.socklen_t

@(private, require_results)
_socket :: proc(path: string) -> (sock: Socket, err: Error) {
	result := unix.sys_socket(os.AF_UNIX, os.SOCK_STREAM, 0)
	if result < 0 {
		return 0, posix.get_errno()
	}
	return Socket(result), nil
}

@(private, require_results)
_create_and_listen :: proc(path: string, backlog: int) -> (sock: Socket, err: Error) {
	sock = _socket(path) or_return
	addr := posix.sockaddr_un{}
	_init_address(&addr, path) or_return

	if os.exists(path) {
		_convert_error(os.remove(path)) or_return
	}

	_convert_error(os.bind(cast(os.Socket)sock, cast(^os.SOCKADDR)&addr, size_of(addr))) or_return
	_convert_error(os.listen(cast(os.Socket)sock, backlog)) or_return

	return
}

@(private, require_results)
_accept_and_stream :: proc(sock: Socket) -> (rwc: io.Read_Write_Closer, err: Error) {
	cl_sock, cl_err := os.accept(cast(os.Socket)sock, nil, nil)
	if err = _convert_error(cl_err); err != nil {return}

	stream := os.stream_from_handle(cast(os.Handle)cl_sock)
	rwc = io.to_read_write_closer(stream)

	return
}

@(private, require_results)
_init_address :: proc(addr: ^posix.sockaddr_un, path: string) -> Error {
	if len(path) >= len(addr.sun_path) {
		return .EINVAL
	}

	addr.sun_family = .UNIX
	raw_str := transmute(runtime.Raw_String)path
	mem.copy(&addr.sun_path, raw_str.data, len(path))
	addr.sun_path[len(path)] = 0

	return nil
}

@(private, require_results)
_convert_error :: proc(os_err: os.Error) -> (err: Error) {
	if os_err == nil {
		return .NONE
	}

	return cast(Error)os_err.(os.Platform_Error)
}
