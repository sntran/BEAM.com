// An Erlang or Elixir release on Cloudflare Workers: the WebAssembly emulator
// (threads on JSPI, the runtime of wasm/erts, with no files) writes the
// release (release.bin of pack.erl) into its file system at /app and boots it.
//
// Where the VM lives:
// - a binding BEAM (a Durable Object namespace): one object for the app, and
//   all requests and sockets go to it;
// - no binding BEAM: a plain Worker, with one VM for each isolate; the next
//   requests to the same isolate use it again.
// Where the release comes from:
// - a binding APP (a service binding to another Worker): GET /release.bin;
// - a text binding RELEASE_URL: a fetch of that URL;
// - else the module release.bin in this Worker.
//
// It gives each request and WebSocket frame to Erlang through wasm_host (the
// events of wasm/phoenix/wasm_host/server.ex), and the endpoint adapter of the
// app answers; wasm_tcp sockets use connect().
import { DurableObject } from 'cloudflare:workers';
import { connect } from 'cloudflare:sockets';
import createBeam from './beam.mjs';
import wasm from './beam.wasm';

async function loadRelease(env) {
  if (env.APP) return (await env.APP.fetch('http://app/release.bin')).arrayBuffer();
  if (env.RELEASE_URL) return (await fetch(env.RELEASE_URL)).arrayBuffer();
  return (await import('./release.bin')).default;
}

// release.bin: "BEAMFS1\n", then (length, path, length, data) for each file.
function unpack(FS, bytes) {
  const b = new Uint8Array(bytes);
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const text = new TextDecoder();
  if (text.decode(b.subarray(0, 8)) !== 'BEAMFS1\n') throw new Error('release.bin: not a release');
  let meta = null;
  for (let i = 8; i < b.length;) {
    const plen = view.getUint32(i); i += 4;
    const path = text.decode(b.subarray(i, i + plen)); i += plen;
    const dlen = view.getUint32(i); i += 4;
    const data = b.subarray(i, i + dlen); i += dlen;
    if (path === '.release.json') { meta = JSON.parse(text.decode(data)); continue; }
    const full = '/app/' + path;
    FS.mkdirTree(full.slice(0, full.lastIndexOf('/')));
    FS.writeFile(full, data);
  }
  return meta;
}

let vm;  // the VM of this isolate (without a Durable Object)

export default {
  fetch(request, env, ctx) {
    if (env.BEAM) return env.BEAM.get(env.BEAM.idFromName('app')).fetch(request);
    if (!vm) {
      const v = vm = new Vm(env, true);
      v.ready.catch(() => { if (vm === v) vm = undefined; });
    }
    return vm.fetch(request, ctx);
  },
};

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.vm = new Vm(env);
  }

  fetch(request) {
    return this.vm.fetch(request);
  }
}

class Vm {
  // plain: a plain Worker (no Durable Object), where the VM runs only in
  // the handlers of open requests (serve).
  constructor(env, plain = false) {
    this.pending = new Map();  // id -> {resolve, request, stream}
    this.sockets = new Map();  // id -> the server end of a WebSocketPair
    this.tcps = new Map();     // id -> {socket, writer} (wasm_tcp)
    this.nextId = 1;
    this.plain = plain;
    this.handlers = [];        // the open requests (plain)
    this.jobs = [];            // the wake-ups of the threads (plain)
    this.timers = new Map();   // id -> {at, f}: the timers of the threads (plain)
    this.nextTimer = 1;
    this.ready = this.boot(env);
  }

