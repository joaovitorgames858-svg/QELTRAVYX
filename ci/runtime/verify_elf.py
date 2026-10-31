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
    if size != 56 or count == 0 or count > 256 or offset + size * count > len(data):
        raise ValueError('Invalid ELF program header table')
    interpreter = None
    loads, dynamics = [], []
    for i in range(count):
        p_type, flags, start, vaddr, _, length, _, align = struct.unpack_from('<IIQQQQQQ', data, offset+i*size)
        if start + length > len(data):
            raise ValueError('Truncated ELF segment')
        if p_type == 1:
            loads.append((vaddr, start, length))
        if p_type == 2:
            dynamics.append((start, length))
        if p_type == 3:
            interpreter = data[start:start+length].rstrip(b'\0')
        if p_type == 1 and (align < 16384 or flags & 3 == 3):
            raise ValueError('Require 16 KiB LOAD alignment and no writable/executable segment')
    if interpreter != b'/system/bin/linker64':
        raise ValueError('Not an Android Bionic executable')
    if b'libc.so.6\0' in data or b'ld-linux' in data or b'/com.termux/' in data:
        raise ValueError('Host/Termux linkage is forbidden')
    needed, strings = [], None
    for start, length in dynamics:
        for pos in range(start, start + length, 16):
            tag, value = struct.unpack_from('<QQ', data, pos)
            if tag == 0: break
            if tag == 1: needed.append(value)
            if tag == 5: strings = value
            if tag in (15, 29):
                raise ValueError('Embedded RPATH/RUNPATH is forbidden; use APK library directory')
    if strings is None:
        raise ValueError('Missing dynamic string table')
    string_offset = next((start + strings - addr for addr, start, size in loads if addr <= strings < addr + size), None)
    if string_offset is None: raise ValueError('Invalid dynamic string table')
    libraries = []
    allowed = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libz.so', 'libc++_shared.so'}
    for offset in needed:
        start = string_offset + offset
        end = data.find(b'\0', start, start + 256)
        if end == -1: raise ValueError('Invalid DT_NEEDED')
        library = data[start:end].decode('ascii')
        if library not in allowed: raise ValueError('Unbundled/unknown dependency: ' + library)
        libraries.append(library)
    if 'libc++_shared.so' in libraries and not (Path(path).parent / 'libc++_shared.so').is_file():
        raise ValueError('Missing bundled libc++_shared.so')
    print('DT_NEEDED: ' + ', '.join(libraries))
    print(str(path) + ': Android AArch64 PIE, linker64, 16 KiB segments (execution NOT tested)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    verify(parser.parse_args().binary)
