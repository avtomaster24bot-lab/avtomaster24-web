// Локальный тест уведомлений в демо-режиме: клиент создаёт заявку, демо-исполнитель принимает и пишет —
// у клиента появляется счётчик на «Заявки», всплывашка и (при разрешении) системное уведомление.
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://localhost:8099/';
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 400, height: 860 } });
  await ctx.route(/supabase\.co/, (r) => r.abort());
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(BASE); await p.waitForSelector('.hero'); await p.click('[data-demo=client]'); await p.waitForTimeout(3500);
  await p.goto(BASE + '#/new/tow'); await p.waitForSelector('#reqForm, #cOk');
  if (await p.$('#cOk')) { for (const c of await p.$$('input[data-kind]')) await c.check(); await p.click('#cOk'); await p.waitForSelector('#reqForm'); }
  await p.fill('#reqForm [name=location]', 'ул. Демо, 1'); await p.click('#reqForm button.p'); await p.waitForURL(/#\/request\/\d+/);
  await p.goto(BASE + '#/catalog');
  await p.waitForSelector('#nav [data-nav="requests"] .nbadge', { timeout: 30000 });
  const n = await p.textContent('#nav [data-nav="requests"] .nbadge'); const title = await p.title();
  await p.screenshot({ path: '/workspace/am24-shots/notify-demo.png' });
  await p.goto(BASE + '#/requests'); await p.waitForTimeout(500); const gone = !(await p.$('#nav [data-nav="requests"] .nbadge'));
  console.log(JSON.stringify({ badge: n, title, clearedOnOpen: gone, errs }));
  await b.close(); process.exit(n && gone && !errs.length ? 0 : 1);
})();
