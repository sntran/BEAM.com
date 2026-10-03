// connect() of cloudflare:sockets, with node:net: a socket with the streams
// readable and writable, and the promises opened and closed.
import net from 'node:net';
import { Duplex } from 'node:stream';

export function connect({ hostname, port }) {
  const conn = net.connect({ host: hostname, port });
  const { readable, writable } = Duplex.toWeb(conn);
  let closed;
  const socket = {
    opened: new Promise((resolve, reject) => {
      conn.once('connect', () => resolve({}));
      conn.once('error', reject);
    }),
    closed: new Promise((r) => { closed = r; }),
    readable,
    writable,
    async close() { conn.destroy(); },
  };
  // A failed connection rejects opened; the other errors end the socket.
  socket.opened.catch(() => {});
  conn.on('error', () => {});
  conn.once('close', () => closed());
  return socket;
}
