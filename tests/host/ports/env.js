// The env of the page of tests/programs/ports_check.erl
// (tests/page/check.mjs --ports): the objects of the port programs of
// programs.js. The VM of the page imports this module (the option env of
// main.js), and each export is a binding.
import { echo, sink, source } from './programs.js';

export const ECHO = { port: echo };
export const SINK = { port: sink };
export const SOURCE = { port: source };
