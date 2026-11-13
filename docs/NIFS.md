# NIF libraries

`beam.com` is one static file, so it cannot load a native NIF library
(a `.so` or `.dll` file): ERTS has no `dlopen()` in it. It can load two
other kinds of NIF:

- A native NIF object: the `.o` files of the NIF for x86_64 and aarch64,
  from `cosmocc`. `beam.com` links the object into the running program,
  so the NIF runs at the speed of native code. See "Native NIF objects"
  below.
- A NIF library that is compiled to WebAssembly. One `.wasm` file then
  works on all the systems and CPUs of `beam.com`.

When `erlang:load_nif(PATH, Info)` finds no static NIF for the module,
it looks for these files, in this order:

1. `PATH.x86_64.o` or `PATH.aarch64.o` (the CPU of the computer): a
   native NIF object.
2. `PATH.x86_64.aot` or `PATH.aarch64.aot`: an AOT file, a WebAssembly
   module compiled to machine code. It runs at almost the speed of a
   native NIF.
3. `PATH.wasm`: the WebAssembly module. The interpreter of WAMR runs it.

The C code of the NIF does not change: the same `ERL_NIF_INIT`, the
same `enif_*` functions. `beam.com INPUT -o OUTPUT` copies the files in
`priv/` into the zip of OUTPUT, as for any `priv` file, and `load_nif`
reads them from the zip: nothing goes onto the disk.

How you make the `.wasm` file is your choice: any C compiler for
`wasm32-wasip1` works. This page shows Zig and wasi-sdk. A custom build
of `beam.com` can also link the NIF as a static NIF (see "Custom builds"
in [`BUILDING.md`](BUILDING.md)).

## Native NIF objects

A native NIF object is the NIF as `cosmocc` compiles it, with no link:
`cosmocc -c` gives one object for x86_64 and one for aarch64
(`.aarch64/`). For a NIF with more than one file, `ld -r` joins the
objects of each CPU into one object:

```sh
include=$(beam.com --nif-include)
cosmocc -O2 -I"$include" -c c_src/my_nif.c -o my_nif.o
cosmocc -O2 -I"$include" -c c_src/util.c -o util.o
x86_64-linux-cosmo-ld -r -o priv/my_nif.x86_64.o my_nif.o util.o
aarch64-linux-cosmo-ld -r -o priv/my_nif.aarch64.o .aarch64/my_nif.o .aarch64/util.o
```

Then `erlang:load_nif("priv/my_nif", 0)` loads `priv/my_nif.x86_64.o` or
`priv/my_nif.aarch64.o`. The same object works on each system of
`beam.com` with that CPU: Linux, macOS, Windows, and the BSDs.

A NIF in C++ links the members of `libcxx.a` (libc++) that it needs into
its object, and keeps one global name. The program gives the object
libc++abi: the exceptions, `__gxx_personality_v0`, the type info, and
`operator new`. So the process has one exception runtime:

```sh
cosmoc++ -O2 -I"$include" -c c_src/my_nif.cpp -o my_nif.o
lib=$(dirname "$(command -v cosmocc)")/..
x86_64-linux-cosmo-ld -r -o nif.o my_nif.o "$lib/x86_64-linux-cosmo/lib/libcxx.a"
x86_64-unknown-cosmo-objcopy --keep-global-symbol=nif_init nif.o priv/my_nif.x86_64.o
aarch64-linux-cosmo-ld -r -o nif64.o .aarch64/my_nif.o "$lib/aarch64-linux-cosmo/lib/libcxx.a"
aarch64-unknown-cosmo-objcopy --keep-global-symbol=nif_init nif64.o priv/my_nif.aarch64.o
```

The loader removes the sections that no live section names, as
`ld --gc-sections` does. The roots are the sections of the global
symbols, the constructors, and the sections with C names. So a function
that the NIF never reaches can name a symbol that the program does not
have, as in a static link. With one global name (`objcopy
--keep-global-symbol`), the loader keeps only the code that the NIF
uses: the object of `ex_pdfium` (PDFium, 38 MB, 72,789 sections) takes
9.6 MB of memory. A live section of size 0 also gets an address: Rust
puts each static of size 0 (such as `log::logger::NOP`) in its own empty
section, and the code takes its address.

- The entry of the object is `LIB_nif_init`, with `LIB` the name of the
  file (`-DSTATIC_ERLANG_NIF_LIBNAME=LIB`), else `nif_init`, as for a
  dynamic library. Else it is the one global function `NAME_nif_init`
  of the object: Rustler loads `priv/native/libCRATE`, and the object of
  the store has `CRATE_nif_init`.
