// Opens N counter pages at the same time (LiveView sockets), clicks in each,
// and checks the counts.   node load-test.mjs URL N
import { chromium } from 'playwright-core';
const [url = 'http://localhost:8789/counter', n = '20'] = process.argv.slice(2);

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const t0 = Date.now();
const pages = await Promise.all(Array.from({ length: Number(n) }, async () => {
  const page = await browser.newPage();
  await page.goto(url);
  await page.waitForSelector('.phx-connected', { timeout: 30000 });
  return page;
}));
console.log(`${pages.length} sockets connected in ${Date.now() - t0} ms`);
const t1 = Date.now();
await Promise.all(pages.map(async (page, i) => {
  for (let k = 0; k <= i % 3; k++) await page.click('button:has-text("+")');
  await page.waitForFunction((c) => document.querySelector('#count').textContent === String(c), (i % 3) + 1);
}));
console.log(`clicks in all pages done in ${Date.now() - t1} ms`);
await browser.close();
