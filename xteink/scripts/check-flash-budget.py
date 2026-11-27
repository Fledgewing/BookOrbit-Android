#!/usr/bin/env python3
"""Check the actual OTA image against the smallest slot in its generated table."""
import pathlib
import struct
import sys


def check(image, table):
    data = pathlib.Path(table).read_bytes()
    slots = {}
    for offset in range(0, len(data) - 31, 32):
        magic, kind, subtype, address, size = struct.unpack_from('<HBBII', data, offset)
        if magic != 0x50AA:
            break
        if kind == 0 and subtype in (0x10, 0x11):
            if subtype in slots or not size:
                raise ValueError('invalid OTA slots')
            slots[subtype] = size
    if set(slots) != {0x10, 0x11}:
        raise ValueError('expected ota_0 and ota_1 in generated partition table')
    slot = min(slots.values())
    used = pathlib.Path(image).stat().st_size
    gate = slot * 995 // 1000
    print(f'{used} of {slot} bytes ({100 * used / slot:.2f}%); '
          f'{slot - used} bytes headroom; {gate - used} bytes under the 99.5% gate')
    return used <= gate


if __name__ == '__main__':
    try:
        sys.exit(0 if check(*sys.argv[1:]) else 1)
    except (ValueError, OSError, TypeError) as error:
        sys.exit(str(error))