- The object can call each `enif_*` function, and the functions of the
  libc in
  [`c_src/cosmo/beam_com_nif_libc.h`](../c_src/cosmo/beam_com_nif_libc.h):
  the strings, the memory, `stdio`, the math functions, the threads, the
  time, the files, and `__hostos` (the system tests of Cosmopolitan, such
  as `IsWindows()`). A symbol that is not there stops the load, and the
  error of `load_nif/2` names it.
- The constructors of the object run at the load. A second `load_nif/2`
  of the same file (an upgrade of the module) gives the same copy of the
  object, as `dlopen()` does: its static data stays. The program keeps
  the object until it stops.
- Thread-local data works: `_Thread_local` of C, and the TLS of Rust
  (`thread_local!`, and the threads of rayon). The program has one
  static TLS area of 32 KiB for all the objects, and each thread has its
  own copy. A thread that started before the load gets the initial values
  too. The initial values that are not zero go into the template of the
  thread data of the program: a system that refuses this change (OpenBSD
  can make the program immutable) refuses such an object.
- On aarch64, the code of Rust reads the thread pointer from
  `tpidr_el0`, and Cosmopolitan keeps it in `x28`. The loader changes
  each `mrs xN, tpidr_el0` of an object to `mov xN, x28`, as cosmocc
  does in the code of the program. On XNU, `tpidr_el0` is not `x28`.
- C++ works: static constructors, exceptions (also across the frames of
  the object), `dynamic_cast`, function-local statics, and `thread_local`
  objects with destructors.

`BEAM_COM_NIF_DEBUG=1` writes `nif_native: FILE` for each object that
loads. `BEAM_COM_NIF_NATIVE=0` turns the loader off.

### The NIFs of the store

The store of parts (docs/BUILDING.md) has the NIF of each package of
`EXTRA_NIFS` as the static build links it: `LIB.a` and `.aarch64/LIB.a`,
with the function `LIB_nif_init` and the libraries that it needs.
`scripts/nif_object.sh` makes the native NIF objects of such a part:

```sh
sh scripts/nif_object.sh build/cosmocc vix DIR nifs/vix-0.42.0
sh scripts/nif_object.sh build/cosmocc rustycsv DIR nifs/rusty_csv-0.4.6 native/librustycsv
```

The first command writes `vix.x86_64.o` and `vix.aarch64.o`, the second
`native/librustycsv.x86_64.o` and `.aarch64.o`: the paths where the
packages load them. `ld -r -u LIB_nif_init` takes the members of the
archive that the NIF needs, and the members of `libcxx.a` that they
need. The object keeps one global name, `LIB_nif_init`.
`scripts/steps.sh nif_recipes` gives the version, the library and the
path of each package of `EXTRA_NIFS`.

| NIF | Object (x86_64) | Memory | Load |
|---|---|---|---|
| `vix` 0.42.0 (libvips 8.18, glib, AVIF, GIF, ICC, SVG) | 31 MB | 17.8 MB | 300 ms |
| `ex_pdfium` 0.6.0 (PDFium) | 26 MB | 9.6 MB | 140 ms |
| `rusty_csv` 0.4.6 | 1.8 MB | | 15 ms |

The libc of `beam_com_nif_libc.h` has each name that these objects
need: for glib, also the sockets, `posix_spawn`, `iconv` and the
resolver. These names add about 0.5 MB to `beam.com`.
`tests/cosmo/nif_needs.c` (`nif_needs.com OBJECT...`) loads each object
of its CPU with this table and with no constructors. It writes each
name that the object needs and that the table does not have, all in one
run. CI runs it on the objects of the store before a program loads
them.

### The NIF files of beam.com

The directory `lib/beam_com/priv/nifs/APP-VSN` of the zip of `beam.com`
holds files of the priv directory of the package `APP` of version
`VSN`: a NIF library in WebAssembly (lazy_html), or native NIF objects.
For example, `nifs/vix-0.42.0/vix.x86_64.o` and
`nifs/rusty_csv-0.4.6/native/librustycsv.x86_64.o`. `beam.com --version`
names these packages ("NIF files"). The list comes from the directory,
so a `beam.com` with more files in its zip needs no other build:

- `beam.com DIR -o OUT` (a Mix project) writes the files of each
  package into its priv directory before its code compiles (vix loads
  its NIF then), and puts them into OUT.
- A Mix project that Mix builds (a release of Mix, for example with git
  deps or `assets.deploy`): after `mix compile`, the builder writes the
  files of each dep of the source of a directory (see below) into
  `_build/ENV/lib/APP/priv`. Thus `assets.deploy` can use the NIF, and
  the release has it. This is also for a package that compiles no NIF,
  such as tailwind.com, whose module loads `priv/native/libtailwind_nif`
  of its application. A file with the same bytes stays. For a dep of
  another source or version, the builder writes no file, and one line
  names the two.

