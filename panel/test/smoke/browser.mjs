// Real-browser smoke test: Login Flow v2 through the Nextcloud UI in the same window, every page, CSP errors.
// Usage: node browser.mjs <screenshot-dir>   (env: PLAYWRIGHT_MODULES, CHROMIUM, JSQR_DIR — all optional)
import { createRequire } from 'module';
const require = createRequire((process.env.PLAYWRIGHT_MODULES || '/opt/node22/lib/node_modules') + '/');
const { chromium } = require('playwright');
let jsQR = null;
try { jsQR = createRequire((process.env.JSQR_DIR || process.cwd()) + '/')('jsqr'); } catch { /* QR decode check skipped */ }

const PANEL = 'https://127.0.0.1:' + (process.env.SMOKE_PANEL_PORT || '19444');
const NC_PORT = process.env.SMOKE_NC_PORT || '19443';
const shots = process.argv[2] || 'shots';
const problems = [];

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true,
  ignoreHTTPSErrors: true, locale: 'zh-CN', colorScheme: 'light',
  userAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36 HomeVaultApp/0.1',
});
const page = await ctx.newPage();
page.on('console', (m) => { if (m.type() === 'error' && page.url().startsWith(PANEL)) problems.push('console: ' + m.text()); });
page.on('pageerror', (e) => problems.push('pageerror: ' + e.message));

const snap = async (name) => page.screenshot({ path: `${shots}/${name}.png`, fullPage: false });

await page.goto(PANEL + '/');
await page.getByRole('button', { name: '使用 Nextcloud 登录' }).waitFor({ timeout: 15000 });
await snap('01-login');
await page.getByRole('button', { name: '使用 Nextcloud 登录' }).click();
await page.waitForURL(new RegExp('127\\.0\\.0\\.1:' + NC_PORT + '/login/v2/flow'), { timeout: 15000 });
await page.waitForLoadState('networkidle');
await snap('02-nc-authpicker');
// Auth picker → "Log in"
await page.getByRole('button', { name: /log in|登录/i }).first().click();
await page.waitForURL(/\/login\?|\/login$/, { timeout: 15000 }).catch(() => {});
await page.waitForLoadState('networkidle');
await snap('03-nc-login');
await page.locator('input[name="user"]').fill('hvadmin');
await page.locator('input[name="password"]').fill('Smoke-Admin-Pass-2026!');
await page.locator('input[name="password"]').press('Enter');
await page.waitForURL(/login\/v2\/grant/, { timeout: 20000 });
await page.waitForLoadState('networkidle');
await snap('04-nc-grant');
await page.getByRole('button', { name: /grant access|授予访问权限|授予访问|授权/i }).first().click();
await page.waitForLoadState('networkidle');
await snap('05-nc-done');
// Back to the panel with the back button (as in the Android WebView)
for (let i = 0; i < 6 && !page.url().startsWith(PANEL); i++) {
  await page.goBack({ waitUntil: 'load' }).catch(() => {});
}
if (!page.url().startsWith(PANEL)) await page.goto(PANEL + '/');
await page.locator('h2', { hasText: '系统概览' }).waitFor({ timeout: 20000 });
await page.waitForTimeout(800);
await snap('06-overview');

const pages = [
  ['07-storage', '#/storage', '存储空间'],
  ['08-backup', '#/backup', '备份'],
  ['09-logs', '#/logs', '日志'],
  ['10-logfile', '#/logs?file=backup%2Fbackup-20260926-033000.log', null],
  ['11-container', '#/logs?service=app', null],
  ['12-vpn', '#/vpn', 'VPN 设备'],
  ['13-settings', '#/settings', '设置'],
];
for (const [name, hash, heading] of pages) {
  await page.goto(PANEL + '/' + hash);
  if (heading) await page.locator('h2', { hasText: heading }).waitFor({ timeout: 10000 });
  await page.waitForTimeout(1200);
  await snap(name);
}
// log search highlighting
await page.goto(PANEL + '/#/logs?file=backup%2Fbackup-20260926-033000.log');
await page.locator('input[type=search]').fill('error');
await page.locator('input[type=search]').press('Enter');
await page.waitForTimeout(800);
const marks = await page.locator('.logview mark').count();
if (marks !== 1) problems.push('expected 1 highlighted match, got ' + marks);
await snap('14-logsearch');

// QR codes on the settings page must decode to the absolute download URLs
await page.goto(PANEL + '/#/settings');
await page.locator('.qr-box canvas').first().waitFor({ timeout: 10000 });
const qrs = await page.evaluate(() => [...document.querySelectorAll('.qr-box canvas')].map((c) => {
  const d = c.getContext('2d').getImageData(0, 0, c.width, c.height);
  return { w: c.width, h: c.height, data: Array.from(d.data) };
}));
for (const q of jsQR ? qrs : []) {
  const r = jsQR(Uint8ClampedArray.from(q.data), q.w, q.h);
  console.log('QR decoded:', r ? r.data : null);
  if (!r || !new RegExp('^' + PANEL.replace(/\./g, '\\.') + '/(download/android|ca\\.crt)$').test(r.data)) problems.push('QR decode failed: ' + (r && r.data));
}

