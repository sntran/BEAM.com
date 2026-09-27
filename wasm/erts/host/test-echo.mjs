// Test of wasm_host: Erlang echoes 3 events, and the host counts the replies.
//   cd wasm/erts/build && node ../host/test-echo.mjs ROOT EBIN
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, ebin] = process.argv.slice(2);
const opts = {
  arguments: ['-S', '1', '--', '-root', root, '-bindir', root + '/bin', '-progname', 'erl', '--',
    '-home', '/', '-boot', root + '/bin/start_clean', '-pa', ebin, '-noshell', '-eval',
    'Loop = fun L(0) -> halt(); L(N) -> E = wasm_host:recv(), wasm_host:send([<<"echo:">>, E]), L(N - 1) end, Loop(3).'],
};
const got = [];
let Module;
opts.preRun = [(m) => { Module = m; m.beamHost.onsend = (b) => { got.push(Buffer.from(b).toString()); console.log('host got', got.at(-1)); }; }];
const { default: createBeam } = await import(pathToFileURL(resolve('beam.mjs')));
createBeam(opts);
setTimeout(() => Module.beamHost.push(Buffer.from('one')), 300);
setTimeout(() => { Module.beamHost.push(Buffer.from('two')); Module.beamHost.push(Buffer.from('three')); }, 600);