A directory `APP-VSN` is for the Hex package `APP` of version `VSN`,
unless it has a file `SOURCE`. Its one line names the package of the
files, because two packages can have the same application and version
(the Hex package `tailwind` and tailwind.com):

| `SOURCE` | The files are for |
|---|---|
| no file, or `hex` | the Hex package `APP` of hex.pm, of the version `VSN` |
| `hex PACKAGE` | the Hex package `PACKAGE` (the option `hex:` of the dep), of the version `VSN` |
| `git URL` | the git dep of `URL`, of the version `VSN` |
| `git URL commit=SHA tag=TAG` | the git dep of `URL` at a commit that starts with `SHA` (7 to 40 hexadecimal digits), or with `tag: TAG` in `mix.exs`. `VSN` is only a name: the version is not checked |

The URL compares with no `/` or `.git` at the end, and with the scheme
and the host in lower case: `github: "sntran/tailwind.com"` in
`mix.exs` is `https://github.com/sntran/tailwind.com.git`. With
`commit=` and `tag=`, one of them must match. A directory with a commit
or a tag comes before one without. A line `#` is a comment. A file of
another form matches no dep. `SOURCE` does not go into the priv
directory. The hooks of `make` and Rustler and the builder of a plain
Mix project use only the directories of a Hex package of the name of
the directory. `beam.com --version` gives a source that is not `hex`
after the name. For example, the objects of a commit of tailwind.com:

```sh
printf 'git https://github.com/sntran/tailwind.com commit=c0be553\n' > SOURCE
beam.com scripts/assemble.erl -- beam.com beam-tailwind.com \
  lib/beam_com/priv/nifs/tailwind-c0be553/SOURCE=SOURCE \
  lib/beam_com/priv/nifs/tailwind-c0be553/native/libtailwind_nif.x86_64.o=libtailwind_nif.x86_64.o \
  lib/beam_com/priv/nifs/tailwind-c0be553/native/libtailwind_nif.aarch64.o=libtailwind_nif.aarch64.o
```

A custom build with `nifs+=tailwind` ([`BUILDING.md`](BUILDING.md),
`FILE_NIFS`) does this with the objects of a release of tailwind.com.
`scripts/file_nifs.sh` has the tag, the commit and the SHA-256 of each
object, and writes `SOURCE` with `commit=` and `tag=`. Thus the dep
`{:tailwind, github: "sntran/tailwind.com", tag: "v0.3.0"}` gets the
NIF, and the version of Tailwind CSS (4.x) stays a choice of the
project (`config :tailwind, version:`). The Hex package `tailwind` gets
no file, and it uses its own program, as before.

- `beam.com mix compile`: `make` of `elixir_make` (vix) copies them into
  `MIX_APP_PATH/priv`, and the module `Rustler` of `beam.com` (rusty_csv,
  ex_pdfium) copies them into the priv directory of the package and
  loads `code:priv_dir(APP)/native/libCRATE`.

The version of the package must be a version of its directory. A
linked NIF of the same package wins: ERTS finds a static NIF first.

The NIF of vix sends each object that a resource destructor frees to
the process `Elixir.Vix.Nif.Janitor`, as `Vix.Nif` starts it. Without
this process, the destructor makes new resources with no end.

### A program assembled from parts

A program with native NIF objects needs no compiler and no link: it is
a program and new files in its zip. `scripts/assemble.erl` makes such a
program as a server can stream it:

```sh
beam.com scripts/assemble.erl -- BASE OUT lib/APP-VSN/priv/LIB.x86_64.o=FILE ...
beam.com scripts/assemble.erl -- BASE OUT lib/APP-VSN/priv/=DIR ...
```

A spec `PREFIX/=DIR` adds each regular file of DIR, with the path
`PREFIX/PATH`, in the sequence of the names.

The license texts of a part (`licenses-pdfium` of ex_pdfium) go into
`licenses/NAME` of OUT, as in the static build, and each program that
OUT builds keeps them. With `beam.com` as BASE and the objects of the store as NIF files of
`beam.com`, OUT is a `beam.com` that builds a project with vix,
rusty_csv or ex_pdfium from hex.pm, with no static NIF of them:

```sh
beam.com scripts/assemble.erl -- beam.com beam-vix.com \
  lib/beam_com/priv/nifs/vix-0.42.0/vix.x86_64.o=nifs/vix-0.42.0/vix.x86_64.o \
  lib/beam_com/priv/nifs/vix-0.42.0/vix.aarch64.o=nifs/vix-0.42.0/vix.aarch64.o
./beam-vix.com my_project -o my_project.com
```

