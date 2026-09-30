// connect() of cloudflare:sockets, with Deno.connect: a socket with the
// streams readable and writable, and the promises opened and closed.
export function connect({ hostname, port }) {
  const conn = Deno.connect({ hostname, port });
  let closed;
  const socket = {
    opened: conn.then(() => ({})),
    closed: new Promise((r) => { closed = r; }),
    readable: new ReadableStream({
      async start(c) { this.reader = (await conn).readable.getReader(); },
      async pull(c) {
        const { value, done } = await this.reader.read();
        if (done) { c.close(); closed(); } else c.enqueue(value);
      },
      cancel() { this.reader?.cancel(); },
    }),
    writable: new WritableStream({
      async start() { this.writer = (await conn).writable.getWriter(); },
      // A write to a socket that the peer closed fails in Workers too.
      write(chunk) { return this.writer.write(chunk).catch(() => {}); },
      close() { return this.writer.close(); },
    }),
    async close() { try { (await conn).close(); } catch {} closed(); },
  };
  return socket;
}