// retention change through the UI (custom dialog, no window.confirm)
await page.goto(PANEL + '/#/settings');
await page.locator('input[type=number]').waitFor();
await page.locator('input[type=number]').fill('30');
await page.getByRole('button', { name: '保存' }).click();
await page.locator('.toast').first().waitFor({ timeout: 5000 });
await snap('15-retention-saved');

// restart via confirm dialog
await page.goto(PANEL + '/#/overview');
await page.locator('h2', { hasText: '系统概览' }).waitFor();
await page.waitForTimeout(800);
const restartBtn = page.getByRole('button', { name: /重启/ }).filter({ hasText: '重启' });
const count = await restartBtn.count();
await page.locator('li', { hasText: '缓存（Redis）' }).getByRole('button', { name: /重启/ }).click();
await page.locator('.modal').waitFor();
await snap('16-restart-dialog');
await page.locator('.modal').getByRole('button', { name: '重启' }).click();
await page.locator('.toast').first().waitFor({ timeout: 30000 });

// dark mode
const dark = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, ignoreHTTPSErrors: true, colorScheme: 'dark' });
await dark.addCookies((await ctx.cookies()).filter((c) => c.name === '__Host-hvpanel'));
const dp = await dark.newPage();
dp.on('pageerror', (e) => problems.push('dark pageerror: ' + e.message));
await dp.goto(PANEL + '/#/overview');
await dp.locator('h2', { hasText: '系统概览' }).waitFor({ timeout: 10000 });
await dp.waitForTimeout(800);
await dp.screenshot({ path: `${shots}/17-overview-dark.png` });
await dp.goto(PANEL + '/#/storage');
await dp.waitForTimeout(1200);
await dp.screenshot({ path: `${shots}/18-storage-dark.png` });

// desktop layout
const desk = await browser.newContext({ viewport: { width: 1280, height: 800 }, ignoreHTTPSErrors: true });
await desk.addCookies((await ctx.cookies()).filter((c) => c.name === '__Host-hvpanel'));
const dk = await desk.newPage();
await dk.goto(PANEL + '/#/overview');
await dk.locator('h2', { hasText: '系统概览' }).waitFor({ timeout: 10000 });
await dk.waitForTimeout(800);
await dk.screenshot({ path: `${shots}/19-desktop.png` });

// normal browser (no HomeVaultApp in the User-Agent): the Nextcloud login page opens in a new tab
// and the panel tab keeps waiting/polling
const plain = await browser.newContext({ viewport: { width: 1280, height: 800 }, ignoreHTTPSErrors: true, locale: 'zh-CN' });
const pp = await plain.newPage();
pp.on('pageerror', (e) => problems.push('plain pageerror: ' + e.message));
await pp.goto(PANEL + '/');
await pp.getByRole('button', { name: '使用 Nextcloud 登录' }).waitFor({ timeout: 15000 });
const [popup] = await Promise.all([
  plain.waitForEvent('page', { timeout: 15000 }),
  pp.getByRole('button', { name: '使用 Nextcloud 登录' }).click(),
]);
await popup.waitForURL(new RegExp('127\\.0\\.0\\.1:' + NC_PORT + '/login/v2/'), { timeout: 15000 }).catch(() => {});
if (!new RegExp(':' + NC_PORT + '/login/v2/').test(popup.url())) problems.push('new tab did not open the Nextcloud login page: ' + popup.url());
if (!pp.url().startsWith(PANEL)) problems.push('panel tab navigated away: ' + pp.url());
await pp.getByText('已在新标签页打开 Nextcloud 登录页').waitFor({ timeout: 10000 }).catch(() => problems.push('waiting hint missing'));
if (await popup.evaluate(() => window.opener !== null)) problems.push('login tab keeps window.opener');
await pp.screenshot({ path: `${shots}/20-login-newtab-waiting.png` });
await pp.getByRole('button', { name: '取消' }).click();
await pp.getByRole('button', { name: '使用 Nextcloud 登录' }).waitFor({ timeout: 10000 });
await plain.close();

// horizontal overflow check on mobile pages
for (const hash of ['#/overview', '#/storage', '#/backup', '#/logs', '#/vpn', '#/settings']) {
  await page.goto(PANEL + '/' + hash);
  await page.waitForTimeout(900);
  const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (over > 1) problems.push(`horizontal overflow ${over}px on ${hash}`);
}

// logout through the UI
await page.goto(PANEL + '/#/settings');
await page.getByRole('button', { name: '退出登录' }).last().click();
await page.locator('.modal').getByRole('button', { name: '退出' }).click();
await page.getByRole('button', { name: '使用 Nextcloud 登录' }).waitFor({ timeout: 15000 });

console.log('restart buttons:', count);
console.log(problems.length ? 'PROBLEMS:\n' + problems.join('\n') : 'NO PROBLEMS');
await browser.close();
