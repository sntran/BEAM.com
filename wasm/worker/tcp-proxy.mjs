// A client proxy for incoming TCP on Workers: each connection to a local
// port becomes a WebSocket to /.tcp/PORT of the Worker (worker.js), which
// gives it to the listener of PORT in Erlang (gen_tcp:listen).
//
//   node tcp-proxy.mjs LOCAL_PORT wss://app.example.com/.tcp/PORT
//   ssh -p LOCAL_PORT localhost
import net from 'node:net';
import { WebSocket } from 'ws';

const [localPort, url] = process.argv.slice(2);
if (!localPort || !url) {
  console.error('usage: node tcp-proxy.mjs LOCAL_PORT WS_URL');
  process.exit(2);
}

net.createServer((sock) => {
  sock.pause();
  const ws = new WebSocket(url);
  ws.binaryType = 'nodebuffer';
  ws.on('open', () => {
    sock.on('data', (d) => ws.send(d, { binary: true }));
    sock.resume();
  });
  ws.on('message', (d) => sock.write(d));
  ws.on('close', () => sock.end());
  ws.on('error', (e) => { console.error(`tcp-proxy: ${e.message}`); sock.destroy(); });
  sock.on('close', () => ws.close());
  sock.on('error', () => ws.close());
}).listen(Number(localPort), '127.0.0.1', () => console.error(`tcp-proxy: 127.0.0.1:${localPort} -> ${url}`));
