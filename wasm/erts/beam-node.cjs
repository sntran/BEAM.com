// Runs the WebAssembly emulator in Node.js with the arguments of the command
// line: node beam-node.cjs [EMULATOR FLAGS] -- [ERL ARGS]
require('./beam.cjs')({ arguments: process.argv.slice(2) });
