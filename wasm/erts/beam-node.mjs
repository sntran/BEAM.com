// Runs the WebAssembly emulator in Node.js with the arguments of the command
// line: node beam-node.mjs [EMULATOR FLAGS] -- [ERL ARGS]
import createBeam from './beam.mjs';

createBeam({ arguments: process.argv.slice(2) });
