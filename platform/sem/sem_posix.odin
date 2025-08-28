package sem

import "core:c"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import lib "system:System"
} else {
	foreign import lib "system:c"
}

SIZE_OF_SEM_T :: 32 when size_of(int) == 8 else 16

@(rodata)
SEM_FAILED: ^sem_t

sem_t :: struct #raw_union {
	size:  [SIZE_OF_SEM_T]u8,
	align: c.long,
}

foreign lib {
	sem_open :: proc(name: cstring, oflag: c.int, #c_vararg args: ..any) -> ^sem_t ---
	sem_init :: proc(sem: ^sem_t, pshared: c.int, value: c.uint) -> c.int ---
	sem_unlink :: proc(name: cstring) -> c.int ---
	sem_wait :: proc(sem: ^sem_t) -> c.int ---
	sem_post :: proc(sem: ^sem_t) -> c.int ---
	sem_getvalue :: proc(sem: ^sem_t, val: ^c.int) -> c.int ---
}

@(require_results)
unlink :: proc "contextless" (name: cstring) -> (err: posix.Errno) {
	unlink_res := sem_unlink(name)
	if unlink_res == -1 {
		err = posix.get_errno()
	}

	return
}

@(require_results)
open :: proc {
	open2,
	open4,
}

open2 :: proc "contextless" (name: cstring, oflags: c.int) -> (res: ^sem_t, err: posix.Errno) {
	res = sem_open(name, oflags)
	if res == SEM_FAILED {
		err = posix.get_errno()
	}

	return
}

@(require_results)
open4 :: proc "contextless" (
	name: cstring,
	oflags: c.int,
	mode: posix._mode_t,
	value: c.uint,
) -> (
	res: ^sem_t,
	err: posix.Errno,
) {
	res = sem_open(name, oflags, mode, value)
	if res == SEM_FAILED {
		err = posix.get_errno()
	}

	return
}

post :: proc(sem: ^sem_t) -> (err: posix.Errno) {
	if res := sem_post(sem); res == -1 {
		err = posix.get_errno()
	}

	return
}

wait :: proc(sem: ^sem_t) -> (err: posix.Errno) {
	if res := sem_wait(sem); res == -1 {
		err = posix.get_errno()
	}

	return
}

@(require_results)
getvalue :: proc(sem: ^sem_t) -> (val: c.int, err: posix.Errno) {
	if res := sem_getvalue(sem, &val); res == -1 {
		err = posix.get_errno()
	}

	return
}
