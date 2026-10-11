// The site of a native app.com, for the browser check (check.mjs --cdn):
//
//   node tests/page/app-site.mjs RUNTIME APP.com DIR [PORTS]
//
// It writes into DIR the files that a site needs on its own origin, with
// the code of the page from the npm package (RUNTIME: runtime/ of
// scripts/npm.sh, at the URL @BEAM_COM@ that check.mjs gives):
// - index.html and 404.html of the page, with the start of main.js of the
//   package and the option app;
// - sw.js and vm.js: a service worker and a SharedWorker must come from
//   the origin of the site, so these import the ones of the package;
// - app.com, and .nojekyll (GitHub Pages: no Jekyll);
// - with PORTS (a module of bindings, as tests/host/ports/page.js): that
//   module and the modules that it imports from its directory, and the
//   option ports of main.js.
import fs from 'node:fs';
import path from 'node:path';

const [runtime, app, out, ports] = process.argv.slice(2);
if (!out) {
  console.error('usage: node tests/page/app-site.mjs RUNTIME APP.com DIR [PORTS]');
  process.exit(2);
}
const CDN = '@BEAM_COM@';
fs.mkdirSync(out, { recursive: true });
const index = fs.readFileSync(path.join(runtime, 'page', 'index.html'), 'utf8');
const start = "import { start } from './main.js';\n  start();";
if (!index.includes(start)) throw new Error('index.html: no start of main.js');
const options = ports ? `{ app: './app.com', ports: './${path.basename(ports)}' }` : "{ app: './app.com' }";
fs.writeFileSync(path.join(out, 'index.html'),
  index.replace(start, `import { start } from '${CDN}/page/main.js';\n  start(${options});`));
if (ports) {
  const source = fs.readFileSync(ports, 'utf8');
  const names = [...source.matchAll(/from '\.\/([\w.-]+\.js)'/g)].map((m) => m[1]);
  for (const name of [path.basename(ports), ...names]) {
    fs.copyFileSync(path.join(path.dirname(ports), name), path.join(out, name));
  }
}
fs.copyFileSync(path.join(runtime, 'page', '404.html'), path.join(out, '404.html'));
fs.writeFileSync(path.join(out, 'sw.js'), `import '${CDN}/page/sw.js';\n`);
fs.writeFileSync(path.join(out, 'vm.js'), `import '${CDN}/page/vm.js';\n`);
fs.copyFileSync(app, path.join(out, 'app.com'));
fs.writeFileSync(path.join(out, '.nojekyll'), '');
console.log(`app-site: wrote ${out}`);
