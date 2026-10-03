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
//   answers "Invalid email or password";
// - the URL of the page keeps the path of the frame in its fragment
//   (#/users/log-in): a reload, a LiveView navigation, a link to
//   BASE/app/PATH with the service worker and at the first visit (404.html),
//   and a fragment that is not a path.
//
// --tabs: also the checks of the tabs of a site (examples/phoenix_demo):
// - two tabs show the app, with one VM in a SharedWorker;
// - a click on the shared counter in one tab shows in the other tab;
// - when the first tab closes, the second tab still works;
// - a reload of the only tab keeps the VM and the counter (Chrome 148 or
//   later, with extendedLifetime; an older browser restores the snapshot);
// - 35 s after all the tabs close, the VM stopped: the next visit restores
//   it from the snapshot;
// - a boot in the SharedWorker that fails one time gets one more start, so
//   the site has one VM; a SharedWorker that always fails gives the VM in
//   the tab;
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
// is a redirect, a path of the site with no file gives 404.html of the site,
// and another path outside the site is a 404.
// failRelease: the next request of release.bin fails (the check of a failed
// boot).
let failRelease = false;
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (failRelease && url.pathname.endsWith('/release.bin')) {
    failRelease = false;
    res.writeHead(503);
    return res.end();
  }
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
    // GitHub Pages gives the 404.html of the site for a path with no file.
    if (file && existsSync(path.join(dir, '404.html'))) return send(res, path.join(dir, '404.html'), 404);
    res.writeHead(404, { 'content-type': 'text/html' });
    res.end('<h1>404</h1>');
  }
});

