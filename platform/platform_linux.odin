package platform

import "core:c"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"

import conf "../config"
import "../fcgi"
import "../logging"

DEFAULT_CONFIG_PATH :: "/etc/odin-fcgi/config.ini"

// Called when a new client was accepted in the main process
Accept_Proc :: proc(client_sock: Socket)

// Called when a new client was received in a worker process
Received_Proc :: proc(client: io.Read_Write_Closer)

@(private)
_run :: proc() {
	conf.init(DEFAULT_CONFIG_PATH)
	cfg := &conf.GLOBAL_CONFIG

	logger, log_err := logging.init_log(cfg.log_path)
	if log_err != nil {
		fmt.eprintfln("Failed to init logger file: %s", cfg.log_path)
		os.exit(1)
	}
	context.logger = logger

	if e := init_worker_processes(cfg.worker_count, fcgi.on_client_accepted); e != nil {
		log.fatalf("Failed to init workers: %s", e)
		os.exit(1)
	}

	create_sock_err := accept_loop(cfg, main_on_client_accepted)
	if create_sock_err != nil {
		log.fatalf("Failed to create/bind socket: %s", create_sock_err)
		os.exit(1)
	}
}

Cmsg_Hdr :: struct #packed {
	len:   uint,
	level: Cmsg_Level,
	type:  Cmsg_Type,
}

Cmsg_Level :: enum int {
	None   = 0,
	Socket = 1,
}

Cmsg_Type :: enum int {
	Rights      = 1,
	Credentials = 2,
	Security    = 3,
	Pidfd       = 4,
}

main_on_client_accepted :: proc(client_sock: Socket) {
	// defer os.close(os.Handle(client_sock))

	log.infof("client accepted in main: %+v", client_sock)

	// h: fcgi.Record_Header
	// if _, e := os.read_ptr(os.Handle(client_sock), &h, size_of(h)); e != nil {
	// 	log.errorf("here: %s", e)
	// 	return
	// }
	//
	// log.infof("here read: %+v", h)
	// return

	cs := client_sock

	for i in 0 ..< len(SHARED) {
		state := sync.atomic_load(&SHARED[i])
		if state == .Idle {
			// msg: linux.Msg_Hdr
			// cmsg: posix.cmsghdr
			// base := "FD"
			// buf := [align_of(linux.Msg_Hdr) + align_of(int)]u8{}
			// iovec := [1]linux.IO_Vec{{base = &base, len = 2}}
			// msg.iov = iovec[:]
			// msg.control = buf[:]
			//
			// if _, e := linux.sendmsg(linux.Fd(SOCKET_PAIRS[i][0]), &msg, {}); e != nil {
			// 	log.errorf("Error while sending client socket FD to worker: %s", e)
			// }

			buf := [256]u8{}
			base := "FD"
			iovec := posix.iovec{iov_base=rawptr(uintptr(&base)), iov_len=2}
			msg := posix.msghdr{}
			msg.msg_iov = &iovec
			msg.msg_iovlen = 1
			msg.msg_control = &buf
			msg.msg_controllen = size_of(buf)

			cmsg := posix.CMSG_FIRSTHDR(&msg)
			cmsg.cmsg_level = posix.SOL_SOCKET
			cmsg.cmsg_type = posix.SCM_RIGHTS
			cmsg.cmsg_len = size_of(posix.cmsghdr) + size_of(client_sock)
			d := posix.CMSG_DATA(cmsg)
			log.infof("CMSG_DATA: %v", d)
			mem.copy(d, &cs, size_of(client_sock))
			msg.msg_controllen = cmsg.cmsg_len

			log.infof("Main sendmsg to %d: %v", i, msg)
			res := posix.sendmsg(posix.FD(SOCKET_PAIRS[i][0]), &msg, {})
			if res < 0 {
				log.errorf("Error in main sendmsg: %s", posix.get_errno())
			}

			log.infof("Main sendmsg to %d res: %d", i, res)

			// writer := io.to_writer(os.stream_from_handle(os.Handle(SOCKET_PAIRS[i][0])))
			// if _, e := io.write_ptr(writer, &cs, size_of(cs)); e != nil {
			// 	log.errorf("Error while sending client socket FD to worker: %s", e)
			// }
			return
		}
	}

	log.error("Did not find an idle worker to handle client")
	// TODO: do we add it to a queue or maybe send reject fastcgi record?
}
