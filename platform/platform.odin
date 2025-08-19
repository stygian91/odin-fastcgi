package platform

import "../config"
import "../fcgi"

run :: proc(cfg: config.Config, on_request: fcgi.On_Request) {
	config.GLOBAL_CONFIG = cfg
	_run(&config.GLOBAL_CONFIG, on_request)
}
