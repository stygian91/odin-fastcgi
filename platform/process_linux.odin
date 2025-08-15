package platform

import "base:runtime"
import "core:mem"
import "core:os"
import "core:io"
import "core:sys/linux"
import "core:sys/posix"

Child_State :: enum int {
	Idle,
	Busy,
}

@(private)
SHARED: ^[]Child_State

@(private)
SOCKET_PAIRS: [dynamic][2]posix.FD

// TODO: add callback(s) for parent/children?
@(require_results)
init_worker_processes :: proc(n: int) -> (err: Error) {
	SHARED = mmap_shared_slice(Child_State, n) or_return
	SOCKET_PAIRS = init_socket_pairs(n) or_return

	for i in 0 ..< n {
		pid := os.fork() or_return
		if pid == 0 {
			init_child(n, i)
			os.exit(0)
		}

		// parent
		posix.close(SOCKET_PAIRS[i][1])
	}

	return
}

@(private)
init_child :: proc(n, nth_child: int) {
	for i in 0..<n {
		if i != nth_child {
			posix.close(SOCKET_PAIRS[i][0])
			posix.close(SOCKET_PAIRS[i][1])
		}
	}

	posix.close(SOCKET_PAIRS[nth_child][0])
	sock_stream := os.stream_from_handle(transmute(os.Handle)SOCKET_PAIRS[nth_child][1])
	sock_rwc := io.to_read_write_closer(sock_stream)
	for {
		client_sock: Socket
		read_bytes, err := io.read_ptr(sock_rwc, &client_sock, size_of(client_sock))
		if err != nil {
			// TODO:
		}
		client_stream := os.stream_from_handle(cast(os.Handle)client_sock)
		client_rwc := io.to_read_write_closer(client_stream)
		// TODO:
	}
}

init_socket_pairs :: proc(n: int) -> (pairs: [dynamic][2]posix.FD, err: Error) {
	pairs = make([dynamic][2]posix.FD, n) or_return

	for i in 0 ..< n {
		if res := posix.socketpair(.UNIX, .STREAM, .IP, &pairs[i]); res == .FAIL {
			return pairs, posix.get_errno()
		}
	}

	return
}

mmap_shared_slice :: proc($T: typeid, n: int) -> (s: ^[]T, err: posix.Errno) {
	addr: uintptr
	size := (uint(size_of(T)) * uint(n)) + uint(size_of(runtime.Raw_Slice))

	res_addr, errno := linux.mmap(addr, size, {.READ, .WRITE}, {.SHARED, .ANONYMOUS})
	if errno != nil {
		err = cast(posix.Errno)errno
		return
	}

	data_ptr := uintptr(res_addr) + size_of(runtime.Raw_Slice)

	s_raw := cast(^runtime.Raw_Slice)res_addr
	s_raw.len = n
	s_raw.data = rawptr(data_ptr)

	s = transmute(^[]T)s_raw

	return
}
