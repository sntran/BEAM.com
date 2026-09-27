// An Erlang or Elixir release on Cloudflare Workers: a Durable Object runs the
// WebAssembly emulator (threads on JSPI, the runtime of wasm/erts, with no
// files) and writes the release (release.bin of pack.erl) into its file
// system at /app before the boot. It gives each request and WebSocket frame
// to Erlang through wasm_host (the events of wasm/phoenix/wasm_host/server.ex),
// and the endpoint adapter of the app answers; wasm_tcp sockets use connect().
import { DurableObject } from 'cloudflare:workers';
import { connect } from 'cloudflare:sockets';
import createBeam from './beam.mjs';
import wasm from './beam.wasm';
import release from './release.bin';

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

export default {
  // One object for the app: all requests and sockets go to the same VM.
  fetch(request, env) {
    return env.BEAM.get(env.BEAM.idFromName('app')).fetch(request);
  },
};

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.pending = new Map();  // id -> {resolve, request, stream}
    this.sockets = new Map();  // id -> the server end of a WebSocketPair
    this.tcps = new Map();     // id -> {socket, writer} (wasm_tcp)
    this.nextId = 1;
    this.ready = this.boot(env);
  }

  boot(env) {
    const t0 = Date.now();
    return new Promise((resolve, reject) => {
      this.onready = () => { console.log(`beam: ready in ${Date.now() - t0} ms, ${this.memory()}`); resolve(); };
      createBeam({
        // The boot arguments are set in preRun, after the release is unpacked.
        arguments: [],
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

  async fetch(request) {
    await this.ready;
    const url = new URL(request.url);
    const id = this.nextId++;
    const upgrade = request.headers.get('upgrade')?.toLowerCase() === 'websocket';
    const body = upgrade || request.method === 'GET' || request.method === 'HEAD' ? null : await request.arrayBuffer();
    const response = new Promise((resolve) => this.pending.set(id, { resolve, upgrade }));
    this.event({
      t: 'http', id, method: request.method, path: url.pathname + url.search,
      headers: [...request.headers], scheme: url.protocol.replace(':', ''),
    }, body);
    return response;
  }

  // A TCP socket of wasm_tcp: connect() of cloudflare:sockets.
  async tcpConnect({ id, host, port }) {
    let socket;
    try {
      socket = connect({ hostname: host, port });
      this.tcps.set(id, { socket, writer: socket.writable.getWriter() });
      await socket.opened;
    } catch (e) {
      this.tcps.delete(id);
      this.event({ t: 'tcp_error', id, reason: 'econnrefused' });
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
      case 'head': {
        const { readable, writable } = new TransformStream();
        p.writer = writable.getWriter();
        p.resolve(new Response(readable, { status: msg.status, headers: new Headers(msg.headers) }));
        break;
      }
      case 'chunk': p.writer.write(body); break;
      case 'end': this.pending.delete(msg.id); p.writer.close(); break;
      case 'ws_accept': {
        this.pending.delete(msg.id);
        const [client, server] = Object.values(new WebSocketPair());
        server.accept();
        this.sockets.set(msg.id, server);
        server.addEventListener('message', (e) => {
          const binary = typeof e.data !== 'string';
          this.event({ t: 'ws_msg', id: msg.id, op: binary ? 'binary' : 'text' },
            binary ? e.data : new TextEncoder().encode(e.data));
        });
        server.addEventListener('close', () => { this.sockets.delete(msg.id); this.event({ t: 'ws_close', id: msg.id }); });
        console.log(`beam: socket ${msg.id}, ${this.sockets.size} open, ${this.memory()}`);
        p.resolve(new Response(null, { status: 101, webSocket: client }));
        break;
      }
      case 'ws_send': {
        const ws = this.sockets.get(msg.id);
        if (ws) ws.send(msg.op === 'binary' ? body : new TextDecoder().decode(body));
        break;
      }
      case 'ws_close': this.sockets.get(msg.id)?.close(msg.code || 1000); break;
      case 'tcp_connect': this.tcpConnect(msg); break;
      case 'tcp_send': this.tcps.get(msg.id)?.writer.write(body); break;
      case 'tcp_close': {
        const t = this.tcps.get(msg.id);
        this.tcps.delete(msg.id);
        t?.socket.close().catch(() => {});
        break;
      }
    }
  }
}
