#!/usr/bin/env python3
"""Turn a raw .bin into a Tcl fragment OpenOCD can source.

OpenOCD's Jim Tcl has no dependable binary file I/O, and `load_image` only
targets memory — useless without a flash driver, which is the whole problem.
Emitting the image as a word list sidesteps both.

    ./tools/bin2tcl.py build/beacon/x2-beacon.bin 0x08000000 > /tmp/img.tcl
"""
import sys, struct

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, addr = sys.argv[1], int(sys.argv[2], 0)

    data = open(path, 'rb').read()
    if addr % 128:
        sys.exit(f"error: 0x{addr:08X} is not 128-byte page aligned")
    if len(data) % 4:
        data += b'\xff' * (4 - len(data) % 4)   # pad to a word

    words = struct.unpack(f'<{len(data)//4}I', data)

    print(f"# {path}: {len(data)} bytes -> 0x{addr:08X}")
    print(f"set ::IMG_ADDR 0x{addr:08X}")
    print("set ::IMG_WORDS {")
    for i in range(0, len(words), 8):
        print("  " + " ".join(f"0x{w:08X}" for w in words[i:i+8]))
    print("}")

main()
