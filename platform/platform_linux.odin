package platform

import "core:fmt"
import "core:os"

import c "../config"
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
}
