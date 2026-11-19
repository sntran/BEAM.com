#!/usr/bin/env python3
# generated.py COSMO: makes the changes to the generated files of COSMO
# (the source of Cosmopolitan 4.0.2), for the Windows layer of aarch64.
# The file win-arm64.patch has the changes to the other files
# (build_cosmo_libc in scripts/steps.sh).
#
# 1. libc/nt: the aarch64 body of each stub of a Windows function.
#    Before, the body returns 0. After, it goes to the function whose
#    address is in the import slot __imp_NAME. The start code fills each
#    slot on Windows on ARM64.
# 2. libc/sysv/dos2errno: the table from a Windows error to an errno
#    value is also for aarch64. The image is above 4 GiB, so the field
#    of aarch64 is the distance from the field to the errno value.
# 3. libc/sysv/consts: each errno value also links its part of the
#    table on aarch64.
import pathlib
import re
import sys

STUB = re.compile(r"(#elif defined\(__aarch64__\)\n)\tmov\tx0,#0\n(\tret\n)?")
SLOT = re.compile(r"\b(__imp_\w+)")
TABLE_OLD = (
    "#ifndef __x86_64__\n        .end\n#endif\n"
    "\t.macro\t.e doscode systemv\n\t.short\t\\doscode\n\t.long\t\\systemv\n"
)
TABLE_NEW = (
    "\t.macro\t.e doscode systemv\n\t.short\t\\doscode\n"
    "#ifdef __aarch64__\n\t.long\t\\systemv - .\n#else\n\t.long\t\\systemv\n#endif\n"
)
YOINK = re.compile(r"#ifdef __x86_64__\n(\.yoink kDos2Errno\.\w+\n)#endif\n")


def stub(text):
    """Gives the new text of one stub file, or None for no change."""
    m = STUB.search(text)
    slot = SLOT.search(text)
    if not m or not slot:
        return None
    name = slot.group(1)
    body = f"\tadrp\tx16,{name}\n\tldr\tx16,[x16,#:lo12:{name}]\n\tbr\tx16\n"
    return text[: m.start()] + m.group(1) + body + text[m.end() :]


def table(text):
    """Gives the new text of one part of the error table, or None."""
    if TABLE_OLD not in text:
        return None
    return text.replace(TABLE_OLD, TABLE_NEW)


def yoink(text):
    """Gives the new text of one errno file, or None."""
    new = YOINK.sub(r"\1", text)
    return None if new == text else new


def change(root, folder, function):
    count = 0
    for path in sorted(pathlib.Path(root, folder).rglob("*.S")):
        new = function(path.read_text())
        if new is not None:
            path.write_text(new)
            count += 1
    print(f"{folder}: {count} files changed")


def main():
    change(sys.argv[1], "libc/nt", stub)
    change(sys.argv[1], "libc/sysv/dos2errno", table)
    change(sys.argv[1], "libc/sysv/consts", yoink)


if __name__ == "__main__":
    main()
