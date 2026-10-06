// The vars of the Wrangler file of a project (wrangler.jsonc, else
// wrangler.json), for npx beam.com --snapshot: the snapshot gets the
// BEAM_ERL_FLAGS of the Worker. Wrangler reads JSONC: comments (// and
// /* */) and a comma before } or ]. wrangler.toml is not read.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// {file, vars} of the first Wrangler file of dir, or null.
export function wranglerVars(dir = '.') {
  for (const name of ['wrangler.jsonc', 'wrangler.json']) {
    let text;
    try {
      text = readFileSync(join(dir, name), 'utf8');
    } catch {
      continue;
    }
    const vars = jsonc(text).vars;
    return { file: name, vars: vars && typeof vars === 'object' ? vars : {} };
  }
  return null;
}

// The value of a JSONC text.
export function jsonc(text) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      // A string, with its escapes, as it is.
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 1;
      out += ' ';
    } else {
      out += c;
    }
  }
  // A comma before } or ] (outside the strings, which have no newline).
  return JSON.parse(out.replace(/,(\s*[}\]])/g, '$1'));
}