OUT has these parts, in this order:

1. The bytes of BASE up to its central directory, with no change. The
   executable headers and the offsets of the entries of BASE stay
   correct.
2. A local entry for each new file, with its deflated bytes.
3. The central directory of BASE, and an entry for each new file.
4. A new end record.

The sizes of the parts give the length of OUT before the first byte. So
a server that keeps BASE and the deflated files (with their CRC-32) can
send OUT with a `Content-Length`, from the first byte, with no work for
each request but a copy. The script writes the length first, then
writes OUT with no seek, and then checks the length. The same inputs
give the same bytes. The script does not support ZIP64: OUT has fewer
than 65,535 entries and less than 4 GiB.

A local entry has no offset, so the entries of one package are the
same bytes in each program. Only the central directory changes with
the set of packages. `--parts` cuts the programs of each set into
segments, in DIR:

```sh
beam.com scripts/assemble.erl -- --parts BASE DIR KEY URL PKG:SPEC ...
```

- `beam-p.KEY.head`: the bytes of BASE up to its central directory.
- `beam-p.KEY.PKG.part`: the local entries of the files of PKG.
- `beam-p.KEY.SET.tail`: the central directory and the end record of
  the program of the packages of SET.
- `beam-p.plus.SET.txt`: the segments of SET, one on each line, after
  the text URL.

