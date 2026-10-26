const { chromium } = require('playwright') /* NODE_PATH с playwright; сайт: cd site && python3 -m http.server 8099 */;
const BASE = process.env.BASE || 'http://localhost:8099/';
const OUT = '/workspace/am24-shots/';
(async () => {
  const b = await chromium.launch(); const errors = [];
  const ctx = await b.newContext({ colorScheme: 'dark', viewport: { width: 1100, height: 900 }, deviceScaleFactor: 1, locale: 'ru-RU' });
  await ctx.route(/supabase\.co/, (r) => r.abort());
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error' && !/supabase|ERR_FAILED|net::/.test(m.text())) errors.push('console: ' + m.text()); });
  p.on('dialog', (d) => d.type() === 'prompt' ? d.accept('Спам заявками') : d.accept());
  const step = async (n, fn) => { try { await fn(); console.log('OK  ', n); } catch (e) { console.log('FAIL', n, e.message.slice(0, 500)); errors.push(n); } };
  const shot = async (f) => { await p.addStyleTag({ content: '#toast,.cookie,#cookie,[class*=cookie]{display:none!important}' }); const h = await p.evaluate(() => document.documentElement.scrollHeight); await p.setViewportSize({ width: 1100, height: Math.min(h, 4000) }); await p.waitForTimeout(300); await p.screenshot({ path: OUT + f }); await p.setViewportSize({ width: 1100, height: 900 }); };
  const accept = async () => { await p.waitForTimeout(300); if (await p.$('#cOk')) { for (const c of await p.$$('input[data-kind]')) await c.check(); await p.click('#cOk'); await p.waitForTimeout(400); } };
  const as = async (u) => { await p.evaluate((u) => localStorage.setItem('am24-demo-user', u), u); await p.goto(BASE + '#/'); await p.reload(); await p.waitForTimeout(500); await accept(); };
  const go = async (h, sel) => { await p.goto(BASE + h); await p.waitForTimeout(300); await accept(); if (sel) await p.waitForSelector(sel); };
  const toastHas = async (re) => { await p.waitForFunction((s) => new RegExp(s).test(document.querySelector('#toast')?.textContent || ''), re.source, { timeout: 5000 }); };
  await p.goto(BASE); await p.waitForSelector('.hero');
  await as('u-admin');
  await step('global: overview role card + tabs', async () => { await go('#/admin', '.tabs'); const t = await p.textContent('main'); for (const w of ['главный администратор', 'Пользователи', 'Админы и права', 'Настройки', 'Журнал']) if (!t.includes(w)) throw new Error('нет ' + w); });
  await step('global: appoint regional admin by username', async () => {
    await go('#/admin?t=admins', '#admForm'); await p.fill('#admForm [name=username]', '@demo_staff'); await p.selectOption('#admForm [name=role]', 'regional_admin'); await p.selectOption('#admForm [name=city]', 'Алматы');
    await p.click('#admForm button.p'); await toastHas(/назначен/); await p.waitForTimeout(400); if (!(await p.textContent('main')).includes('Демо Сотрудник')) throw new Error('нет в списке');
  });
  await step('global: demote + last global protected', async () => {
    await p.click('[data-demote="u-staff"]'); await toastHas(/сняты/); await p.waitForTimeout(400);
    const t = await p.textContent('main'); if (!t.includes('последний главный')) throw new Error('нет защиты последнего главного');
  });
  await step('global: users search + block/unblock', async () => {
    await go('#/admin?t=users', '#uSearch'); await p.fill('#uSearch [name=q]', '+7700999'); await p.click('#uSearch button'); await p.waitForSelector('[data-blk="u-other"]');
    await p.click('[data-blk="u-other"]'); await toastHas(/заблокирован/); await p.waitForSelector('[data-unblk="u-other"]');
  });
  await step('settings: city notice + global limit', async () => {
    await go('#/admin?t=settings', '#setForm'); await p.fill('#setForm [name=max_open_requests]', '5'); await p.click('#setForm button.p'); await toastHas(/сохранены/);
    await go('#/admin?t=settings&c=' + encodeURIComponent('Талдыкорган'), '#setForm [name=city_notice]'); await p.fill('#setForm [name=city_notice]', 'Демо: в праздники эвакуаторы работают с 9 до 21'); await p.fill('#setForm [name=ttl_sto]', '90'); await p.click('#setForm button.p'); await toastHas(/сохранены/);
    await go('#/', '.hero'); if (!(await p.textContent('main')).includes('в праздники эвакуаторы')) throw new Error('нет объявления');
  });
  await step('log shows actions', async () => { await go('#/admin?t=log', 'table'); const t = await p.textContent('main'); for (const w of ['Роль', 'Блокировка', 'Настройка']) if (!t.includes(w)) throw new Error('нет ' + w); });
  await go('#/admin?t=admins', '.matrix'); await shot('admin-rights-demo.png');
  await step('blocked user sees banner and cannot create request', async () => {
    await as('u-other'); await go('#/new/sto', '#reqForm'); if (!(await p.textContent('main')).includes('заблокирован')) throw new Error('нет баннера');
  });
  await step('regional admin: own city only, no admins tab', async () => {
    await as('u-region'); await go('#/admin', '.tabs'); const t = await p.textContent('main');
    if (t.includes('Админы и права') || !t.includes('региональный администратор: Алматы')) throw new Error('неверные вкладки');
    await go('#/admin?t=settings', '#setForm'); if (await p.$('#setForm [name=max_open_requests]')) throw new Error('регион видит общие лимиты');
    await go('#/admin?t=users', '#uSearch'); if ((await p.textContent('main')).includes('Демо Клиент')) throw new Error('видит чужой город');
  });
  await step('owner: org settings pause + staff', async () => {
    await as('u-master'); await go('#/cabinet?p=1&t=settings', '#orgSet'); await p.check('#orgSet [name=paused]'); await p.click('#orgSet .opt:has(input[value="0"])'); await p.click('#orgSet button.p'); await toastHas(/Пауза/);
    await p.fill('#staffAdd [name=username]', 'demo_client'); await p.selectOption('#staffAdd [name=role]', 'manager'); await p.click('#staffAdd button'); await toastHas(/добавлен/);
    await p.waitForTimeout(400); const t = await p.textContent('main'); if (!t.includes('Демо Клиент') || !t.includes('Демо Сотрудник') || !t.includes('на паузе')) throw new Error('нет сотрудников/паузы');
  });
  await p.waitForTimeout(3600); await shot('org-settings-demo.png');
  await step('owner: unpause + assign to master', async () => {
    await p.uncheck('#orgSet [name=paused]'); await p.click('#orgSet button.p'); await toastHas(/Сохранено/);
    await go('#/cabinet?p=1', '.tabs'); const sel = await p.$('[data-assign]');
    if (!sel) { const acc = await p.$('[data-acc], button:has-text("Принять")'); if (acc) { await acc.click(); await p.waitForTimeout(600); } }
    await p.waitForSelector('[data-assign]'); await p.selectOption('[data-assign] >> nth=0', 'u-staff'); await toastHas(/поручена/);
  });
  await step('master (staff): sees only assigned, no accept, no settings', async () => {
    await as("u-staff"); await go("#/cabinet?p=1"); await p.waitForSelector(".tabs"); const t = await p.textContent('main');
    if (!t.includes('мастер') || t.includes('⚙ Настройки') || await p.$('button:has-text("Принять")')) throw new Error('лишние права мастера: ' + t.slice(0, 300)); if (!(await p.$('main .card .badge'))) throw new Error('мастер не видит поручённую заявку'); await go('#/chat/' + (await p.$eval('a[href^="#/chat/"]', (a) => a.getAttribute('href').split('/').pop())), '#chatF');
  });
  await step('client settings: language + theme card', async () => { await as('u-client'); await go('#/profile', '#uiCard'); await p.click('[data-lang=kk]'); await p.waitForTimeout(500); await p.click('[data-lang=ru]'); await p.waitForTimeout(300); });
  await b.close(); console.log(errors.length ? 'ERRORS: ' + JSON.stringify(errors) : 'NO ERRORS');
})();