  async boot(env) {
    const t0 = Date.now();
    const release = await loadRelease(env);
    const t1 = Date.now();
    return new Promise((resolve, reject) => {
      this.onready = () => { console.log(`beam: ready in ${Date.now() - t0} ms (release ${release.byteLength >> 10} KB in ${t1 - t0} ms), ${this.memory()}`); resolve(); };
      createBeam({
        // The boot arguments are set in preRun, after the release is unpacked.
        arguments: [],
        jspiSchedule: this.plain ? {
          later: (f) => { this.jobs.push(f); this.handlers.at(-1)?.wake?.(); },
          timer: (f, ms) => {
            const id = this.nextTimer++;
            this.timers.set(id, { at: Date.now() + ms, f });
            this.handlers.at(-1)?.wake?.();
            return id;
          },
          clear: (id) => { this.timers.delete(id); },
        } : undefined,
        preRun: [(m) => {
          this.beam = m;
          const { name, vsn } = unpack(m.FS, release);
          m.arguments.push('-S', '1', '-SDcpu', '1', '-A', '0', '--',
            '-root', '/app', '-bindir', '/app/bin', '-progname', 'erl', '--',
            '-home', '/', '-mode', 'interactive', '-config', '/app/tmp/run.runtime',
            '-boot', `/app/releases/${vsn}/start`, '-boot_var', 'RELEASE_LIB', '/app/lib', '-noshell');
          // The text bindings of the Worker are the environment of the release
          // (SECRET_KEY_BASE, PHX_HOST, DATABASE_URL, ...).
          const vars = Object.fromEntries(Object.entries(env).filter(([, v]) => typeof v === 'string'));
          Object.assign(m.ENV, {
            ROOTDIR: '/app', BINDIR: '/app/bin', EMU: 'beam', PROGNAME: 'erl', HOME: '/',
            RELEASE_ROOT: '/app', RELEASE_NAME: name, RELEASE_VSN: vsn, RELEASE_MODE: 'interactive',
            RELEASE_TMP: '/app/tmp', RELEASE_SYS_CONFIG: '/app/tmp/run.runtime', RELEASE_PROG: name,
            PHX_SERVER: 'true', WASM_HOST: '1',
          }, vars);
          m.beamHost.onsend = (bytes) => this.onsend(bytes);
        }],
        print: (s) => console.log(s),
        printErr: (s) => console.log(s),
        // Workers compile no WebAssembly at run time: use the imported module.
        instantiateWasm: (imports, done) => {
          WebAssembly.instantiate(wasm, imports).then((instance) => done(instance));
          return {};
        },
        onExit: (code) => reject(new Error(`beam exited with status ${code}`)),
      }).catch(reject);
    });
  }

  memory() {
    return `memory ${this.beam.HEAPU8.length >> 20} MB`;
  }

  event(header, body) {
    const h = new TextEncoder().encode(JSON.stringify(header) + '\n');
    if (!body || !body.byteLength) return this.beam.beamHost.push(h);
    const b = new Uint8Array(h.length + body.byteLength);
    b.set(h);
    b.set(new Uint8Array(body), h.length);
    this.beam.beamHost.push(b);
  }

  // ctx: the context of a request to a plain Worker (none in a Durable Object).
  async fetch(request, ctx) {
    let finished = () => {};
    const h = this.plain ? this.serve(ctx, new Promise((r) => { finished = r; })) : undefined;
    try {
      return await this.request(request, h, finished);
    } catch (e) {
      finished();
      throw e;
    }
  }

  async request(request, h, finished) {
    await this.ready;
    const url = new URL(request.url);
    const id = this.nextId++;
    const upgrade = request.headers.get('upgrade')?.toLowerCase() === 'websocket';
    const body = upgrade || request.method === 'GET' || request.method === 'HEAD' ? null : await request.arrayBuffer();
    const response = new Promise((resolve) => this.pending.set(id, { resolve, upgrade, handler: h }));
    response.then(finished);
    this.event({
      t: 'http', id, method: request.method, path: url.pathname + url.search,
      headers: [...request.headers], scheme: url.protocol.replace(':', ''),
    }, body);
    return response;
  }

  // A plain Worker runs code only for an open request, and an I/O object (a
  // stream, a socket) or a timer belongs to the request that made it. So the
  // handler of each open request is the event loop of the VM: it runs the
  // wake-ups and timers of the threads (jspiSchedule), and the host calls
  // that make or use I/O objects (run), until the request has its response
  // and its sockets are closed. With no open request, the VM does not run.
  serve(ctx, finished) {
    const h = { jobs: [], wake: null, timeout: null, sockets: 0, done: false };
    this.handlers.push(h);
    finished.then(() => { h.done = true; h.wake?.(); });
    // A macrotask of this request, after its pending I/O (as jspiLater).
    const ch = new MessageChannel();
    const tick = () => new Promise((r) => { ch.port1.onmessage = r; ch.port2.postMessage(0); });
    ctx.waitUntil((async () => {
      try {
        for (;;) {
          this.runJobs(h);
          if (h.done && !h.sockets) break;
          if (h.jobs.length || this.jobs.length || this.nextTimerAt() <= Date.now()) {
            await tick();
            continue;
          }
          // A timer of this request at least each second: else the runtime can
          // take a request that waits only for the VM (in another request) as
          // hung, and cancel it with the work of the VM that waits in it.
          const at = Math.min(this.nextTimerAt(), Date.now() + 1000);
          await new Promise((wake) => {
            h.wake = wake;
            h.timeout = setTimeout(wake, Math.max(0, at - Date.now()));
          });
          h.wake = null;
          if (h.timeout !== null) { clearTimeout(h.timeout); h.timeout = null; }
        }
      } finally {
        this.handlers.splice(this.handlers.indexOf(h), 1);
        ch.port1.close();
        this.handlers.at(-1)?.wake?.();  // the next one takes the jobs and timers
      }
    })());
    return h;
  }

