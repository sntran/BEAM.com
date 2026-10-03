// node:net for worker.js in a web page: a page has no TCP connections. The
// error becomes econnrefused in Erlang (wasm_tcp).
export function connect({ host, port }) {
  throw new Error(`no TCP connection to ${host}:${port} in a web page`);
}

export default { connect };
