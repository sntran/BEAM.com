// The host side of c_src/wasm/nif_wasm_host.c (an Emscripten JS library):
// the engine of the host compiles and runs the module of a NIF library in
// the WebAssembly runtime of --target wasm32.
//
// - Each enif_* import of the module is the export nifx_enif_* of ERTS
//   (nif_wasm.c), with nothing of JavaScript between them. An enif_*
//   function that ERTS does not give stops the call when the module calls
//   it.
// - WASI has the standard output and error, the clocks and random bytes;
//   no files and no arguments.
// - A function of the module goes into the table of ERTS, so that C code
//   can call it (nif_host_tramp). Each call runs on its own JSPI stack
//   (WebAssembly.promising): a trap stops only that call.
// - The module must export its table. When it does not, the export
//   __nif_table goes into a copy of its bytes before the compilation.
//   Module.nifModule(file, bytes), when the host gives it, can give a
//   compiled module (a host that cannot compile WebAssembly at run time).
addToLibrary({
  $nifHost: {
    libs: [null],
    pending: new Map(),
    next: 0,
    tramp: null,
    text: { 1: '', 2: '' },
  },

  // The parts of the module that the bridge needs: the type of each
  // export and of each element of table 0, and the name of the export of
  // table 0 (added when there is none). A type is [parameters, results];
  // 99 when it is not all i32, -1 when it is not known.
  $nifParse: (bytes) => {
    let i = 8;
    const leb = () => {
      let r = 0, s = 0, b;
      do { b = bytes[i++]; r += (b & 0x7f) * 2 ** s; s += 7; } while (b & 0x80);
      return r;
    };
    const sleb = () => {
      let r = 0, s = 0, b;
      do { b = bytes[i++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80);
      return s < 32 && (b & 0x40) ? r | (-1 << s) : r;
    };
    const name = () => { const n = leb(); const s = new TextDecoder().decode(bytes.subarray(i, i + n)); i += n; return s; };
    const valtype = () => { const t = bytes[i++]; if (t === 0x63 || t === 0x64) sleb(); return t; };
    const limits = () => { const f = bytes[i++]; leb(); if (f & 1) leb(); };
    const offset = () => {
      const op = bytes[i++];
      const v = op === 0x41 ? sleb() : (leb(), null);
      if (bytes[i++] !== 0x0b) throw new Error('offset expression');
      return v;
    };
    const kind = (params, results) => [
      params.every((t) => t === 0x7f) ? params.length : 99,
      results.length === 0 ? 0 : results.length === 1 && results[0] === 0x7f ? 1 : 99,
    ];
    const types = [], funcs = [], exportTypes = new Map(), elems = new Map();
    let tableExport = null, hasTable = false, exportAt = -1, exportEnd = -1;
    if (bytes[0] !== 0 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) throw new Error('not a WebAssembly module');
    while (i < bytes.length) {
      const at = i, id = bytes[i++], size = leb(), end = i + size;
      if (id === 1) {
        for (let n = leb(); n > 0; n--) {
          if (bytes[i++] !== 0x60) throw new Error('type form');
          const p = []; for (let k = leb(); k > 0; k--) p.push(valtype());
          const r = []; for (let k = leb(); k > 0; k--) r.push(valtype());
          types.push(kind(p, r));
        }
      } else if (id === 2) {
        for (let n = leb(); n > 0; n--) {
          name(); name();
          const k = bytes[i++];
          if (k === 0) funcs.push(types[leb()]);
          else if (k === 1) { valtype(); limits(); hasTable = true; }
          else if (k === 2) limits();
          else if (k === 3) { valtype(); i++; }
          else if (k === 4) { i++; leb(); }
        }
      } else if (id === 3) {
        for (let n = leb(); n > 0; n--) funcs.push(types[leb()]);
      } else if (id === 4) {
        if (leb() > 0) hasTable = true;
      } else if (id === 7) {
        exportAt = at;
        exportEnd = end;
        for (let n = leb(); n > 0; n--) {
          const nm = name(), k = bytes[i++], idx = leb();
          if (k === 0) exportTypes.set(nm, funcs[idx]);
          if (k === 1 && idx === 0) tableExport = nm;
        }
      } else if (id === 9) {
        for (let n = leb(); n > 0; n--) {
          const f = leb();
          const table = f === 2 || f === 6 ? leb() : 0;
          const at = f & 1 ? null : offset();
          if (f === 1 || f === 2 || f === 3) i++;
          if (f === 5 || f === 6 || f === 7) valtype();
          for (let k = leb(), e = 0; e < k; e++) {
            let fi = null;
            if (f < 4) fi = leb();
            else {
              const op = bytes[i++];
              if (op === 0xd2) fi = leb(); else if (op === 0xd0) valtype(); else throw new Error('element expression');
              if (bytes[i++] !== 0x0b) throw new Error('element expression');
            }
            if (table === 0 && at !== null && fi !== null) elems.set(at + e, fi);
          }
        }
      }
      i = end;
    }
    if (!tableExport && hasTable) {
      if (exportAt < 0) throw new Error('no export section');
      const enc = (v) => { const o = []; do { let b = v % 128; v = Math.floor(v / 128); if (v) b |= 0x80; o.push(b); } while (v); return o; };
      i = exportAt + 1;
      const size = leb(), bodyAt = i, count = leb();
      const nm = new TextEncoder().encode('__nif_table');
      const body = [...enc(count + 1), ...bytes.subarray(i, bodyAt + size), ...enc(nm.length), ...nm, 1, 0];
      const out = new Uint8Array(exportAt + 1 + enc(body.length).length + body.length + (bytes.length - exportEnd));
      out.set(bytes.subarray(0, exportAt + 1));
      out.set(enc(body.length), exportAt + 1);
      out.set(body, exportAt + 1 + enc(body.length).length);
      out.set(bytes.subarray(exportEnd), exportAt + 1 + enc(body.length).length + body.length);
      bytes = out;
      tableExport = '__nif_table';
    }
    return { bytes, funcs, exportTypes, elems, tableExport };
  },

  // Output of WASI: whole lines to the output and the error of the VM.
  $nifWrite__deps: ['$nifHost'],
  $nifWrite: (fd, data) => {
    const text = nifHost.text[fd] + new TextDecoder().decode(data);
    const lines = text.split('\n');
    nifHost.text[fd] = lines.pop();
    for (const line of lines) (fd === 1 ? out : err)(line);
  },

  $nifWasi__deps: ['$nifWrite'],
  $nifWasi: (lib) => {
    const u8 = () => new Uint8Array(lib.mem.buffer);
    const dv = () => new DataView(lib.mem.buffer);
    const zero2 = (a, b) => { dv().setUint32(a, 0, true); dv().setUint32(b, 0, true); return 0; };
    return {
      args_get: () => 0,
      args_sizes_get: zero2,
      environ_get: () => 0,
      environ_sizes_get: zero2,
      clock_res_get: (id, p) => { dv().setBigUint64(p, 1000n, true); return 0; },
      clock_time_get: (id, precision, p) => {
        const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        dv().setBigUint64(p, ns, true);
        return 0;
      },
      random_get: (p, n) => {
        for (let k = 0; k < n; k += 65536) crypto.getRandomValues(new Uint8Array(lib.mem.buffer, p + k, Math.min(65536, n - k)));
        return 0;
      },
      fd_write: (fd, iov, count, written) => {
        if (fd !== 1 && fd !== 2) return 8;
        let total = 0;
        for (let k = 0; k < count; k++) {
          const p = dv().getUint32(iov + 8 * k, true), n = dv().getUint32(iov + 8 * k + 4, true);
          nifWrite(fd, u8().slice(p, p + n));
          total += n;
        }
        dv().setUint32(written, total, true);
        return 0;
      },
      fd_read: (fd, iov, count, read) => { if (fd !== 0) return 8; dv().setUint32(read, 0, true); return 0; },
      fd_close: (fd) => (fd <= 2 ? 0 : 8),
      fd_fdstat_set_flags: (fd) => (fd <= 2 ? 0 : 8),
      fd_seek: (fd) => (fd <= 2 ? 70 : 8),
      fd_fdstat_get: (fd, p) => {
        if (fd > 2) return 8;
        const u = u8(); u.fill(0, p, p + 24); u[p] = 2; u.fill(0xff, p + 8, p + 24);
        return 0;
      },
      fd_filestat_get: (fd, p) => {
        if (fd > 2) return 8;
        const u = u8(); u.fill(0, p, p + 64); u[p + 16] = 2;
        return 0;
      },
      fd_prestat_get: () => 8,
      fd_prestat_dir_name: () => 8,
      proc_exit: (code) => { throw new Error(`proc_exit(${code})`); },
      sched_yield: () => 0,
      poll_oneoff: () => 58,
    };
  },

  $nifSlot__deps: ['$wasmTable'],
  $nifSlot: (lib, f) => {
    let s = lib.slots.get(f);
    if (!s) {
      s = wasmTable.grow(1);
      wasmTable.set(s, f);
      lib.slots.set(f, s);
    }
    return s;
  },

  nif_host_compile__deps: ['$nifCompile', '$UTF8ToString', '$stringToUTF8'],
  nif_host_compile__sig: 'ipipipi',
  nif_host_compile: (bytes, n, file, debug, error, size) => {
    const name = UTF8ToString(file);
    const fail = (msg) => { stringToUTF8(String(msg), error, size); return 0; };
    // An exception must not leave this function: it would stop the thread.
    try {
      return nifCompile(name, HEAPU8.slice(bytes, bytes + n), debug, fail);
    } catch (e) {
      return fail(`${name}: ${e?.message ?? e}`);
    }
  },

  $nifCompile__deps: ['$nifHost', '$nifParse', '$nifWasi'],
  $nifCompile: (name, bytes, debug, fail) => {
    let info, module;
    try {
      info = nifParse(bytes);
    } catch (e) {
      return fail(`${name}: ${e.message}`);
    }
    try {
      module = Module['nifModule']?.(name, info.bytes) ?? new WebAssembly.Module(info.bytes);
    } catch (e) {
      return fail(e.message);
    }
    const lib = { file: name, module, info, instance: null, mem: null, table: null, slots: new Map() };
    const wasi = nifWasi(lib);
    const imports = { env: {}, wasi_snapshot_preview1: {} };
    const bad = [];
    const stop = (what) => () => { throw new Error(`${what} is not supported`); };
    for (const im of WebAssembly.Module.imports(module)) {
      const nifx = im.module === 'env' && im.name.startsWith('enif_') && wasmExports['nifx_' + im.name];
      if (im.kind !== 'function') bad.push(`${im.module}.${im.name}`);
      else if (nifx) imports.env[im.name] = nifx;
      else if (im.module === 'env' && im.name.startsWith('enif_')) {
        if (debug) err(`nif_wasm: ${name}: ${im.name} is not supported`);
        imports.env[im.name] = stop(im.name);
      } else if (im.module === 'wasi_snapshot_preview1') {
        if (!wasi[im.name] && debug) err(`nif_wasm: ${name}: ${im.name} is not supported`);
        imports.wasi_snapshot_preview1[im.name] = wasi[im.name] ?? stop(im.name);
      } else bad.push(`${im.module}.${im.name}`);
    }
    if (bad.length) return fail(`unsupported imports: ${bad.join(' ')}`);
    lib.imports = imports;
    nifHost.libs.push(lib);
    // The host makes no snapshot of the VM (worker.js).
    Module['nifLoaded'] = true;
    return nifHost.libs.length - 1;
  },

  nif_host_instantiate__deps: ['$nifHost', '$stringToUTF8'],
  nif_host_instantiate__sig: 'iipi',
  nif_host_instantiate: (id, error, size) => {
    const lib = nifHost.libs[id];
    try {
      lib.instance = new WebAssembly.Instance(lib.module, lib.imports);
    } catch (e) {
      stringToUTF8(String(e.message), error, size);
      return 0;
    }
    lib.mem = lib.instance.exports.memory;
    lib.table = lib.info.tableExport ? lib.instance.exports[lib.info.tableExport] : null;
    if (!(lib.mem instanceof WebAssembly.Memory)) {
      stringToUTF8('the module exports no memory', error, size);
      return 0;
    }
    return 1;
  },

  nif_host_free__deps: ['$nifHost', '$wasmTable'],
  nif_host_free__sig: 'vi',
  nif_host_free: (id) => {
    const lib = nifHost.libs[id];
    if (!lib) return;
    for (const s of lib.slots.values()) wasmTable.set(s, null);
    nifHost.libs[id] = null;
  },

  nif_host_has_export__deps: ['$nifHost', '$UTF8ToString'],
  nif_host_has_export__sig: 'iip',
  nif_host_has_export: (id, name) => (nifHost.libs[id].info.exportTypes.has(UTF8ToString(name)) ? 1 : 0),

  nif_host_export__deps: ['$nifHost', '$nifSlot', '$UTF8ToString'],
  nif_host_export__sig: 'iipp',
  nif_host_export: (id, name, types) => {
    const lib = nifHost.libs[id], nm = UTF8ToString(name);
    const f = lib.instance.exports[nm];
    if (typeof f !== 'function') return 0;
    const t = lib.info.exportTypes.get(nm) ?? [-1, -1];
    HEAP32[types >> 2] = t[0];
    HEAP32[(types >> 2) + 1] = t[1];
    return nifSlot(lib, f);
  },

  nif_host_element__deps: ['$nifHost', '$nifSlot'],
  nif_host_element__sig: 'iiip',
  nif_host_element: (id, index, types) => {
    const lib = nifHost.libs[id];
    let f = null;
    try { f = lib.table?.get(index >>> 0) ?? null; } catch (e) { f = null; }
    if (!f) return 0;
    const fi = lib.info.elems.get(index >>> 0);
    const t = (fi !== undefined && lib.info.funcs[fi]) || [-1, -1];
    HEAP32[types >> 2] = t[0];
    HEAP32[(types >> 2) + 1] = t[1];
    return nifSlot(lib, f);
  },

  nif_host_read__deps: ['$nifHost'],
  nif_host_read__sig: 'iiipi',
  nif_host_read: (id, off, dst, n) => {
    const buf = nifHost.libs[id].mem.buffer;
    off >>>= 0; n >>>= 0;
    if (off + n > buf.byteLength) return 0;
    HEAPU8.set(new Uint8Array(buf, off, n), dst);
    return 1;
  },

  nif_host_write__deps: ['$nifHost'],
  nif_host_write__sig: 'iiipi',
  nif_host_write: (id, off, src, n) => {
    const buf = nifHost.libs[id].mem.buffer;
    off >>>= 0; n >>>= 0;
    if (off + n > buf.byteLength) return 0;
    new Uint8Array(buf, off, n).set(HEAPU8.subarray(src, src + n));
    return 1;
  },

  nif_host_strlen__deps: ['$nifHost'],
  nif_host_strlen__sig: 'iii',
  nif_host_strlen: (id, off) => {
    const u = new Uint8Array(nifHost.libs[id].mem.buffer);
    off >>>= 0;
    const end = off < u.length ? u.indexOf(0, off) : -1;
    return end < 0 ? -1 : end - off;
  },

  // Run nif_host_tramp(call) on its own JSPI stack. 0: it ended, else the
  // id of the call for nif_host_wait. The fields of hcall_t: done at 12,
  // error at 36.
  nif_host_call__deps: ['$nifHost', '$stringToUTF8'],
  nif_host_call__sig: 'ip',
  nif_host_call: (call) => {
    nifHost.tramp ??= WebAssembly.promising(wasmExports['nif_host_tramp']);
    const p = nifHost.tramp(call);
    if (HEAPU32[(call + 12) >> 2]) return 0;
    const id = ++nifHost.next;
    nifHost.pending.set(id, p.then(() => 1, (e) => {
      stringToUTF8(String(e?.message ?? e), call + 36, 256);
      return 0;
    }));
    return id;
  },

  nif_host_wait__deps: ['$nifHost'],
  nif_host_wait__async: true,
  nif_host_wait__sig: 'ii',
  nif_host_wait: (id) => {
    const p = nifHost.pending.get(id);
    nifHost.pending.delete(id);
    return p;
  },

  nif_host_throw__sig: 'v',
  nif_host_throw: () => {
    throw new Error('an enif_* function failed');
  },
});
