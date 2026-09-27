// A Node.js host for the WebAssembly emulator: it serves HTTP and WebSockets,
// and gives each request and frame to Erlang through wasm_host (see
// wasm/phoenix/wasm_host/server.ex for the events).
//
//   PORT=4000 node server.cjs /path/to/beam.cjs [EMULATOR FLAGS] -- [ERL ARGS]
const http = require('node:http');
const net = require('node:net');
const { WebSocketServer } = require('ws');

const [beamPath, ...args] = process.argv.slice(2);
const port = Number(process.env.PORT || 4000);
const pending = new Map();  // id -> {res} or {req, socket, head} (an upgrade)
const sockets = new Map();  // id -> ws
const tcps = new Map();     // id -> net.Socket (wasm_tcp)
const wss = new WebSocketServer({ noServer: true });
let nextId = 1;
let beam;

function event(header, body) {
  const h = Buffer.from(JSON.stringify(header) + '\n');
  beam.beamHost.push(body && body.length ? Buffer.concat([h, body]) : h);
}

function request(req, body, extra) {
  const id = nextId++;
  const headers = [];
  for (let i = 0; i < req.rawHeaders.length; i += 2) headers.push([req.rawHeaders[i], req.rawHeaders[i + 1]]);
  pending.set(id, extra);
  event({ t: 'http', id, method: req.method, path: req.url, headers, scheme: 'http' }, body);
}

function onsend(bytes) {
  const buf = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length);
  const nl = buf.indexOf(10);
  const msg = JSON.parse(buf.subarray(0, nl).toString());
  const body = buf.subarray(nl + 1);
  const p = pending.get(msg.id);
  switch (msg.t) {
    case 'resp':
      pending.delete(msg.id);
      if (p?.res) { p.res.writeHead(msg.status, msg.headers); p.res.end(body); }
      else if (p?.socket) { p.socket.end(`HTTP/1.1 ${msg.status} Rejected\r\ncontent-length: ${body.length}\r\n\r\n` + body); }
      break;
    case 'head': p.res.writeHead(msg.status, msg.headers); break;
    case 'chunk': p.res.write(body); break;
    case 'end': pending.delete(msg.id); p.res.end(); break;
    case 'ws_accept':
      pending.delete(msg.id);
      wss.handleUpgrade(p.req, p.socket, p.head, (ws) => {
        sockets.set(msg.id, ws);
        ws.on('message', (data, isBinary) => event({ t: 'ws_msg', id: msg.id, op: isBinary ? 'binary' : 'text' }, Buffer.from(data)));
        ws.on('close', () => { sockets.delete(msg.id); event({ t: 'ws_close', id: msg.id }); });
      });
      break;
    case 'ws_send': sockets.get(msg.id)?.send(body, { binary: msg.op === 'binary' }); break;
    case 'ws_close': sockets.get(msg.id)?.close(msg.code || 1000); break;
    case 'tcp_connect': {
      const sock = net.connect({ host: msg.host, port: msg.port });
      tcps.set(msg.id, sock);
      sock.on('connect', () => event({ t: 'tcp_open', id: msg.id }));
      sock.on('data', (d) => event({ t: 'tcp_data', id: msg.id }, d));
      sock.on('error', (e) => event({ t: 'tcp_error', id: msg.id, reason: (e.code || 'einval').toLowerCase() }));
      sock.on('close', () => { tcps.delete(msg.id); event({ t: 'tcp_closed', id: msg.id }); });
      break;
    }
    case 'tcp_send': tcps.get(msg.id)?.write(body); break;
    case 'tcp_close': tcps.get(msg.id)?.destroy(); tcps.delete(msg.id); break;
  }
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => request(req, Buffer.concat(chunks), { res }));
});
server.on('upgrade', (req, socket, head) => request(req, null, { req, socket, head }));

require(require('node:path').resolve(beamPath))({
  arguments: args,
  preRun: [(m) => { beam = m; m.beamHost.onsend = onsend; }],
});
server.listen(port, '127.0.0.1', () => console.error(`host: http://127.0.0.1:${port}/`));