async function send(res, file, status = 200) {
  const data = await readFile(file);
  res.writeHead(status, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream',
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

// Waits for the page of the site in page (after a goto or a reload), and
// gives the frame of the app.
async function land(page) {
  await page.waitForFunction(() => document.body?.classList.contains('running')
                             || document.getElementById('status')?.classList.contains('err'), null, { timeout });
  const error = await page.$eval('#status', (s) => (s.classList.contains('err') ? s.textContent : null));
  if (error) throw new Error(`the page says: ${error}`);
  return page.frames().find((f) => f.parentFrame() === page.mainFrame());
}

// Polls the URL of page until it ends with end.
async function urlEnds(page, end) {
  for (let t = 0; t < 300; t++) {
    if (page.url().endsWith(end)) return;
    await new Promise((done) => setTimeout(done, 100));
  }
  throw new Error(`the URL of the page is ${page.url()}, not ...${end}`);
}

// The path of the frame in the fragment of the URL of the page (#67).
async function links(browser, origin) {
  const site = `${origin}${base}`;
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(site);
  let frame = await land(page);
  await live(frame);
  await frame.click('a[href$="/users/log-in"]');
  await urlEnds(page, '#/users/log-in');
  await page.reload();
  frame = await land(page);
  await frame.waitForSelector('#login_form_password', { timeout: 30000 });
  if (frame.url() !== `${site}app/users/log-in`) throw new Error(`after the reload, the frame is at ${frame.url()}`);
  step('the URL of the page ends with #/users/log-in, and a reload shows the login page');

  await frame.click('a[href$="/users/register"]');
  await urlEnds(page, '#/users/register');
  step('after a LiveView navigation in the frame, the fragment has the new path');

  // With the service worker: a top window in the scope goes to the page.
  const tab = await context.newPage();
  await tab.goto(`${site}app/users/log-in`);
  await urlEnds(tab, '#/users/log-in');
  frame = await land(tab);
  await frame.waitForSelector('#login_form_password', { timeout: 30000 });
  step('with the VM on, BASE/app/users/log-in in a new tab shows the login page at BASE#/users/log-in');

  for (const fragment of ['#//example.com', '#https://example.com', '#javascript:x', '#/\\example.com']) {
    const p = await context.newPage();
    await p.goto(`${site}${fragment}`);
    const f = await land(p);
    await f.waitForLoadState('load');
    if (new URL(f.url()).origin !== origin || !f.url().startsWith(`${site}app/`)) {
      throw new Error(`the fragment ${fragment} opened ${f.url()}`);
    }
    await p.close();
  }
  step('a fragment that is not a path keeps the frame in the app');
  await context.close();

  // No service worker yet: GitHub Pages gives 404.html, which goes to the page.
  const fresh = await browser.newContext();
  const first = await fresh.newPage();
  await first.goto(`${site}app/users/log-in?x=1`);
  await urlEnds(first, '#/users/log-in?x=1');
  frame = await land(first);
  await frame.waitForSelector('#login_form_password', { timeout: 30000 });
  if (frame.url() !== `${site}app/users/log-in?x=1`) throw new Error(`at the first visit, the frame is at ${frame.url()}`);
  step('at the first visit, BASE/app/users/log-in goes through 404.html to the login page at BASE#/users/log-in');
  const miss = await fresh.newPage();
  const r = await miss.goto(`${site}no-such-file`);
  await miss.waitForSelector('#missing:not([hidden])', { timeout: 30000 });
  if (r.status() !== 404) throw new Error(`a missing file gave ${r.status()}`);
  step('another missing path shows the 404 text');
  await fresh.close();
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

  // A reload of the only tab. The VM stops 30 s after the last tab leaves
  // (vm.js), and extendedLifetime (Chrome 148 or later) keeps the
  // SharedWorker that long: the reload keeps the VM and the counter. An older
  // browser stops the SharedWorker at once: the reload restores the VM from
  // the snapshot.
  const lifetime = Number(browser.version().split('.')[0]) >= 148;
  const r = await open(two, origin);
  if (r.error) throw new Error(`the reload says: ${r.error}`);
  await live(r.frame);
  const after = await clicks(r.frame);
  if (r.restored === 'false' && after === n + 2) {
    step(`a reload of the only tab kept the VM: the counter is still ${after}`);
  } else if (!lifetime && r.restored === 'true' && after === 0) {
    step('a reload of the only tab restored the VM from the snapshot (this browser has no extendedLifetime)');
  } else {
    throw new Error(`after a reload of the only tab: restored ${r.restored}, counter ${after}`);
  }
  await two.close();

  // All the tabs closed: the VM stops after 30 s. A visit after 35 s
  // restores it from the snapshot. No page of the site is open meanwhile,
  // because a new page would keep the VM.
  await new Promise((done) => setTimeout(done, 35000));
  const c = await open(await context.newPage(), origin);
  if (c.error) throw new Error(`the next visit says: ${c.error}`);
  if (c.restored !== 'true') throw new Error('35 s after all the tabs closed, the next visit did not restore the VM from the snapshot');
  await live(c.frame);
  await counted(c.frame, 0);
  step('all the tabs closed; 35 s later, the next visit restored the VM from the snapshot (the counter is 0)');
  await context.close();

  // A boot in the SharedWorker that fails one time (here: release.bin fails
  // one time). The page starts it one more time on the same port, so the
  // first tab runs in the SharedWorker, and the site has one VM.
  const once = await browser.newContext();
  failRelease = true;
  const f = await open(await once.newPage(), origin);
  if (f.error || f.where !== 'shared') throw new Error(`after one failed boot, the first tab: ${f.error ?? f.where}`);
  await live(f.frame);
  const g = await open(await once.newPage(), origin);
  if (g.error || g.where !== 'shared') throw new Error(`after one failed boot, the next tab: ${g.error ?? g.where}`);
  step('a boot that failed one time got one more start: the tabs run in the SharedWorker');
  await once.close();

  // A SharedWorker whose VM fails at each start (a stand-in for a browser
  // that cannot run the VM there): two starts, then the VM runs in the tab,
  // and another tab shows a message.
  const each = await browser.newContext();
  await each.addInitScript(() => {
    globalThis.starts = 0;
    globalThis.SharedWorker = class extends EventTarget {
      constructor() {
        super();
        const { port1, port2 } = new MessageChannel();
        port2.onmessage = (e) => {
          if (e.data.type !== 'start') return;
          globalThis.starts += 1;
          port2.postMessage({ type: 'error', message: 'no VM in this SharedWorker' });
        };
        this.port = port1;
      }
    };
  });
  const p = await each.newPage();
  const x1 = await open(p, origin);
  const tries = await p.evaluate(() => globalThis.starts);
  if (x1.error || x1.where !== 'tab' || tries !== 2) {
    throw new Error(`a SharedWorker that always fails: ${x1.error ?? x1.where}, ${tries} starts`);
  }
  await live(x1.frame);
  const y1 = await open(await each.newPage(), origin);
  if (!/another tab/.test(y1.error ?? '')) throw new Error(`a SharedWorker that always fails, the next tab: ${y1.error ?? 'the app'}`);
  step('a SharedWorker that always fails: two starts, then the VM runs in the tab, and another tab shows a message');
  await each.close();

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
    if (flag('--phoenix-demo')) await links(browser, origin);
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
