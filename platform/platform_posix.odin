package platform

import "base:runtime"
import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

import conf "../config"
import "../fcgi"
import "../logging"
import "./sem"

@(private)
Error :: union #shared_nil {
	runtime.Allocator_Error,
	posix.Errno,
}

Child_State :: enum int {
	Idle,
	Busy,
}

FD_Queue :: struct {
	queue: queue.Queue(posix.FD),
	cond:  sync.Cond,
	mutex: sync.Mutex,
}

@(private)
SHARED: ^[]Child_State

QUEUE: FD_Queue
WORKER_SEMA: ^sem.sem_t

@(private)
SOCKET_PAIRS: [dynamic][2]posix.FD

@(private)
_run :: proc(cfg: ^conf.Config, on_request: fcgi.On_Request) {
	logger, log_err := logging.init_log(cfg.log_path)
	if log_err != nil {
		fmt.eprintfln("Failed to init logger file: %s", cfg.log_path)
		posix.exit(1)
	}
	context.logger = logger

	// ignore sigpipe signal
	posix.signal(.SIGPIPE, cast(proc "c" (_: posix.Signal))posix.SIG_IGN)

	if e := init_worker_processes(cfg, on_request); e != nil {
		log.fatalf("Failed to init workers: %s", e)
		posix.exit(1)
	}

	if e := queue.init(&QUEUE.queue, cfg.queue_size); e != nil {
		log.fatalf("Failed to init queue: %s", e)
		posix.exit(1)
	}
	defer queue.destroy(&QUEUE.queue)

	consumer_thread := thread.create_and_start(main_fd_consumer, context)
	defer {
		thread.join(consumer_thread)
		thread.destroy(consumer_thread)
	}

	create_sock_err := accept_loop(cfg)
	if create_sock_err != nil {
		log.fatalf("Failed to create/bind socket: %s", create_sock_err)
		posix.exit(1)
	}
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

		sync.lock(&QUEUE.mutex)

		if queue.len(QUEUE.queue) >= cfg.queue_size {
			// TODO: send reject record
			posix.close(cl_sock)
			sync.unlock(&QUEUE.mutex)
			continue
		}

		queue.push_back(&QUEUE.queue, cl_sock)
		sync.unlock(&QUEUE.mutex)
		sync.cond_signal(&QUEUE.cond)
	}
}

main_fd_consumer :: proc() {
	log.info("FD consumer thread started.")

	for {
		sync.lock(&QUEUE.mutex)
		if queue.len(QUEUE.queue) == 0 {
			sync.cond_wait(&QUEUE.cond, &QUEUE.mutex)
		}
		sync.unlock(&QUEUE.mutex)

		sem.wait(WORKER_SEMA)
		sync.lock(&QUEUE.mutex)
		cl_sock := queue.pop_front(&QUEUE.queue)
		sync.unlock(&QUEUE.mutex)
		find_idle_worker(cl_sock)
	}

	log.info("FD consumer thread exiting.")
}

find_idle_worker :: proc(client_sock: posix.FD) {
	defer posix.close(client_sock)

	for i in 0 ..< len(SHARED) {
		state := sync.atomic_load(&SHARED[i])
		if state == .Busy {
			continue
		}

		sync.atomic_store(&SHARED[i], .Busy)
		send_err := send_fd(client_sock, SOCKET_PAIRS[i][0])
		if send_err != nil {
			log.errorf("Error in main sendmsg: %s", posix.get_errno())
			// TODO: probably send reject record to web server
			sync.atomic_store(&SHARED[i], .Idle)
			break
		}

		return
	}

	log.errorf("No worker found for socket: %v", client_sock)
}

@(require_results)
init_worker_processes :: proc(cfg: ^conf.Config, on_request: fcgi.On_Request) -> (err: Error) {
	SHARED = mmap_shared_slice(Child_State, cfg.worker_count) or_return
	SOCKET_PAIRS = init_socket_pairs(cfg.worker_count) or_return
	WORKER_SEMA = init_worker_semaphore(u32(cfg.worker_count), cfg.sem_path) or_return

	arena: vmem.Arena
	vmem.arena_init_static(&arena, cfg.memory_limit * mem.Megabyte) or_return
	alloc := vmem.arena_allocator(&arena)

	for i in 0 ..< cfg.worker_count {
		pid := posix.fork()
		if pid < 0 {
			return posix.get_errno()
		}

		if pid == 0 {
			init_child(cfg.worker_count, i, alloc, on_request)
			posix.exit(0)
		}

		// parent
		posix.close(SOCKET_PAIRS[i][1])
	}

	return
}

@(private)
init_child :: proc(n, child_number: int, alloc: mem.Allocator, on_request: fcgi.On_Request) {
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
		defer {
			sync.atomic_store(&SHARED[child_number], .Idle)
			sem.post(WORKER_SEMA)
		}

		if res := posix.recvmsg(SOCKET_PAIRS[child_number][1], &msg, {}); res < 0 {
			log.errorf("Error in worker %d recvmsg: %s", child_number, posix.get_errno())
			continue
		}

		cmsg := posix.CMSG_FIRSTHDR(&msg)
		mem.copy(&client_sock, posix.CMSG_DATA(cmsg), size_of(client_sock))

		stream := os.stream_from_handle(os.Handle(client_sock))
		fcgi.on_client_accepted(io.to_read_write_closer(stream), alloc, on_request)
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

init_worker_semaphore :: proc(
	value: u32,
	sema_name: string,
) -> (
	res: ^sem.sem_t,
	err: posix.Errno,
) {
	_name := strings.clone_to_cstring(sema_name)
	if ul_err := sem.unlink(_name); ul_err != nil && ul_err != .ENOENT {
		err = ul_err
		return
	}

	res = sem.open(_name, posix.O_CREAT | posix.O_EXCL, 0o644, value) or_return
	return
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

mmap_shared_slice :: proc "contextless" ($T: typeid, n: int) -> (s: ^[]T, err: posix.Errno) {
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

@(require_results)
send_fd :: proc(fd: posix.FD, sock: posix.FD) -> posix.Errno {
	fd2 := fd
	msg: posix.msghdr
	buf_len := cmsg_space(size_of(posix.FD))
	buf := make([dynamic]u8, buf_len)
	defer delete(buf)

	base := "FD"
	io := posix.iovec {
		iov_base = raw_data(base),
		iov_len  = 2,
	}
	msg.msg_iov = &io
	msg.msg_iovlen = 1

	msg.msg_control = raw_data(buf)
	msg.msg_controllen = auto_cast buf_len

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

cmsg_align :: proc(len: int) -> int {
	return ((len) + size_of(int) - 1) &~ (size_of(int) - 1)
}

cmsg_space :: proc(len: int) -> int {
	return cmsg_align(len) + cmsg_align(size_of(posix.cmsghdr))
}
