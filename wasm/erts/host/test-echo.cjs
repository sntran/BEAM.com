// Test of wasm_host: Erlang echoes 3 events, and the host counts the replies.
const [root, ebin] = process.argv.slice(2);
const opts = {
  arguments: ['-S', '1', '--', '-root', root, '-bindir', root + '/bin', '-progname', 'erl', '--',
    '-home', '/', '-boot', root + '/bin/start_clean', '-pa', ebin, '-noshell', '-eval',
    'Loop = fun L(0) -> halt(); L(N) -> E = wasm_host:recv(), wasm_host:send([<<"echo:">>, E]), L(N - 1) end, Loop(3).'],
};
const got = [];
let Module;
opts.preRun = [(m) => { Module = m; m.beamHost.onsend = (b) => { got.push(Buffer.from(b).toString()); console.log('host got', got.at(-1)); }; }];
require(process.cwd() + '/beam.cjs')(opts);
setTimeout(() => Module.beamHost.push(Buffer.from('one')), 300);
setTimeout(() => { Module.beamHost.push(Buffer.from('two')); Module.beamHost.push(Buffer.from('three')); }, 600);
