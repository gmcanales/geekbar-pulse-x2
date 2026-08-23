#!/usr/bin/env python3
"""Turn a raw .bin into a Tcl fragment OpenOCD can source.

OpenOCD's Jim Tcl has no dependable binary file I/O, and `load_image` only
targets memory — useless without a flash driver, which is the whole problem.
Emitting the image as a word list sidesteps both.

    ./tools/bin2tcl.py build/beacon/x2-beacon.bin 0x08000000 > /tmp/img.tcl
    ./tools/bin2tcl.py dump.bin 0x08000000 --var REF_WORDS --count 32 > /tmp/ref.tcl
"""
import sys, struct

def main():
    args = sys.argv[1:]
    var, offset, count = "IMG", 0, None
    out = []
    i = 0
    while i < len(args):
        if args[i] == "--var":    var = args[i+1]; i += 2
        elif args[i] == "--offset": offset = int(args[i+1], 0); i += 2
        elif args[i] == "--count":  count = int(args[i+1], 0); i += 2
        else: out.append(args[i]); i += 1
    if len(out) != 2:
        sys.exit(__doc__)
    path, addr = out[0], int(out[1], 0)

    data = open(path, 'rb').read()[offset:]
    if count is not None:
        data = data[:count * 4]
    if addr % 128:
        sys.exit(f"error: 0x{addr:08X} is not 128-byte page aligned")
    if len(data) % 4:
        data += b'\xff' * (4 - len(data) % 4)   # pad to a word

    words = struct.unpack(f'<{len(data)//4}I', data)

    print(f"# {path}: {len(data)} bytes -> 0x{addr:08X}")
    print(f"set ::{var}_ADDR 0x{addr:08X}")
    print(f"set ::{var}_WORDS {{")
    for i in range(0, len(words), 8):
        print("  " + " ".join(f"0x{w:08X}" for w in words[i:i+8]))
    print("}")

main()
