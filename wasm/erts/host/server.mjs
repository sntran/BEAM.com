// A Node.js host for the WebAssembly emulator: the TCP sockets of wasm_tcp
// (node:net), through wasm_host (see wasm/phoenix/wasm_host/server.ex for the
// events). The HTTP server of the app (Bandit) listens with gen_tcp, and the
// host listens for it.
//
//   node server.mjs /path/to/beam.mjs [EMULATOR FLAGS] -- [ERL ARGS]
import net from 'node:net';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [beamPath, ...args] = process.argv.slice(2);
const tcps = new Map();     // id -> net.Socket
const servers = new Map();  // id of a listener -> net.Server
const peers = new Map();    // id -> id: the sockets of a wasm_tcp:splice/2
const tcpHost = process.env.TCP_HOST || '127.0.0.1';  // the address of the listeners
let nextId = 1;
let beam;

function event(header, body) {
  const h = Buffer.from(JSON.stringify(header) + '\n');
  beam.beamHost.push(body && body.length ? Buffer.concat([h, body]) : h);
}

// The events of a TCP socket (a connection that Erlang made or accepted).
function tcpEvents(id, sock) {
  tcps.set(id, sock);
  sock.setNoDelay(true);  // no Nagle: small messages (the distribution) go at once
  sock.on('data', (d) => {
    const peer = peers.get(id);
    if (peer) tcps.get(peer)?.write(d);  // after wasm_tcp:splice/2: not through Erlang
    else event({ t: 'tcp_data', id }, d);
  });
  sock.on('error', (e) => event({ t: 'tcp_error', id, reason: (e.code || 'einval').toLowerCase() }));
  sock.on('close', () => {
    tcps.delete(id);
    event({ t: 'tcp_closed', id });
    const peer = peers.get(id);
    peers.delete(id);
    if (peer) { peers.delete(peer); tcps.get(peer)?.destroy(); }
  });
}

function onsend(bytes) {
  const buf = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length);
  const nl = buf.indexOf(10);
  const msg = JSON.parse(buf.subarray(0, nl).toString());
  const body = buf.subarray(nl + 1);
  switch (msg.t) {
    case 'ready': console.error(`host: ready in ${Date.now() - started} ms`); break;
    case 'tcp_connect': {
      const sock = net.connect({ host: msg.host, port: msg.port });
      sock.on('connect', () => event({ t: 'tcp_open', id: msg.id }));
      tcpEvents(msg.id, sock);
      break;
    }
    case 'tcp_listen': {
      const server = net.createServer((sock) => {
        const id = `a${nextId++}`;
        event({ t: 'tcp_accept', id: msg.id, conn: id, host: sock.remoteAddress, port: sock.remotePort });
        tcpEvents(id, sock);
      });
      server.on('error', (e) => event({ t: 'tcp_error', id: msg.id, reason: (e.code || 'einval').toLowerCase() }));
      server.listen(msg.port, tcpHost, () => {
        servers.set(msg.id, server);
        console.error(`host: tcp ${tcpHost}:${msg.port}`);
        event({ t: 'tcp_listening', id: msg.id });
      });
      break;
    }
    case 'tcp_splice': peers.set(msg.a, msg.b); peers.set(msg.b, msg.a); break;
    case 'tcp_unlisten': servers.get(msg.id)?.close(); servers.delete(msg.id); break;
    case 'tcp_send': tcps.get(msg.id)?.write(body); break;
    case 'tcp_close': tcps.get(msg.id)?.destroy(); tcps.delete(msg.id); break;
  }
}

const { default: createBeam } = await import(pathToFileURL(resolve(beamPath)));
const started = Date.now();
createBeam({
  arguments: args,
  preRun: [(m) => { beam = m; m.beamHost.onsend = onsend; }],
});
