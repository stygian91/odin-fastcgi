package config

import "base:runtime"
import "core:encoding/ini"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Config :: struct {
	sock_path:    string,
	log_path:     string,
	backlog:      int,
	worker_count: int,
	// in Mb:
	memory_limit: uint,
}

DEFAULT_CONFIG :: Config {
	backlog = 5,
	worker_count = 4,
	memory_limit = 256,
}

Error :: union #shared_nil {
	runtime.Allocator_Error,
	os.Error,
	Missing_Required_Value,
}

Missing_Required_Value :: Maybe(string)

Command_Arguments :: struct {
	config: string `usage:"Config file path"`,
}

GLOBAL_CONFIG: Config

init :: proc(default_config_path: string) {
	args := load_cli_args()
	ini_path := args.config if len(args.config) > 0 else default_config_path
	cfg, cfg_err := load_from_file(ini_path)

	if cfg_err != nil {
		if e, ok := cfg_err.(Missing_Required_Value); ok {
			fmt.eprintfln("Config error: missing required value '%s'", e)
		} else {
			fmt.eprintfln("Config error: %s", cfg_err)
		}
		os.exit(1)
	}

	GLOBAL_CONFIG = cfg
}

@(require_results)
load_from_file :: proc(path: string) -> (cfg: Config, err: Error) {
	content := os.read_entire_file_from_filename_or_err(path) or_return
	ini_map := ini.load_map_from_string(string(content), context.allocator) or_return

	defer ini.delete_map(ini_map)
	m := ini_map[""]

	cfg.sock_path = _get_required(m, "sock_path") or_return
	cfg.log_path = _get_required(m, "log_path") or_return
	cfg.backlog = strconv.parse_int(m["backlog"], 10) or_else DEFAULT_CONFIG.backlog
	cfg.worker_count = strconv.parse_int(m["worker_count"], 10) or_else DEFAULT_CONFIG.worker_count
	cfg.memory_limit = strconv.parse_uint(m["memory_limit"], 10) or_else DEFAULT_CONFIG.memory_limit

	return cfg, nil
}

load_cli_args :: proc() -> Command_Arguments {
	cli_args: Command_Arguments
	flags.parse_or_exit(&cli_args, os.args, .Unix)
	return cli_args
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
