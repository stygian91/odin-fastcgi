package platform

import "../config"

run :: proc(cfg: config.Config) {
	config.GLOBAL_CONFIG = cfg
	_run(&config.GLOBAL_CONFIG)
}