  // The jobs of h, the wake-ups, and the timers that are due, as they are now.
  runJobs(h) {
    const call = (f) => {
      try { f(); } catch (e) { console.log(`beam: host call: ${e.message}`); }
    };
    for (const f of h.jobs.splice(0)) call(f);
    for (const f of this.jobs.splice(0)) call(f);
    const now = Date.now();
    for (const [id, t] of this.timers) {
      if (t.at <= now) { this.timers.delete(id); call(t.f); }
    }
  }

  nextTimerAt() {
    let at = Infinity;
    for (const t of this.timers.values()) at = Math.min(at, t.at);
    return at;
  }

  // Runs fn in the handler h (default: the newest request), or at once in a
  // Durable Object.
  run(fn, h = this.handlers.at(-1)) {
    if (!this.plain) return fn();
    if (!h) return void this.jobs.push(fn);
    h.jobs.push(fn);
    h.wake?.();
  }

  // A TCP socket of wasm_tcp: connect() of cloudflare:sockets. In a plain
  // Worker it belongs to the handler h, and closes with that request.
  async tcpConnect({ id, host, port }, h) {
    let socket;
    if (h) h.sockets++;
    try {
      socket = connect({ hostname: host, port });
      this.tcps.set(id, { socket, writer: socket.writable.getWriter(), h });
      await socket.opened;
    } catch (e) {
      console.log(`beam: connect ${host}:${port}: ${e.message}`);
      this.tcps.delete(id);
      this.event({ t: 'tcp_error', id, reason: 'econnrefused' });
      if (h) { h.sockets--; h.wake?.(); }
      return;
    }
    this.event({ t: 'tcp_open', id });
    try {
      const reader = socket.readable.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        this.event({ t: 'tcp_data', id }, value);
      }
    } catch (e) {}
    this.tcps.delete(id);
    this.event({ t: 'tcp_closed', id });
    if (h) { h.sockets--; h.wake?.(); }
  }

  onsend(bytes) {
    const nl = bytes.indexOf(10);
    const msg = JSON.parse(new TextDecoder().decode(bytes.subarray(0, nl)));
    const body = bytes.slice(nl + 1);
    const p = this.pending.get(msg.id);
    switch (msg.t) {
      case 'ready':
        this.onready();
        break;
      case 'resp':
        this.pending.delete(msg.id);
        p?.resolve(new Response(msg.status === 204 || msg.status === 304 ? null : body,
          { status: msg.status, headers: new Headers(msg.headers) }));
        break;
      case 'head': this.run(() => {
        const { readable, writable } = new TransformStream();
        p.writer = writable.getWriter();
        p.resolve(new Response(readable, { status: msg.status, headers: new Headers(msg.headers) }));
      }, p.handler); break;
      case 'chunk': this.run(() => p.writer.write(body), p.handler); break;
      case 'end': this.pending.delete(msg.id); this.run(() => p.writer.close(), p.handler); break;
      case 'ws_accept': this.run(() => {
        this.pending.delete(msg.id);
        const h = p.handler;
        if (h) h.sockets++;
        const [client, server] = Object.values(new WebSocketPair());
        server.accept();
        this.sockets.set(msg.id, server);
        server.addEventListener('message', (e) => {
          const binary = typeof e.data !== 'string';
          this.event({ t: 'ws_msg', id: msg.id, op: binary ? 'binary' : 'text' },
            binary ? e.data : new TextEncoder().encode(e.data));
        });
        server.addEventListener('close', () => {
          this.sockets.delete(msg.id);
          this.event({ t: 'ws_close', id: msg.id });
          if (h) { h.sockets--; h.wake?.(); }
        });
        server.handler = h;
        console.log(`beam: socket ${msg.id}, ${this.sockets.size} open, ${this.memory()}`);
        p.resolve(new Response(null, { status: 101, webSocket: client }));
      }, p.handler); break;
      case 'ws_send': {
        const ws = this.sockets.get(msg.id);
        if (ws) this.run(() => ws.send(msg.op === 'binary' ? body : new TextDecoder().decode(body)), ws.handler);
        break;
      }
      case 'ws_close': {
        const ws = this.sockets.get(msg.id);
        if (ws) this.run(() => ws.close(msg.code || 1000), ws.handler);
        break;
      }
      case 'tcp_connect': {
        const h = this.handlers.at(-1);
        this.run(() => this.tcpConnect(msg, h), h);
        break;
      }
      case 'tcp_send': {
        const t = this.tcps.get(msg.id);
        if (t) this.run(() => t.writer.write(body), t.h);
        break;
      }
      case 'tcp_close': {
        const t = this.tcps.get(msg.id);
        this.tcps.delete(msg.id);
        if (t) this.run(() => t.socket.close().catch(() => {}), t.h);
        break;
      }
    }
  }
}
