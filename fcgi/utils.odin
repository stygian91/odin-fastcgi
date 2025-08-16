package fcgi

import "core:io"
import "core:strings"

combine_u16 :: #force_inline proc "contextless" (b1, b0: u8) -> u16 {
	return (cast(u16)b1 << 8) + cast(u16)b0
}

split_u16 :: proc "contextless" (num: u16) -> (b1, b0: u8) {
	tmp := (num & 0b1111_1111_0000_0000) >> 8
	b1 = cast(u8)tmp
	tmp = num & 0b1111_1111
	b0 = cast(u8)tmp
	return
}

parse_params :: proc(buf: []u8) -> (res: map[string]string) {
	rem := buf[:]
	res = make(map[string]string)

	for {
		if len(rem) == 0 {return}
		n, k, v := parse_key_value_pair(rem)
		if n == 0 {return}
		res[k] = v
		rem = rem[n:]
	}

	return res
}

@(require_results)
validate_content_length :: #force_inline proc "contextless" (
	content_len, expected_len: int,
) -> (
	err: Fcgi_Error,
) {
	return nil if content_len == expected_len else .Invalid_Record
}

parse_key_value_pair :: proc(buf: []u8) -> (n: int, key: string, value: string) {
	if len(buf) == 0 {return}

	key_len, val_len: u32

	curr := 0
	if (buf[0] & 128) == 128 {
		if len(buf) < 4 {return}
		key_len =
			((u32(buf[0]) & 0x7f) << 24) + (u32(buf[1]) << 16) + (u32(buf[2]) << 8) + u32(buf[3])
		curr += 4
	} else {
		key_len = u32(buf[0])
		curr += 1
	}

	if (buf[curr] & 128) == 128 {
		val_len =
			((u32(buf[curr]) & 0x7f) << 24) +
			(u32(buf[curr + 1]) << 16) +
			(u32(buf[curr + 2]) << 8) +
			u32(buf[curr + 3])
		curr += 4
	} else {
		val_len = u32(buf[curr])
		curr += 1
	}

	if len(buf) < (curr + int(key_len) + int(val_len)) {return}

	key = strings.string_from_ptr(&buf[curr], int(key_len))
	curr += int(key_len)
	value = strings.string_from_ptr(&buf[curr], int(val_len))
	n = curr + int(val_len)

	return
}
