// connect() of cloudflare:sockets: a web page has no TCP connections. The
// error becomes econnrefused in Erlang (wasm_tcp).
export function connect({ hostname, port }) {
  throw new Error(`no TCP connection to ${hostname}:${port} in a web page`);
}
