package fcgi

import "core:strconv"
import "core:strings"

combine_u16 :: #force_inline proc "contextless" (b1, b0: u8) -> u16 {
	return (cast(u16)b1 << 8) + cast(u16)b0
}

split_u16 :: #force_inline proc "contextless" (num: u16) -> (b1, b0: u8) {
	tmp := (num & 0b1111_1111_0000_0000) >> 8
	b1 = cast(u8)tmp
	tmp = num & 0b1111_1111
	b0 = cast(u8)tmp
	return
}

parse_params :: proc(buf: []u8, params: ^map[string]string) {
	rem := buf[:]

	for {
		if len(rem) == 0 {return}
		n, k, v := parse_key_value_pair(rem)
		if n == 0 {return}
		params[k] = v
		rem = rem[n:]
	}
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

@(private)
MAX_4B :: 0xEFFF_FFFF

@(require_results)
serialize_map :: proc(sb: ^strings.Builder, m: map[string]string) -> (err: Serialize_Error) {
	for key, value in m {
		serialize_key_value_pair(sb, key, value) or_return
	}

	return
}

@(require_results)
serialize_key_value_pair :: proc(sb: ^strings.Builder, key, value: string) -> (err: Serialize_Error) {
	if len(key) <= 0b0111_1111 {
		strings.write_byte(sb, byte(len(key)))
	} else if len(key) <= MAX_4B {
		write_u32(sb, u32(len(key)) | (1 << 31))
	} else {
		return .Key_Too_Large
	}

	strings.write_string(sb, key)

	if len(value) <= 0b0111_1111 {
		strings.write_byte(sb, byte(len(value)))
	} else if len(value) <= MAX_4B {
		write_u32(sb, u32(len(value)) | (1 << 31))
	} else {
		return .Value_Too_Large
	}

	strings.write_string(sb, value)

	return
}

@(private)
write_u32 :: proc(sb: ^strings.Builder, num: u32) -> (n: int) {
	buf: [32]byte
	s := strconv.write_bits(buf[:], u64(num), 10, false, 32, strconv.digits, nil)
	return strings.write_string(sb, s)
}