SET is each set of packages that is not empty: the names in the
sequence of `sort`, with a dot between them. The segments of a list,
one after the other, are the bytes of OUT with the specs of these
packages, in that sequence. `tests/run.sh` compares the two. The FIFO
beam.com streams them for a build URL ([`BUILDING.md`](BUILDING.md), "A
build URL").

Caution: a native NIF object runs in the VM with all of its rights, as
a native NIF does. A crash of the object stops the VM. A NIF in
WebAssembly cannot do this.

## Speed

The NIF of `bcrypt_elixir` as a native NIF object runs at the speed of
the same NIF as a static NIF: one hash with cost 12 took 241 to 243 ms
as an object, and 237 to 269 ms as a static NIF, on one x86_64
computer. The two give the same hash.

The NIF of `rusty_csv` (Rust) also loads as an object, from the object
of its static NIF: `parse_string_parallel` parses 200,000 rows in 260 ms
with the threads of rayon. The NIF of `ex_pdfium` (Rust and PDFium in
C++) loads as an object too, with libc++: it makes, opens, renders and
reads PDF documents.

The bcrypt NIF of `bcrypt_elixir`, one hash with cost 12, on x86_64:

| Mode | Time |
|---|---|
| Native NIF | 255 ms |
| AOT file (`--bounds-checks=1`, generic CPU) | 318 ms |
| Interpreter (`.wasm`) | 2,400 ms |
| The WebAssembly runtime of the edge (the engine of Node.js 26) | 339 ms |

`exqlite` (SQLite), 10,000 inserts in one transaction into a database
file: 195 ms with the AOT file, 543 ms with the interpreter.

A call into the library costs about 0.2 µs with the AOT file, and each
`enif_*` function that the module calls about 70 ns (x86_64, 2.8 GHz).
A call of a native NIF costs about 20 ns.

## Make the `.wasm` file

1. Get the headers. `beam.com --nif-include` writes `erl_nif.h` and the
   files that it includes (with the C types of wasm32) to the cache of
   `beam.com`, and prints their directory.
2. Compile the C files for `wasm32-wasip1`, as a reactor (a module with
   no `main`), with these headers.

With [Zig](https://ziglang.org/):

```sh
zig cc -target wasm32-wasi -O2 -s -mexec-model=reactor \
    -I"$(beam.com --nif-include)" -o priv/my_nif.wasm c_src/my_nif.c
```

With [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) (or a clang
with a WASI sysroot):

```sh
$WASI_SDK/bin/clang --target=wasm32-wasip1 -O2 -s -mexec-model=reactor \
    -I"$(beam.com --nif-include)" -o priv/my_nif.wasm c_src/my_nif.c
```

The headers make the module a NIF library: `ERL_NIF_INIT` exports
`nif_init`, an allocator and `chdir`, and each `enif_*` function is an
import of the module `env`. So the link needs no other flag.

The file name is the name that the NIF gives to `load_nif/2`, with
`.wasm`: for `erlang:load_nif(filename:join(PrivDir, "my_nif"), 0)`,
the file is `priv/my_nif.wasm`.

A library that uses other C libraries must compile them for
`wasm32-wasip1` too. WASI preview 1 has no threads, no `dlopen()` and
no signals. For SQLite, for example, give `-DSQLITE_THREADSAFE=0
-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_OMIT_WAL=1`, and the emulated
parts of wasi-libc (`-D_WASI_EMULATED_MMAN -lwasi-emulated-mman`, and
the same for `SIGNAL` and `PROCESS_CLOCKS`).

## Make the AOT files

An AOT file holds machine code: compile it with `wamrc`, the AOT
compiler of [WAMR](https://github.com/bytecodealliance/wasm-micro-runtime),
of the WAMR version of `beam.com` (2.4.5; see `WAMR_VERSION` in
`scripts/steps.sh`). Give these options:

```sh
wamrc --target=x86_64 --cpu=x86-64 --bounds-checks=1 \
    -o priv/my_nif.x86_64.aot priv/my_nif.wasm
wamrc --target=aarch64 --cpu=generic --bounds-checks=1 \
    --cpu-features=+reserve-x18,+reserve-x28 \
    -o priv/my_nif.aarch64.aot priv/my_nif.wasm
```

> **Caution:** An AOT file is native code. It runs with all the rights
> of `beam.com`, as a native NIF does. Without `--bounds-checks=1`, an
> access outside the memory of the module can write the memory of
> `beam.com` (`beam.com` runs WebAssembly without guard pages). Without
> `--cpu`, `wamrc` uses the CPU of your computer, and the file can stop
> with an illegal instruction on another computer. On aarch64, without
> `+reserve-x28`, the code can change the register that holds the thread
> pointer of `beam.com`, and the VM crashes; macOS can change x18 at
> any time, so the code must not use it either.

The AOT files are optional: without them, the `.wasm` file runs in the
interpreter. When an AOT file does not load (another WAMR version, or a
system that refuses memory that is both writable and executable), the
`.wasm` file runs.

On macOS with Apple silicon, the AOT code runs from memory with
`MAP_JIT`, as the JIT of the VM does.

## C++ (lazy_html)

[lazy_html](https://hex.pm/packages/lazy_html) 0.1.13 (the HTML parser
of `Phoenix.LiveViewTest`, a C++ NIF with fine and lexbor) works as a
NIF library in WebAssembly: its 93 tests pass with the `.wasm` file and
with the AOT file, also `render_component/3` and `live_isolated/2` of
LiveViewTest.

`beam.com` has this library: a Mix project with `{:lazy_html,
"0.1.13"}` gets it, with no C++ compiler and no download. The tools of
Elixir (`mix.com`, `iex.com`) make elixir_make build lazy_html with
make (the env `force_build` of elixir_make), and the make of `beam.com`
copies `liblazy_html.wasm` and its AOT files into the priv directory of
the package. `beam.com PROJECT -o app.com` puts the same files into the
program. A program with another version of lazy_html gets an error that
names the version of `beam.com`. The files add about 3.4 MB (0.95 MB
compressed) to `beam.com`, and nothing to a program without lazy_html.
[`scripts/lazy_html.sh`](../scripts/lazy_html.sh) builds them again
(`priv/nifs/lazy_html-0.1.13/`).

wasm32-wasi links no C++ exceptions, so fine and lazy_html need a small
change, which a flag turns on:
[`patches/fine/0001-no-exceptions.patch`](../patches/fine/0001-no-exceptions.patch)
(in `deps/fine`) and
[`patches/lazy_html/0001-no-exceptions.patch`](../patches/lazy_html/0001-no-exceptions.patch)
(in the package). Also apply
[`patches/fine/0002-quiet-variant.patch`](../patches/fine/0002-quiet-variant.patch):
without it, `from_tree` of a deep tree takes a time that grows with the
square of the depth, also natively (`docs/UPSTREAM.md`, F2). Then, with
lexbor at the commit of the `Makefile` of lazy_html:

```sh
# lexbor: each .c file of source/lexbor, but ports/windows_nt
zig cc -target wasm32-wasi -O2 -std=c99 -DLEXBOR_STATIC \
    -D_POSIX_C_SOURCE=199309L -I"$LEXBOR/source" -c FILE.c -o FILE.o
zig ar rcs liblexbor.a *.o
zig c++ -target wasm32-wasi -mexec-model=reactor -O3 -std=c++17 \
    -fno-exceptions -DFINE_NO_EXCEPTIONS -DLEXBOR_STATIC -fvisibility=hidden \
    -I"$(beam.com --nif-include)" -Ideps/fine/c_include -I"$LEXBOR/source" \
    c_src/lazy_html.cpp liblexbor.a -s -o priv/liblazy_html.wasm
```

A document of 553 KB, the median of 15 calls:

| Step | Native NIF | AOT file | Interpreter |
|---|---|---|---|
| `from_document` | 16.7 ms | 29.9 ms | 233 ms |
| `query` | 1.1 ms | 1.5 ms | 12.8 ms |
| `to_html` | 3.7 ms | 6.0 ms | 46.5 ms |
| `to_tree` | 11.9 ms | 40.3 ms | 122.6 ms |

16 processes that use the library at the same time (the concurrent test
of lazy_html, 21,000 calls): 0.5 s with the AOT file, 110 ms with the
native NIF. The calls into one library run one at a time.

`from_tree` of a tree with a depth of 20,000: 51 ms with the AOT file and
the two patches of fine, 14.7 s with the native NIF of the hex package.
All the tests of lazy_html (and of the bridge) take 3.5 s with the AOT
file.

## Rust (rustler)

rustler 0.38 finds the `enif_*` functions with `dlsym()` at run time,
so it does not compile for `wasm32-wasip1`. A small change to rustler
makes a rustler NIF work:
[`patches/rustler/0001-wasm32-imports.patch`](../patches/rustler/0001-wasm32-imports.patch)
declares the `enif_*` functions as imports of `env` on `target_family =
"wasm"`. A test NIF with integers, strings, lists, binaries, atoms and a
resource passed with it. That change is not in rustler yet. With it:

```sh
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/my_nif.wasm priv/
```

## What a NIF library in WebAssembly can do

`beam.com` gives the module 170 `enif_*` functions: the terms (numbers,
atoms, strings, binaries, tuples, lists, maps and their iterators),
`enif_inspect_binary` and `enif_make_new_binary`, resources with
destructors and down callbacks, the monitors, `enif_alloc_env` and
`enif_send`, the pids and ports, exceptions, `enif_schedule_nif`, the
dirty NIF flags, the time functions, `enif_term_to_binary` and
`enif_binary_to_term`, `enif_snprintf` (with `%T`), the I/O queues
(`enif_ioq_*`) and `enif_inspect_iovec`.

The limits:

- **One call at a time.** The calls into one library run one after the
  other: a WebAssembly module has one stack. Two libraries run at the
  same time. A long call (for example a dirty NIF) makes the other
  calls into the same library wait, also on a normal scheduler.
- **Memory.** The memory of a module grows with no copy on Linux,
  macOS, FreeBSD and NetBSD (it has its maximum size in virtual memory,
  4 GB). On Windows and OpenBSD, the memory has room for twice its pages:
  a growth past that room copies the memory once, and the next growths
  copy nothing until the room is full again. There, the memory of a
  module takes up to twice its size.
- **No threads.** `enif_thread_create` fails. The mutexes, the
  condition variables and the read-write locks do nothing, because the
  calls run one at a time.
- **Not supported:** `enif_select` (it fails: the module has no file
  descriptors of the host), `enif_dynamic_resource_call`, and the
  options of `enif_set_option` (it fails). The module can import an
  unsupported function; a call to one of them stops the call with an
  exception.
- **Output.** `enif_fprintf` writes to the standard error of the VM,
  whatever its `FILE`. `%Lf` (a `long double`, 128 bits in wasm32)
  gives `?`.
- **Copies in I/O queues.** `enif_ioq_enq_binary`, `enif_ioq_enqv` and
  `enif_inspect_iovec` copy the bytes into the memory of the module.
- **No upgrade.** `load_nif/2` of new code, while the old code of the
  module has the library, fails with `upgrade`. `beam.com` then frees
  the module that it loaded for that call, as for any `load_nif/2` that
  ERTS refuses before the `load` callback.
- **Files.** The module can open files, as a native NIF can: WASI gets
  `/`, and the module starts in the work directory of the VM. The
  sandbox of `beam.com` ([`SANDBOX.md`](SANDBOX.md)) limits these files
  too. A later change of the work directory of the VM does not change
  the work directory of the module. When the system does not open `/`
  for WASI, the module runs with no files (`BEAM_COM_NIF_DEBUG` tells).
- **Copies.** `enif_inspect_binary` copies the binary into the memory of
  the module.
- **Errors.** A trap of the module (for example an access out of its
  memory) raises `error:{wasm_trap, Message}` in the calling process.
  The module stays loaded.
- **Checks.** ERTS checks some conditions of the `enif_*` functions only
  in a debug build. A native NIF that breaks one can give Erlang memory
  of the VM, or stop the VM. `beam.com` checks them for a module, and a
  bad call is a trap (`error:{wasm_trap, Message}`):
  - A term in a new term (a tuple, a list, a map, a sub-binary, the
    reason of an exception, a message of a message environment), and
    the result of a NIF, is of the same environment, or immediate (an
    atom, a small integer, a local pid). `enif_make_copy` copies a term
    into an other environment. The parts of a term (of `enif_get_tuple`,
    `enif_get_list_cell`, a map) are of the environment of the term.
  - The result of an exception (`enif_make_badarg`, for example of
    `enif_make_double` of a NaN) is no term. In a new term, the new term
    is the same result, so the call raises the exception, as in ERTS.
  - `enif_make_sub_binary` gets a binary or a bitstring, and a range in
    its whole bytes. An `ErlNifPid` holds a local pid or `undefined`, and
    an `ErlNifPort` a local port.
  - A resource needs a reference for `enif_keep_resource`,
    `enif_make_resource` and the monitors: a reference of the module
    (`enif_alloc_resource`, `enif_keep_resource`), or a term of the
    resource in an open environment (for example of
    `enif_get_resource`). `enif_release_resource` releases only a
    reference of the module. The destructor of a resource cannot keep
    it. `enif_alloc_resource` fails in the `load` callback, where ERTS
    has not completed the new types.
  - `enif_is_current_process_alive`, `enif_consume_timeslice` and
    `enif_schedule_nif` need the environment of a NIF call, and
    `enif_whereis_pid` and `enif_whereis_port` on a dirty scheduler too.
  - A map iterator ends with the environment of its map.
  - Each function of the module that `beam.com` calls (a NIF, `load`,
    `unload`, a destructor, a down callback, the function of
    `enif_schedule_nif`) has the type of its C declaration: `i32`
    parameters (one for each argument) and at most one `i32` result.
    For an other type, the call traps with `indirect call type
    mismatch`.

  On a dirty scheduler, `enif_port_command` to a closed port gives 0
  (ERTS 29.1.1 stops there, O26 in [`UPSTREAM.md`](UPSTREAM.md)).
- **At the edge.** See the next section.

## At the edge

The WebAssembly runtime of the edge part of `app.com` (Cloudflare
Workers, Deno, Node.js, a web page) loads the same `.wasm` file. ERTS itself runs in
WebAssembly there, and the engine of the host (V8) compiles and runs the
module, at about the speed of an AOT file (see "Speed"). The AOT files
are not used, and `beam.com` leaves them out of the edge part.

- **Workers.** A Worker cannot compile WebAssembly at run time. So
  `beam.com --nif-modules app.com .` writes each NIF library of the
  release next to the entry (`nifs/`, and `nifs.js`), and Wrangler
  compiles them. The entry gives them to `serve(app)` of the npm
  package:

  ```js
  import app from './app.com' with { type: 'bytes' };
  import nifs from './nifs.js';
  import { serve } from 'beam.com';

  const beam = serve(app, { nifs });
  ```

  Deno, Node.js and a web page compile the files at run time, and need
  no `nifs.js`.
- **Calls.** A call into the library costs about 3.5 µs, and each
  `enif_*` function that the module calls about 0.3 µs: each call runs
  on its own JSPI stack. A trap stops only that call, with
  `error:{wasm_trap, Message}`.
- **No files.** WASI has no directories there: the standard output and
  error, the clocks and random bytes work. Other functions of WASI fail
  or stop the call with an exception.
- **Snapshots.** A snapshot of a VM (`docs/WORKERS.md`) also holds the
  memory of each NIF library in WebAssembly, and the table slots of its
  functions. The restore makes each library again from its file, with
  the same memory, before the threads of ERTS start.
- The loader adds about 95 KB to `beam.wasm` (26 KB with gzip).

`tests/wasm_diff_test.exs` runs `nif_check` in the runtime, also with
the compiled module of a Worker, and after a snapshot and its restore.

## Debug

- `BEAM_COM_NIF_DEBUG=1`: `beam.com` writes the file that it loads, the
  error of an AOT file that did not load, and the `enif_*` functions
  that the module imports but `beam.com` does not give.
- `BEAM_COM_NIF_AOT=0`: `beam.com` does not use the AOT files.
- `BEAM_COM_NIF_MAP=FILE`: the loader of native NIF objects adds a line
  to FILE for each function of an object that it loads: the address,
  the size, and the name. A sampler or a debugger that does not know the
  object finds the names of its addresses in this file.

## The test

[`tests/programs/native_nif_check`](../tests/programs/native_nif_check)
is an application with a native NIF of two C files, its objects in
`priv/`, and `build.sh`, which makes them. Its checks: the terms,
binaries, maps, resources with destructors, monitors, a thread of
`enif_thread_create` that sends messages, dirty NIFs, `enif_schedule_nif`,
exceptions, the libc, a constructor, 32 processes at the same time, a
load by an other module, a broken object, an object that needs a missing
function, and an upgrade of the module. Its thread-local data
(`native_nif_check_tls.c` and `.S`) has each TLS model of C and Rust: the
first call on each scheduler, each dirty scheduler, and a new thread
checks the initial values. Its C++ part (`native_nif_check_cxx.cpp`)
checks the exceptions, `dynamic_cast`, the containers, a function-local
static, and the destructor of a `thread_local` object. `tests/run.sh` builds it and runs
it on each system. `tests/cosmo/nif_load_check.c` (in `step_test` of
`scripts/steps.sh`) checks the loader with no ERTS: the relocations of
both CPUs, the errors, and 3,000 broken objects.

[`tests/programs/store_nif_check`](../tests/programs/store_nif_check)
loads the NIFs of the store as native NIF objects: vix, rusty_csv and
ex_pdfium. The job Build of CI makes their objects from the parts of the
build (`store_nifs.tar.gz`), and `tests/run.sh` and `tests/run.ps1` put
them in `priv/` and run the program on each system. For vix, it encodes
and decodes JPEG, PNG, WebP, AVIF and GIF, loads an SVG, resizes, and
makes a thumbnail. For ex_pdfium, it makes, saves, opens, reads and
renders a PDF document. For rusty_csv, it parses with the threads of
rayon. Each NIF also runs in eight processes at the same time. Then the
tests assemble the same program with `scripts/assemble.erl`: the program
with no objects, and the six objects as new files. That program must
give the same results. Last, they assemble a `beam.com` with the six
objects and the NIF files of tailwind.com as its NIF files, and it
builds and runs `tests/programs/vix_check`, `rusty_csv_check` and
`ex_pdfium_check` (the packages from hex.pm), and `tailwind_check` (the
git dep tailwind.com of the tag of `scripts/file_nifs.sh`, a Mix
release that builds CSS with the NIF at its start). Before, `nif_needs.com` checks the objects
of the CPU of the system.

[`tests/programs/nif_check`](../tests/programs/nif_check) is an
application with a NIF in C (`c_src/nif_check.c`, and
`c_src/nif_check_mv.c` for a function with four results), its `.wasm`
and AOT files in `priv/`, and `build.sh`, which makes them. `tests/run.sh`
builds it with `-o` and runs its checks on each system, with the AOT
file and with the interpreter. The checks also make each bad call of
"Checks" above, call functions of other types, and make 20 `load_nif/2`
calls that ERTS refuses: on Linux, the address space of the VM must not
grow by their modules.

## How it works

- `c_src/cosmo/beam_com_nif.c`: the loader of native NIF objects. It
  checks the ELF object, maps its sections near the program (the code of
  `cosmocc` uses addresses of 32 bits), does the relocations of x86_64
  and aarch64, adds a stub for a call that is too far, gives each FDE of
  `.eh_frame` to libunwind, and runs the constructors. Thread-local
  data: the comment "Thread-local data" in the file. On macOS arm64 it
  writes the code in `MAP_JIT` memory. `beam_com_nif_hook()` (from
  `main()` of `beam_com.c`) puts it before the loader of WebAssembly in
  the hook `erts_wasm_nif_open`.
- `c_src/cosmo/beam_com_nif_syms.c`: the symbols that an object can use,
  the `enif_*` functions of `erl_nif_api_funcs.h`, the list of
  `beam_com_nif_libc.h`, and libc++abi (`beam_com_nif_cxx.h`, made by
  `scripts/nif_cxx_names.sh` for the version of cosmocc).
- `patches/otp/0003-wasm-nif.patch`: `erts_load_nif` calls the hook
  `erts_wasm_nif_open` before it opens a dynamic library, and the hook
  `erts_wasm_nif_close` with an entry of the first hook that it refuses
  before the `load` callback. The headers of `--nif-include` (`erl_nif.h`
  for `__wasm__`) are from the same patch.
- `patches/wamr/0003-indirect-func-type.patch`: the type of the function
  of an element of the table of a module, so that the bridge checks the
  type of each function that it calls through the table.
- `c_src/wasm/nif_wasm.c`: the hook loads the module in WAMR, reads the
  `ErlNifEntry` of the module, and gives ERTS an entry with a native
  function for each NIF. Each `enif_*` import changes the 32-bit
  handles of the module into terms, and back. The comment at the start
  of the file gives the rules.
- The WebAssembly runtime: `wasm/erts/build.sh` applies the same patch,
  and links the same file with `c_src/wasm/nif_wasm_host.c` in place of
  WAMR (the step `nif_edge` of `scripts/steps.sh`). That file gives the
  functions of WAMR on the engine of the host
  (`c_src/wasm/nif_wasm_host.js`): the module imports each `enif_*`
  function as an export of ERTS, the bridge reads and writes the memory
  of the module through copies, and each call into the module runs on
  its own JSPI stack. The comment at the start of
  `nif_wasm_host.c` gives the rules.
