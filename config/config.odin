package config

import "base:runtime"
import "core:encoding/ini"
import "core:os"
import "core:strconv"
import "core:strings"

Config :: struct {
	sock_path:    string,
	log_path:     string,
	sem_path:     string,
	backlog:      int,
	worker_count: int,
	queue_size:   int,
	// in Mb:
	memory_limit: uint,
}

DEFAULT_CONFIG :: Config {
	backlog      = 5,
	worker_count = 4,
	sem_path     = "/fcgi-semaphore",
	queue_size   = 8,
	memory_limit = 256,
}

Error :: union #shared_nil {
	runtime.Allocator_Error,
	os.Error,
	Missing_Required_Value,
}

Missing_Required_Value :: Maybe(string)

GLOBAL_CONFIG: Config

@(require_results)
load_from_file :: proc(path: string) -> (cfg: Config, err: Error) {
	content := os.read_entire_file_from_filename_or_err(path) or_return
	ini_map := ini.load_map_from_string(string(content), context.allocator) or_return

	defer ini.delete_map(ini_map)
	m := ini_map[""]

	cfg.sock_path = _get_required(m, "sock_path") or_return
	cfg.log_path = _get_required(m, "log_path") or_return
	cfg.sem_path = strings.clone(m["sem_path"] or_else DEFAULT_CONFIG.sem_path)

	cfg.backlog = strconv.parse_int(m["backlog"], 10) or_else DEFAULT_CONFIG.backlog
	cfg.worker_count = strconv.parse_int(m["worker_count"], 10) or_else DEFAULT_CONFIG.worker_count
	cfg.queue_size = strconv.parse_int(m["queue_size"], 10) or_else DEFAULT_CONFIG.queue_size
	cfg.memory_limit =
		strconv.parse_uint(m["memory_limit"], 10) or_else DEFAULT_CONFIG.memory_limit

	return cfg, nil
}


@(private, require_results)
_get_required :: proc(m: map[string]string, key: string) -> (val: string, err: Error) {
	v, ok := m[key]
	if !ok {
		err = Missing_Required_Value(key)
		return
	}

	val = strings.clone(v)
	return
}
