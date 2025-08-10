package platform

import "core:fmt"
import "core:log"
import "core:os"

import c "../config"
import "../fcgi"
import "../logging"

DEFAULT_CONFIG_PATH :: "/etc/odin-fcgi/config.ini"

@(private)
_run :: proc() {
	c.init(DEFAULT_CONFIG_PATH)
	cfg := &c.GLOBAL_CONFIG

	logger, log_err := logging.init_log(cfg.log_path)
	if log_err != nil {
		fmt.eprintfln("Failed to init logger file: %s", cfg.log_path)
		os.exit(1)
	}
	context.logger = logger

	create_sock_err := loop(cfg, fcgi.on_client_accepted)
	if create_sock_err != nil {
		log.fatalf("Failed to create/bind socket: %s", create_sock_err)
		os.exit(1)
	}
}
