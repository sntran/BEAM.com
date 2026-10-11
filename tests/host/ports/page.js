// The bindings of the page of tests/programs/ports_check.erl
// (tests/page/check.mjs --ports): the objects of the port programs of
// programs.js. The VM of the page imports this module (the option ports
// of main.js).
import { echo, sink, source } from './programs.js';

export const ECHO = { port: echo };
export const SINK = { port: sink };
export const SOURCE = { port: source };
