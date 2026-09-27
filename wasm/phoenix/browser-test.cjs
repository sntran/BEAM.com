// Drives the counter LiveView in Chromium: the socket connects, three
// clicks on "+" give 3, and the server pushes the seconds.
//   node browser-test.cjs URL   (playwright-core; CHROMIUM=path of chrome)
const { chromium } = require('playwright-core');
const url = process.argv[2] || 'http://127.0.0.1:4000/counter';
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
  const page = await browser.newPage();
  page.on('console', (m) => console.log('console:', m.text()));
  const t0 = Date.now();
  await page.goto(url);
  await page.waitForSelector('.phx-connected', { timeout: 20000 });
  console.log(`connected in ${Date.now() - t0} ms:`, await page.textContent('h1'));
  for (let i = 0; i < 3; i++) {
    const t = Date.now();
    await page.click('button:has-text("+")');
    await page.waitForFunction((n) => document.querySelector('#count').textContent === String(n), i + 1);
    console.log(`click ${i + 1}: count ${await page.textContent('#count')} after ${Date.now() - t} ms`);
  }
  await page.waitForTimeout(2500);
  console.log('ticks after 2.5 s:', await page.textContent('#ticks'));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
