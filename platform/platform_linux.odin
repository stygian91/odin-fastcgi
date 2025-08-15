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
	defer os.close(os.Handle(client_sock))

	log.infof("client accepted in main: %+v", client_sock)

	cs := client_sock

	for i in 0 ..< len(SHARED) {
		state := sync.atomic_load(&SHARED[i])
		if state == .Idle {
			// TODO: calc buf size like CMSG_SPACE(sizeof(fd)) in C
			buf := [256]u8{}
			base := "FD"
			iovec := posix.iovec{iov_base=raw_data(base), iov_len=2}
			msg := posix.msghdr{}
			msg.msg_iov = &iovec
			msg.msg_iovlen = 1
			msg.msg_control = &buf
			msg.msg_controllen = size_of(buf)

			cmsg := posix.CMSG_FIRSTHDR(&msg)
			if cmsg == nil {
				log.errorf("CMSG_FIRSTHDR err: %s", posix.get_errno())
				return
			}

			cmsg.cmsg_level = posix.SOL_SOCKET
			cmsg.cmsg_type = posix.SCM_RIGHTS
			cmsg.cmsg_len = size_of(posix.cmsghdr) + size_of(client_sock)
			mem.copy(posix.CMSG_DATA(cmsg), &cs, size_of(cs))
			msg.msg_controllen = cmsg.cmsg_len

			log.infof("Main sendmsg to %d: %v", i, msg)
			res := posix.sendmsg(posix.FD(SOCKET_PAIRS[i][0]), &msg, {})
			if res < 0 {
				log.errorf("Error in main sendmsg: %s", posix.get_errno())
			}

			return
		}
	}

	log.error("Did not find an idle worker to handle client")
	// TODO: do we add it to a queue or maybe send reject fastcgi record?
}
