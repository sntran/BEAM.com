// Opens the page (index.html) in Chromium and prints the output of Erlang.
//   node browser-test.cjs URL   (playwright-core; CHROMIUM=path of chrome)
const { chromium } = require('playwright-core');
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
  const page = await browser.newPage();
  page.on('console', (m) => console.log('console:', m.text()));
  await page.goto(process.argv[2]);
  await page.waitForFunction(() => document.title === 'done', null, { timeout: 30000 });
  console.log(await page.textContent('#out'));
  console.log('JSPI:', await page.evaluate(() => typeof WebAssembly.Suspending), await browser.version());
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
