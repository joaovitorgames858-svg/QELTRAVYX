#!/usr/bin/env python3
"""Reject glibc, wrong ABI, shared libraries masquerading as executables and W+X."""
import argparse
from pathlib import Path
import struct


def verify(path):
    data = Path(path).read_bytes()
    if data[:7] != b'\x7fELF\x02\x01\x01' or len(data) < 64:
        raise ValueError('Expected ELF64 little-endian')
    kind, machine = struct.unpack_from('<HH', data, 16)
    if kind != 3 or machine != 183 or struct.unpack_from('<Q', data, 24)[0] == 0:
        raise ValueError('Expected AArch64 PIE executable with entry point')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    interpreter = None
    for i in range(count):
        p_type, flags, start, _, _, length, _, align = struct.unpack_from('<IIQQQQQQ', data, offset+i*size)
        if p_type == 3:
            interpreter = data[start:start+length].rstrip(b'\0')
        if p_type == 1 and (align < 16384 or flags & 3 == 3):
            raise ValueError('Require 16 KiB LOAD alignment and no writable/executable segment')
    if interpreter != b'/system/bin/linker64':
        raise ValueError('Not an Android Bionic executable')
    if b'libc.so.6\0' in data or b'ld-linux' in data or b'/com.termux/' in data:
        raise ValueError('Host/Termux linkage is forbidden')
    print(str(path) + ': Android AArch64 PIE, linker64, 16 KiB segments (execution NOT tested)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    verify(parser.parse_args().binary)
