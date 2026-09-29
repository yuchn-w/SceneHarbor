#!/usr/bin/env python3
"""Remove build-machine home paths from Mach-O C-string sections only.

Replacements have exactly the same byte length. Code, symbols, load commands,
and runtime resource paths are not rewritten. Re-sign modified binaries after
running this tool, then regenerate the distribution's checksum manifests.
"""
import argparse
from pathlib import Path
import struct


def sanitize(path: Path) -> int:
    data = bytearray(path.read_bytes())
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected a little-endian 64-bit Mach-O: ' + path.name)
    position = 32
    replacements = 0
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, position)
        if command == 0x19:
            sections = struct.unpack_from('<I', data, position + 64)[0]
            for index in range(sections):
                section = position + 72 + index * 80
                name, _, _, size, offset = struct.unpack_from('<16s16sQQI', data, section)
                if name.rstrip(b'\0') != b'__cstring':
                    continue
                end = offset + size
                cursor = offset
                while cursor < end:
                    stop = data.find(b'\0', cursor, end)
                    if stop < 0:
                        stop = end
                    start = data.find(b'/Users/', cursor, stop)
                    if start >= 0:
                        suffix = data.find(b'SceneRenderer/', start, stop)
                        if suffix < 0:
                            suffix = data.rfind(b'/', start, stop) + 1
                        length_to_replace = suffix - start
                        if length_to_replace < 8:
                            raise ValueError('Unexpected build-path shape in ' + path.name)
                        replacement = b'/build/' + b'_' * (length_to_replace - 8) + b'/'
                        data[start:suffix] = replacement
                        replacements += 1
                    cursor = stop + 1
        position += length
    if b'/Users/' in data:
        raise ValueError('A user path remains outside supported C-string entries: ' + path.name)
    if replacements:
        path.write_bytes(data)
    return replacements


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binaries', nargs='+', type=Path)
    for target in parser.parse_args().binaries:
        print(f'{target.name}: sanitized {sanitize(target)} build paths')
