// The port programs of tests/programs/ports_check.erl, for the hosts of
// tests/host/app_ports.sh. Each one gets the bytes of the VM (stdin) and
// its arguments, and gives a stream of bytes for the VM.
// - echo: the bytes back.
// - sink RATE COUNT: reads COUNT bytes at RATE bytes for each second, and
//   gives one line with the count.
// - source COUNT: gives COUNT bytes (0, 1, ..., 255, 0, ...) as fast as
//   the reader takes them.
export const echo = (stdin) => stdin;

export function sink(stdin, { argv: [rate, count] }) {
  return new ReadableStream({
    async start(c) {
      const t0 = Date.now();
      let n = 0;
      for await (const part of stdin) {
        n += part.byteLength;
        const wait = t0 + (n / Number(rate)) * 1000 - Date.now();
        if (wait > 0) await new Promise((r) => setTimeout(r, wait));
        if (n >= Number(count)) break;
      }
      c.enqueue(new TextEncoder().encode(`${n}\n`));
      c.close();
    },
  });
}

export function source(stdin, { argv: [count] }) {
  const block = new Uint8Array(65536).map((_, i) => i & 255);
  let n = 0;
  return new ReadableStream({
    type: 'bytes',
    pull(c) {
      if (n >= Number(count)) return c.close();
      const part = block.slice(0, Math.min(block.length, Number(count) - n));
      n += part.length;
      c.enqueue(part);
    },
  });
}
