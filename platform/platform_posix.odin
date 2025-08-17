package platform

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"

import conf "../config"
import "../fcgi"
import "../logging"

DEFAULT_CONFIG_PATH :: "/etc/odin-fcgi/config.ini"

@(private)
Error :: union #shared_nil {
	runtime.Allocator_Error,
	posix.Errno,
}

Child_State :: enum int {
	Idle,
	Busy,
}

@(private)
SHARED: ^[]Child_State

@(private)
SOCKET_PAIRS: [dynamic][2]posix.FD

@(private)
_run :: proc() {
	conf.init(DEFAULT_CONFIG_PATH)
	cfg := &conf.GLOBAL_CONFIG

	logger, log_err := logging.init_log(cfg.log_path)
	if log_err != nil {
		fmt.eprintfln("Failed to init logger file: %s", cfg.log_path)
		posix.exit(1)
	}
	context.logger = logger

	// ignore sigpipe signal
	posix.signal(.SIGPIPE, cast(proc "c" (posix.Signal)) posix.SIG_IGN)

	if e := init_worker_processes(cfg.worker_count); e != nil {
		log.fatalf("Failed to init workers: %s", e)
		posix.exit(1)
	}

	create_sock_err := accept_loop(cfg)
	if create_sock_err != nil {
		log.fatalf("Failed to create/bind socket: %s", create_sock_err)
		posix.exit(1)
	}
}

main_on_client_accepted :: proc(client_sock: posix.FD) {
	defer posix.close(client_sock)

	log.debugf("client accepted in main: %+v", client_sock)

	for i in 0 ..< len(SHARED) {
		state := sync.atomic_load(&SHARED[i])
		if state == .Idle {
			send_err := send_fd(client_sock, SOCKET_PAIRS[i][0])
			if send_err != nil {
				log.errorf("Error in main sendmsg: %s", posix.get_errno())
				continue
			}
		}

		return
	}

	log.error("Did not find an idle worker to handle client")
	// TODO: do we add it to a queue or maybe send reject fastcgi record?
}

@(require_results)
send_fd :: proc(fd: posix.FD, sock: posix.FD) -> posix.Errno {
	// TODO: calc buf size like CMSG_SPACE(sizeof(fd)) in C
	fd2 := fd
	msg: posix.msghdr
	buf: [256]u8

	base := "FD"
	io := posix.iovec {
		iov_base = raw_data(base),
		iov_len  = 2,
	}
	msg.msg_iov = &io
	msg.msg_iovlen = 1

	msg.msg_control = &buf
	msg.msg_controllen = size_of(buf)

	cmsg := posix.CMSG_FIRSTHDR(&msg)
	if cmsg == nil {
		return .EINVAL
	}

	cmsg.cmsg_level = posix.SOL_SOCKET
	cmsg.cmsg_type = posix.SCM_RIGHTS
	cmsg.cmsg_len = size_of(fd) + size_of(posix.cmsghdr)
	mem.copy(posix.CMSG_DATA(cmsg), &fd2, size_of(fd2))
	msg.msg_controllen = cmsg.cmsg_len

	if res := posix.sendmsg(sock, &msg, {}); res < 0 {
		return posix.get_errno()
	}

	return nil
}

@(require_results)
accept_loop :: proc(cfg: ^conf.Config) -> (err: posix.Errno) {
	serv_sock := create_and_listen(cfg.sock_path, cast(c.int)cfg.backlog) or_return
	log.infof("Listening on socket: %s", cfg.sock_path)

	for {
		cl_sock := posix.accept(serv_sock, nil, nil)
		if cl_sock < 0 {
			log.errorf("Error while accepting socket on main: %s", posix.get_errno())
			continue
		}

		main_on_client_accepted(cl_sock)
	}
}

@(require_results)
create_and_listen :: proc(path: string, backlog: c.int) -> (sock: posix.FD, err: posix.Errno) {
	addr := posix.sockaddr_un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		return -1, .EINVAL
	}

	sock = posix.socket(.UNIX, .STREAM, .IP)
	if sock < 0 {
		return sock, posix.get_errno()
	}

	mem.copy(&addr.sun_path, raw_data(path), len(path))

	if os.exists(path) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		path_cstr := strings.clone_to_cstring(path)
		if res := posix.unlink(path_cstr); res == .FAIL {
			err = posix.get_errno()
			return
		}
	}

	if res := posix.bind(sock, cast(^posix.sockaddr)&addr, size_of(addr)); res == .FAIL {
		err = posix.get_errno()
		return
	}

	if res := posix.listen(sock, backlog); res == .FAIL {
		err = posix.get_errno()
		return
	}

	return
}

@(require_results)
init_worker_processes :: proc(n: int) -> (err: Error) {
	SHARED = mmap_shared_slice(Child_State, n) or_return
	SOCKET_PAIRS = init_socket_pairs(n) or_return

	for i in 0 ..< n {
		pid := posix.fork()
		if pid < 0 {
			return posix.get_errno()
		}

		if pid == 0 {
			init_child(n, i)
			posix.exit(0)
		}

		// parent
		posix.close(SOCKET_PAIRS[i][1])
	}

	return
}

@(private)
init_child :: proc(n, child_number: int) {
	// close other processes' sockets
	for i in 0 ..< n {
		if i != child_number {
			posix.close(SOCKET_PAIRS[i][0])
			posix.close(SOCKET_PAIRS[i][1])
		}
	}

	// close unused part of current worker's pair
	posix.close(SOCKET_PAIRS[child_number][0])

	client_sock: posix.FD
	msg := posix.msghdr{}
	m_buffer := [256]u8{}
	iovec := posix.iovec {
		iov_base = &m_buffer,
		iov_len  = size_of(m_buffer),
	}
	c_buffer := [256]u8{}
	msg.msg_control = &c_buffer
	msg.msg_controllen = size_of(c_buffer)
	msg.msg_iov = &iovec
	msg.msg_iovlen = 1

	for {
		log.debugf("worker %d listening for fd", child_number)

		if res := posix.recvmsg(SOCKET_PAIRS[child_number][1], &msg, {}); res < 0 {
			log.errorf("Error in worker %d recvmsg: %s", child_number, posix.get_errno())
			continue
		}
		defer sync.atomic_store(&SHARED[child_number], .Idle)

		cmsg := posix.CMSG_FIRSTHDR(&msg)
		mem.copy(&client_sock, posix.CMSG_DATA(cmsg), size_of(client_sock))
		log.debugf("Client %d received fd: %+v", child_number, client_sock)

		stream := os.stream_from_handle(os.Handle(client_sock))
		fcgi.on_client_accepted(io.to_read_write_closer(stream))
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
	addr: rawptr
	size := (uint(size_of(T)) * uint(n)) + uint(size_of(runtime.Raw_Slice))

	res_addr := posix.mmap(addr, size, {.READ, .WRITE}, {.SHARED, .ANONYMOUS})
	if res_addr == posix.MAP_FAILED {
		err = posix.get_errno()
		return
	}

	data_ptr := uintptr(res_addr) + size_of(runtime.Raw_Slice)

	s_raw := cast(^runtime.Raw_Slice)res_addr
	s_raw.len = n
	s_raw.data = rawptr(data_ptr)

	s = transmute(^[]T)s_raw

	return
}
