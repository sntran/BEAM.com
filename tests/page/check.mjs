// The browser check of the static site of beam.com INPUT -o DIR
// --target wasm32 (DIR/page/):
//
//   node tests/page/check.mjs DIR/page [--base /repo/] [--phoenix-demo]
//
// It serves DIR/page/ at the path --base (default /), as GitHub Pages does:
// a project site is at /REPO/, a custom domain at /. Then it opens the site
// in headless Chromium and checks that the VM starts and that the frame of
// the app shows the app at BASE/app/.
//
// --phoenix-demo: also the checks of examples/phoenix_demo:
// - the home page shows;
// - a LiveView event (the shared counter) changes the page;
// - a link of the app with the path "/" stays in the frame;
// - the link to the login page stays under BASE/app/;
// - the login form (a POST through the service worker) works: the app
//   answers "Invalid email or password".
//
// Needs playwright-core (npm install --prefix wasm) and a Chromium with
// JSPI (137 or later): CHROMIUM, else the browser of Playwright, else
// Chrome. TIMEOUT (ms, default 180000) bounds the start of the VM.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(new URL('../../wasm/package.json', import.meta.url));
const { chromium } = require('playwright-core');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name, value) => (args.includes(name) ? args[args.indexOf(name) + 1] : value);
const dir = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--base');
if (!dir) {
  console.error('usage: node tests/page/check.mjs DIR/page [--base /repo/] [--phoenix-demo]');
  process.exit(2);
}
const base = `/${option('--base', '/').replace(/^\/+|\/+$/g, '')}/`.replace(/^\/\/$/, '/');
const timeout = Number(process.env.TIMEOUT ?? 180000);

const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.txt': 'text/plain', '.png': 'image/png',
};

// GitHub Pages: a directory gives its index.html, a directory without "/"
// is a redirect, and another path outside the site is a 404.
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const file = url.pathname.startsWith(base) && path.join(dir, decodeURIComponent(url.pathname.slice(base.length)));
  try {
    if (!file || !path.resolve(file).startsWith(path.resolve(dir))) throw new Error('outside');
    const s = await stat(file);
    if (s.isDirectory()) {
      if (!url.pathname.endsWith('/')) {
        res.writeHead(301, { location: `${url.pathname}/` });
        return res.end();
      }
      return send(res, path.join(file, 'index.html'));
    }
    return send(res, file);
  } catch {
    res.writeHead(404, { 'content-type': 'text/html' });
    res.end('<h1>404</h1>');
  }
});

async function send(res, file) {
  const data = await readFile(file);
  res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream',
                       'cache-control': 'max-age=600' });
  res.end(data);
}

function executable() {
  if (process.env.CHROMIUM) return { executablePath: process.env.CHROMIUM };
  const pw = '/opt/pw-browsers/chromium';
  if (existsSync(pw)) return { executablePath: pw };
  return { channel: 'chrome' };
}

const log = [];
const step = (text) => console.log(`page: ${text}`);

async function check(page, origin) {
  const t0 = Date.now();
  await page.goto(`${origin}${base}`);
  await page.waitForFunction(() => document.body.classList.contains('running')
                             || document.getElementById('status')?.classList.contains('err'), null, { timeout });
  const error = await page.$eval('#status', (s) => (s.classList.contains('err') ? s.textContent : null));
  if (error) throw new Error(`the page says: ${error}`);
  step(`the app shows in ${Date.now() - t0} ms`);
  const frame = page.frames().find((f) => f.parentFrame() === page.mainFrame());
  const app = `${origin}${base}app/`;
  if (frame.url() !== app) throw new Error(`the frame is at ${frame.url()}, not ${app}`);
  if (!flag('--phoenix-demo')) return;

  await frame.waitForSelector('#click', { timeout: 30000 });
  await frame.waitForSelector('[data-phx-main].phx-connected', { timeout: 30000 });
  step('the home page shows, and its LiveView is connected');

  const before = Number(await frame.textContent('#clicks'));
  await frame.click('#click');
  await frame.waitForFunction((n) => Number(document.getElementById('clicks').textContent) === n + 1, before,
                              { timeout: 30000 });
  step(`a LiveView event changes the page: the counter goes from ${before} to ${before + 1}`);

  const home = await frame.$('a[href="/"]');
  if (home) {
    await Promise.all([frame.waitForNavigation({ timeout: 30000 }), home.click()]);
    if (frame.url() !== app) throw new Error(`the link "/" went to ${frame.url()}, not ${app}`);
    await frame.waitForSelector('#click', { timeout: 30000 });
    step('a link of the app with the path "/" stays in the frame');
  }

  const login = await frame.getAttribute('a[href$="/users/log-in"]', 'href');
  if (login !== `${base}app/users/log-in`) throw new Error(`the link to the login page is ${login}`);
  await Promise.all([frame.waitForURL(`${app}users/log-in`, { timeout: 30000 }),
                     frame.click('a[href$="/users/log-in"]')]);
  await frame.waitForSelector('#login_form_password', { timeout: 30000 });
  step(`the link to the login page stays under ${base}app/`);

  await frame.fill('#login_form_password input[type=email]', 'nobody@example.com');
  await frame.fill('#login_form_password input[type=password]', 'not the password');
  await frame.click('#login_form_password button');
  await frame.waitForSelector('text=Invalid email or password', { timeout: 30000 });
  if (frame.url() !== `${app}users/log-in`) throw new Error(`after the login form, the frame is at ${frame.url()}`);
  step('the login form (a POST) works: the app answers "Invalid email or password"');
}

server.listen(0, '127.0.0.1', async () => {
  const origin = `http://127.0.0.1:${server.address().port}`;
  step(`serve ${dir} at ${origin}${base}`);
  const browser = await chromium.launch({ headless: true, ...executable() });
  let status = 0;
  try {
    const page = await browser.newPage();
    page.on('console', (m) => log.push(`console ${m.type()}: ${m.text()}`));
    page.on('pageerror', (e) => log.push(`page error: ${e.message}`));
    await check(page, origin);
    step('ok');
  } catch (e) {
    console.error(`page: FAIL ${e.message}`);
    for (const line of log.slice(-40)) console.error(`  ${line}`);
    status = 1;
  } finally {
    await browser.close();
    server.close();
    process.exit(status);
  }
});
