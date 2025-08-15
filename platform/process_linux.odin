package platform

import "base:runtime"
import "core:os"
import "core:sync"
import "core:io"
import "core:mem"
import "core:log"
import "core:sys/linux"
import "core:sys/posix"

import "../fcgi"

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
init_worker_processes :: proc(n: int, on_received: Received_Proc) -> (err: Error) {
	SHARED = mmap_shared_slice(Child_State, n) or_return
	SOCKET_PAIRS = init_socket_pairs(n) or_return

	for i in 0 ..< n {
		pid := os.fork() or_return
		if pid == 0 {
			init_child(n, i, on_received)
			os.exit(0)
		}

		// parent
		posix.close(SOCKET_PAIRS[i][1])
	}

	return
}

@(private)
init_child :: proc(n, nth_child: int, on_received: Received_Proc) {
	// close other processes' sockets
	for i in 0..<n {
		if i != nth_child {
			posix.close(SOCKET_PAIRS[i][0])
			posix.close(SOCKET_PAIRS[i][1])
		}
	}

	// close unused part of current worker's pair
	posix.close(SOCKET_PAIRS[nth_child][0])

	sock_stream := os.stream_from_handle(os.Handle(SOCKET_PAIRS[nth_child][1]))
	sock_rwc := io.to_read_write_closer(sock_stream)
	client_sock: Socket

	msg := posix.msghdr{}
	m_buffer := [256]u8{}
	io := posix.iovec{iov_base = &m_buffer, iov_len = size_of(m_buffer)}
	c_buffer := [256]u8{}
	msg.msg_control = &c_buffer
	msg.msg_controllen = size_of(c_buffer)
	msg.msg_iov = &io
	msg.msg_iovlen = 1

	for {
		log.infof("worker %d listening for fd", nth_child)
		if res := posix.recvmsg(SOCKET_PAIRS[nth_child][1], &msg, {}); res < 0 {
			log.errorf("Error in worker %d recvmsg: %s", nth_child, posix.get_errno())
			continue
		}

		cmsg := posix.CMSG_FIRSTHDR(&msg)

		mem.copy(&client_sock, posix.CMSG_DATA(cmsg), size_of(client_sock))
		log.infof("Client received fd: %+v", client_sock)

		// TODO: create stream and move this in the fcgi module
		fcgi_header: fcgi.Record_Header
		if _, e := os.read_ptr(os.Handle(client_sock), &fcgi_header, size_of(fcgi_header)); e != nil {
			log.errorf("Error reading from client: %s", e)
			continue
		}

		log.infof("Received header: %+v", fcgi_header)

		// receive client socket fd from main process
		// _, err := io.read_ptr(sock_rwc, &client_sock, size_of(client_sock))
		// if err != nil {
		// 	log.errorf("error while receiving client FD: %s", err)
		// 	continue
		// }
		//
		// log.infof("client received fd: %+v", client_sock)
		//
		// sync.atomic_store(&SHARED[nth_child], .Busy)
		// defer sync.atomic_store(&SHARED[nth_child], .Idle)
		//
		// client_stream := os.stream_from_handle(cast(os.Handle)client_sock)
		// client_rwc := io.to_read_write_closer(client_stream)
		// on_received(client_rwc)
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
