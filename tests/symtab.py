#!/usr/bin/env python3
"""The function names of the addresses of a program of Cosmopolitan.

A program of cosmocc has the symbol table of each CPU in its zip:
.symtab.amd64 and .symtab.arm64 (libc/runtime/symbols.internal.h of
Cosmopolitan). The sample of macOS gives only addresses for such a
program ("??? (in <unknown binary>) [0x8008485bc]"). This script adds the
name of the function and the offset in it.

    python3 tests/symtab.py SYMTAB ADDRESS...   # one line for each address
    python3 tests/symtab.py SYMTAB < sample     # the text, with the names

Get SYMTAB with: unzip -p PROGRAM.com .symtab.arm64 > SYMTAB
"""
import bisect
import re
import struct
import sys

MAGIC = 0x544D5953  # "SYMT"


def load(path):
    """The table: (base, starts, ends, names)."""
    with open(path, "rb") as f:
        data = f.read()
    magic, abi, count = struct.unpack_from("<IIQ", data, 0)
    if magic != MAGIC or abi != 1:
        raise ValueError("not a symbol table of Cosmopolitan")
    base = struct.unpack_from("<q", data, 32)[0]
    names_offset, name_base_offset = struct.unpack_from("<II", data, 64)
    starts, ends, names = [], [], []
    for i in range(count):
        start, end = struct.unpack_from("<II", data, 72 + 8 * i)
        offset = struct.unpack_from("<I", data, names_offset + 4 * i)[0]
        first = name_base_offset + offset
        starts.append(start)
        ends.append(end)
        names.append(data[first:data.index(b"\0", first)].decode(errors="replace"))
    return base, starts, ends, names


def name(table, address):
    """NAME+0xOFFSET, or None for an address outside each function."""
    base, starts, ends, names = table
    offset = address - base
    i = bisect.bisect_right(starts, offset) - 1
    if i < 0 or offset > ends[i]:
        return None
    return "%s+%#x" % (names[i], offset - starts[i])


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    try:
        table = load(argv[1])
    except (OSError, ValueError, struct.error) as e:
        # The text goes out with no change: a bad table must not hide it.
        sys.stderr.write("symtab.py: %s: %s\n" % (argv[1], e))
        if len(argv) > 2:
            return 1
        sys.stdout.write(sys.stdin.read())
        return 0
    if len(argv) > 2:
        for arg in argv[2:]:
            print("%s %s" % (arg, name(table, int(arg, 16)) or "?"))
        return 0

    def add(match):
        found = name(table, int(match.group(1), 16))
        return match.group(0) + (" " + found if found else "")

    for line in sys.stdin:
        sys.stdout.write(re.sub(r"\[(0x[0-9a-fA-F]+)\]", add, line))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
