const { chromium } = require('@playwright/test');
(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,<title>QA browser ready</title><button>Verify</button>');
    await page.getByRole('button', { name: 'Verify' }).click();
    if (await page.title() !== 'QA browser ready') throw new Error('Browser check failed');
    console.log('Playwright Chromium launch and interaction passed; no application UI tested.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
