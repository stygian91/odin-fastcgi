package logging

import l "core:log"
import "core:os"

@(require_results)
init_log :: proc(log_path: string) -> (logger: l.Logger, err: os.Error) {
	fd := os.open(log_path, os.O_RDWR | os.O_CREATE | os.O_APPEND, 0o640) or_return

	when ODIN_DEBUG {
		file_logger := l.create_file_logger(fd)
		stdlogger := l.create_file_logger(os.stdout, .Debug, l.Default_Console_Logger_Opts)
		logger = l.create_multi_logger(stdlogger, file_logger)
	} else {
		file_logger := l.create_file_logger(fd, .Info)
		logger = file_logger
	}

	return
}
