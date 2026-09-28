// Runs Erlang/OTP (ERTS in WebAssembly, threads on JSPI) for each request:
//   GET /?eval=EXPR   runs erl -noshell -eval EXPR and returns its output.
import createBeam from './beam.mjs';
import wasm from './beam.wasm';

const DEFAULT = 'io:format("hello from ~s, OTP ~s~n", [erlang:system_info(system_architecture), erlang:system_info(otp_release)]), halt().';

export default {
  async fetch(request) {
    const expr = new URL(request.url).searchParams.get('eval') ?? DEFAULT;
    const out = [];
    let module, exited;
    const exit = new Promise((resolve) => { exited = resolve; });
    createBeam({
      arguments: ['-S', '1', '-SDcpu', '1', '-SDio', '1', '-A', '0', '--',
        '-root', '/otp', '-bindir', '/otp/bin', '-progname', 'erl', '--',
        '-home', '/', '-boot', '/otp/bin/start_clean', '-noshell', '-eval', expr],
      preRun: [(m) => { module = m; Object.assign(m.ENV, { BINDIR: '/otp/bin', ROOTDIR: '/otp', EMU: 'beam', PROGNAME: 'erl' }); }],
      print: (s) => out.push(s),
      printErr: (s) => out.push(s),
      // Workers compile no WebAssembly at run time: use the imported module.
      instantiateWasm: (imports, done) => {
        WebAssembly.instantiate(wasm, imports).then((instance) => done(instance));
        return {};
      },
      onExit: (code) => exited(code),
    }).catch((e) => { out.push(String(e)); exited(-1); });
    const code = await exit;
    const mb = module ? Math.round(module.HEAPU8.length / 1048576) : '?';
    return new Response(out.join('\n') + `\n[exit status ${code}, memory ${mb} MB]\n`, {
      headers: { 'content-type': 'text/plain; charset=utf-8' },
    });
  },
};
