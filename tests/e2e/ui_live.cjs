// Боевой UI-тест в браузере (Playwright) тестовыми аккаунтами: две роли одновременно (клиент и СТО),
// уведомления, чат в реальном времени, «никто не ответил» (перемотка часов), каталог гостя, мобильный вид, KZ.
// Запуск: NODE_PATH=<node_modules с playwright и @supabase/supabase-js> BASE=https://avtomaster24bot-lab.github.io/avtomaster24-web/ node tests/e2e/ui_live.cjs
const { chromium } = require('playwright');
const { login } = require('./common.cjs');
const BASE = process.env.BASE || 'https://avtomaster24bot-lab.github.io/avtomaster24-web/';
const OUT = process.env.SHOTS || '/workspace/am24-shots/';
const IMG = process.env.PHOTO || require('path').join(__dirname, '../../site/assets/img/sto.webp');
const errors = []; let pass = 0, fail = 0;
const step = async (name, fn) => { try { await fn(); pass++; console.log('OK  ', name); } catch (e) { fail++; console.log('FAIL', name, '—', e.message.split('\n')[0].slice(0, 300)); errors.push(name); } };

(async () => {
  const b = await chromium.launch();
  const ctxFor = async (user, opts = {}) => {
    const ctx = await b.newContext({ viewport: { width: 400, height: 860 }, deviceScaleFactor: 2, locale: 'ru-RU', colorScheme: 'dark', ...opts });
    await ctx.addInitScript(([sess, city]) => {
      if (sessionStorage.getItem('am24-e2e-init')) return; sessionStorage.setItem('am24-e2e-init', '1');
      localStorage.setItem('am24-cookie-ok', '1'); localStorage.setItem('am24-city', city);
      if (sess) localStorage.setItem('am24-auth', JSON.stringify(sess)); else localStorage.removeItem('am24-auth');
    }, [user ? user.session : null, 'Талдыкорган']);
    const p = await ctx.newPage(); p.setDefaultTimeout(15000);
    p.on('pageerror', (e) => errors.push((user?.name || 'guest') + ' pageerror: ' + e.message));
    p.on('console', (m) => { if (m.type() === 'error' && !/favicon|net::ERR_ABORTED/.test(m.text())) errors.push((user?.name || 'guest') + ' console: ' + m.text().slice(0, 200)); });
    return { ctx, p };
  };
  const C = await login('test_client_2'), M = await login('test_sto_2');
  const { p: pc } = await ctxFor(C); const { p: pm } = await ctxFor(M);

  // гость: тестовые организации не видны
  await step('гость: каталог без тестовых организаций', async () => {
    const { p } = await ctxFor(null); await p.goto(BASE + '#/catalog/sto'); await p.waitForSelector('#view h1');
    await p.waitForTimeout(1500); const txt = await p.textContent('#view'); if (/ТЕСТ/.test(txt)) throw new Error('гость видит тестовые'); await p.screenshot({ path: OUT + 'live5-guest-catalog.png' });
  });
  await step('клиент вошёл (сессия), видит тестовые СТО с меткой ТЕСТ', async () => {
    await pc.goto(BASE + '#/catalog/sto'); await pc.waitForSelector('.test-badge'); await pc.screenshot({ path: OUT + 'live5-client-catalog.png' });
  });
  await step('исполнитель: кабинет открыт, звук разрешён жестом', async () => {
    await pm.goto(BASE + '#/cabinet'); await pm.waitForSelector('text=Кабинет'); await pm.mouse.click(5, 300); await pm.waitForTimeout(3500);
  });
  let rid;
  await step('клиент: заявка в СТО с фото', async () => {
    await pc.goto(BASE + '#/new/sto?cat=2'); await pc.waitForSelector('#reqForm');
    if (await pc.$('#subSel')) await pc.selectOption('#subSel', { index: 1 });
    await pc.fill('[name=vehicle_info]', 'ТЕСТ Toyota Camry 2015'); await pc.fill('#reqForm [name=description]', 'ТЕСТ: стук в подвеске (UI)');
    await pc.setInputFiles('#ph', IMG); await pc.waitForSelector('#phPrev img');
    await pc.click('#reqForm button.p'); await pc.waitForURL(/#\/request\/\d+/, { timeout: 20000 }); rid = pc.url().match(/request\/(\d+)/)[1];
    await pc.waitForSelector('.photos img'); await pc.screenshot({ path: OUT + 'live5-request.png', fullPage: true });
  });
  await step('исполнитель: уведомление о новой заявке (бейдж + всплывашка)', async () => {
    await pm.waitForSelector('.toast.link', { timeout: 30000 });
    await pm.waitForSelector(`[data-acc="${rid}"]`, { timeout: 8000 });   // лента обновилась сама
    await pm.screenshot({ path: OUT + 'live5-notify-provider.png' });
  });
  await step('исполнитель видит фото и принимает', async () => {
    await pm.goto(BASE + '#/cabinet'); await pm.waitForSelector(`[data-acc="${rid}"]`); await pm.waitForSelector('.photos img');
    await pm.click(`[data-acc="${rid}"]`); await pm.waitForSelector(`a[href="#/chat/${rid}"]`);
    await pm.click(`[data-contact="${rid}"]`); await pm.waitForSelector(`[data-c="${rid}"] a[href^="tel:"]`);
  });
  await step('клиент: уведомление «принял» и статус «В работе»', async () => {
    await pc.goto(BASE + '#/'); await pc.waitForSelector('#nav [data-nav="requests"] .nbadge, .toast.link', { timeout: 30000 });
    await pc.goto(BASE + '#/request/' + rid); await pc.waitForSelector('text=В работе');
  });
  await step('чат в реальном времени в обе стороны', async () => {
    await pc.goto(BASE + '#/chat/' + rid); await pc.waitForSelector('#chatF'); await pm.goto(BASE + '#/chat/' + rid); await pm.waitForSelector('#chatF');
    await pc.fill('#chatF [name=t]', 'ТЕСТ: когда сможете?'); await pc.click('#chatF button');
    await pm.waitForSelector('.msg:not(.me) >> text=ТЕСТ: когда сможете?', { timeout: 10000 });
    await pm.click('[data-q="Выезжаю"]'); await pc.waitForSelector('.msg:not(.me) >> text=Выезжаю', { timeout: 10000 });
    await pc.screenshot({ path: OUT + 'live5-chat-client.png' }); await pm.screenshot({ path: OUT + 'live5-chat-provider.png' });
  });
  await step('исполнитель завершает, клиент оценивает', async () => {
    await pm.goto(BASE + '#/cabinet'); await pm.waitForSelector(`[data-done="${rid}"]`); await pm.fill(`[data-done="${rid}"] [name=amount]`, '12000'); await pm.click(`[data-done="${rid}"] button`);
    await pm.waitForTimeout(1500);
    await pc.goto(BASE + '#/request/' + rid); await pc.waitForSelector('#revForm'); await pc.click('label[for=rt5]'); await pc.fill('#revForm textarea', 'ТЕСТ: отлично (UI)'); await pc.click('#revForm button.p');
    await pc.waitForSelector('text=Ваша оценка');
  });
  await step('«Пока никто не ответил» через 5 минут (перемотка часов)', async () => {
    const { ctx, p } = await ctxFor(C); await p.clock.install({ time: new Date() });
    await p.goto(BASE + '#/new/tow'); await p.waitForSelector('#reqForm');
    await p.fill('#reqForm [name=description]', 'ТЕСТ: проверка «никто не ответил»');
    await p.fill('#reqForm [name=location]', 'ТЕСТ: ул. Тестовая, 1');
    await p.click('#reqForm button.p'); await p.waitForURL(/#\/request\/\d+/, { timeout: 20000 }); const id = p.url().match(/request\/(\d+)/)[1];
    await p.clock.fastForward('06:00'); await p.goto(BASE + '#/requests'); await p.goto(BASE + '#/request/' + id);
    await p.waitForSelector('text=никто не ответил', { timeout: 15000 }); await p.screenshot({ path: OUT + 'live5-noanswer.png', fullPage: true });
    await p.click('text=Отменить').catch(() => {}); await ctx.close();
  });
  await step('профиль: настройки уведомлений, данные, KZ', async () => {
    await pc.goto(BASE + '#/profile'); await pc.waitForSelector('#nCard'); await pc.click('#langBtn'); await pc.waitForTimeout(500);
    await pc.screenshot({ path: OUT + 'live5-profile-kk.png', fullPage: true }); await pc.click('#langBtn');
  });
  await step('десктоп: главная и кабинет', async () => {
    const { p } = await ctxFor(M, { viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1 }); await p.goto(BASE + '#/cabinet'); await p.waitForSelector('.stats'); await p.screenshot({ path: OUT + 'live5-cabinet-desktop.png' });
  });
  console.log(`\nИТОГО UI: ${pass} OK, ${fail} FAIL`); if (errors.length) console.log('Ошибки:', errors);
  await b.close(); process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
