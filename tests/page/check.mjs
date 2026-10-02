// The browser check of the static site of beam.com INPUT -o DIR
// --target wasm32 (DIR/page/):
//
//   node tests/page/check.mjs DIR/page [--base /repo/] [--phoenix-demo] [--tabs]
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
// --tabs: also the checks of the tabs of a site (examples/phoenix_demo):
// - two tabs show the app, with one VM in a SharedWorker;
// - a click on the shared counter in one tab shows in the other tab;
// - when the first tab closes, the second tab still works;
// - when all the tabs close, the VM stops: the next visit restores it from
//   the snapshot;
// - with no SharedWorker, the VM runs in one tab, and another tab shows a
//   message.
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
  console.error('usage: node tests/page/check.mjs DIR/page [--base /repo/] [--phoenix-demo] [--tabs]');
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

// Opens the site in page. Gives the frame of the app, or the text of the
// error of the page.
async function open(page, origin) {
  await page.goto(`${origin}${base}`);
  await page.waitForFunction(() => document.body.classList.contains('running')
                             || document.getElementById('status')?.classList.contains('err'), null, { timeout });
  const error = await page.$eval('#status', (s) => (s.classList.contains('err') ? s.textContent : null));
  if (error) return { error };
  const frame = page.frames().find((f) => f.parentFrame() === page.mainFrame());
  const app = `${origin}${base}app/`;
  if (frame.url() !== app) throw new Error(`the frame is at ${frame.url()}, not ${app}`);
  const vm = await page.evaluate(() => ({ where: document.body.dataset.vm, restored: document.body.dataset.restored }));
  return { frame, ...vm };
}

const clicks = async (frame) => Number(await frame.textContent('#clicks'));
const counted = (frame, n) =>
  frame.waitForFunction((v) => Number(document.getElementById('clicks')?.textContent) === v, n, { timeout: 30000 });
const live = async (frame) => {
  await frame.waitForSelector('#click', { timeout: 30000 });
  await frame.waitForSelector('[data-phx-main].phx-connected', { timeout: 30000 });
};

async function check(page, origin) {
  const t0 = Date.now();
  const { frame, error } = await open(page, origin);
  if (error) throw new Error(`the page says: ${error}`);
  step(`the app shows in ${Date.now() - t0} ms`);
  const app = `${origin}${base}app/`;
  if (!flag('--phoenix-demo')) return;

  await live(frame);
  step('the home page shows, and its LiveView is connected');

  const before = await clicks(frame);
  await frame.click('#click');
  await counted(frame, before + 1);
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

async function tabs(browser, origin) {
  const context = await browser.newContext();
  const [one, two] = [await context.newPage(), await context.newPage()];
  const a = await open(one, origin), b = await open(two, origin);
  for (const t of [a, b]) {
    if (t.error) throw new Error(`a tab says: ${t.error}`);
    if (t.where !== 'shared') throw new Error(`the VM of a tab is in ${t.where}, not in a SharedWorker`);
    await live(t.frame);
  }
  step('two tabs show the app, with one VM in a SharedWorker');
  const n = await clicks(b.frame);
  await a.frame.click('#click');
  await counted(b.frame, n + 1);
  step('a click on the shared counter in one tab shows in the other tab');
  await one.close();
  await b.frame.click('#click');
  await counted(b.frame, n + 2);
  step('the first tab closed, and the second tab still works');
  await two.close();
  // The SharedWorker stops when its last tab closes. Its stop takes a moment,
  // so a page that comes too soon can still get the old VM: then open again.
  let c = null;
  for (let t = 0; t < 50; t++) {
    const page = await context.newPage();
    c = await open(page, origin);
    if (c.error) throw new Error(`the next visit says: ${c.error}`);
    if (c.restored === 'true') break;
    await page.close();
    await new Promise((r) => setTimeout(r, 100));
  }
  if (c.restored !== 'true') throw new Error('the next visit did not restore the VM from the snapshot');
  await live(c.frame);
  await counted(c.frame, 0);
  step('all the tabs closed, and the next visit restored the VM from the snapshot (the counter is 0)');
  await context.close();

  // No SharedWorker: one VM in one tab, as before.
  const old = await browser.newContext();
  await old.addInitScript(() => { delete globalThis.SharedWorker; });
  const x = await open(await old.newPage(), origin), y = await open(await old.newPage(), origin);
  if (x.error || x.where !== 'tab') throw new Error(`with no SharedWorker, the first tab: ${x.error ?? x.where}`);
  await live(x.frame);
  if (!/another tab/.test(y.error ?? '')) throw new Error(`with no SharedWorker, the second tab: ${y.error ?? 'the app'}`);
  step('with no SharedWorker, the VM runs in one tab, and another tab shows a message');
  await old.close();
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
    if (flag('--tabs')) await tabs(browser, origin);
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
