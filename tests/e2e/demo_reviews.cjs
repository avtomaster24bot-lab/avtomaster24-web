// Отзывы (Обновление 7) в демо-режиме: модерация с пунктами правил, скрытие на проверку, удаление после проверки,
// правка/удаление автором, запрет оценки своей организации, ПД-подсветка, годовой отчёт.
// Запуск: NODE_PATH=<node_modules с playwright> node tests/e2e/demo_reviews.cjs  (сайт: cd site && python3 -m http.server 8099)
const { chromium } = require('playwright');
const BASE = process.env.BASE || 'http://localhost:8099/';
(async () => {
  const b = await chromium.launch(); const errors = [];
  const ctx = await b.newContext({ viewport: { width: 1000, height: 900 }, locale: 'ru-RU' });
  await ctx.route(/supabase\.co/, (r) => r.abort());
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error' && !/supabase|ERR_FAILED|net::/.test(m.text())) errors.push('console: ' + m.text()); });
  p.on('dialog', (d) => d.type() === 'prompt' ? d.accept('Подтверждено: персональные данные') : d.accept());
  const step = async (n, fn) => { try { await fn(); console.log('OK  ', n); } catch (e) { console.log('FAIL', n, e.message.slice(0, 400)); errors.push(n); } };
  const accept = async () => { await p.waitForTimeout(300); if (await p.$('#cOk')) { for (const c of await p.$$('input[data-kind]')) await c.check(); await p.click('#cOk'); await p.waitForTimeout(400); } };
  const as = async (u) => { await p.evaluate((u) => localStorage.setItem('am24-demo-user', u), u); await p.goto(BASE + '#/'); await p.reload(); await p.waitForTimeout(500); await accept(); };
  const go = async (h, sel) => { await p.goto(BASE + h); await p.waitForTimeout(350); await accept(); if (sel) await p.waitForSelector(sel); };
  const toastHas = async (re) => { await p.waitForFunction((s) => new RegExp(s).test(document.querySelector('#toast')?.textContent || ''), re.source, { timeout: 5000 }); };
  const main = () => p.textContent('main');
  await p.goto(BASE); await p.waitForSelector('.hero');
  // две выполненные заявки: клиента и владельца СТО №1 (для проверки «своя организация»)
  await p.evaluate(() => { const d = JSON.parse(localStorage.getItem('am24-demo-db-v2'));
    const base = { type: 'sto', city: 'Талдыкорган', status: 'completed', category_id: 2, subcategory: 'Замена амортизаторов', description: 'ТЕСТ отзывы', vehicle_info: 'Toyota', details: {}, accepted_by: 1, created_at: new Date().toISOString(), updated_at: new Date().toISOString() };
    d.requests.push({ ...base, id: 901, user_id: 'u-client' }, { ...base, id: 902, user_id: 'u-master' }); localStorage.setItem('am24-demo-db-v2', JSON.stringify(d)); });
  await as('u-client');
  await step('клиент: отзыв с телефоном → предупреждение и модерация', async () => {
    await go('#/request/901', '#revForm'); await p.click('label[for=rt2]'); await p.fill('#revForm [name=comment]', 'Долго. Мастер дал номер +7 701 111 22 33'); await p.click('#revForm button.p'); await toastHas(/Спасибо/);
    await p.waitForSelector('#myRev'); if (!/на модерации/.test(await main())) throw new Error('нет статуса');
  });
  await step('владелец не оценивает свою организацию', async () => {
    await as('u-master'); await go('#/request/902', '#revForm'); await p.click('#revForm button.p'); await toastHas(/свою организацию/);
  });
  await as('u-admin');
  const rvId = () => p.evaluate(() => JSON.parse(localStorage.getItem('am24-demo-db-v2')).reviews.find((r) => r.request_id === 901).id);
  await step('модератор: подсветка ПД и скрытие по п. 3.3', async () => {
    await go('#/admin?t=reviews', 'form[data-rvh]'); if (!(await p.$('mark.pii'))) throw new Error('нет подсветки');
    const f = `form[data-rvh="${await rvId()}"]`; await p.selectOption(f + ' [name=rule]', 'pii'); await p.fill(f + ' [name=reason]', 'Уберите номер телефона'); await p.click(f + ' button.danger'); await toastHas(/Скрыто/);
    await p.waitForSelector('[data-rvd]'); if (!/п\. 3\.3/.test(await main())) throw new Error('нет пункта');
  });
  await step('автор видит причину и исправляет → снова модерация', async () => {
    await as('u-client'); await go('#/request/901', '#myRev'); const t = await main(); if (!/скрыт модератором/.test(t) || !/Уберите номер/.test(t)) throw new Error('нет причины: ' + (await p.textContent('#myRev')).replace(/\s+/g, ' ').slice(0, 600));
    await p.click('[data-rev-edit]'); await p.fill('#revEdit [name=comment]', 'Долго, но сделали хорошо'); await p.click('#revEdit button'); await toastHas(/модерации/);
  });
  await step('модератор публикует → на странице «по выполненной заявке»', async () => {
    await as('u-admin'); const sel = `[data-rvp="${await rvId()}"]`; await go('#/admin?t=reviews', sel); await p.click(sel); await toastHas(/Опубликовано/);
    await go('#/provider/1', '.rev'); if (!/по выполненной заявке/.test(await main())) throw new Error('нет метки');
  });
  await step('жалоба → скрыть на время проверки → удалить с основанием', async () => {
    const rv = await rvId();
    await as('u-other'); await go(`#/complaint?type=review&id=${rv}`, 'form');
    const f = await p.$('#cmpForm') ? '#cmpForm' : 'main form'; await p.fill(f + ' [name=reason]', 'Ложь').catch(() => {}); await p.fill(f + ' [name=body]', 'В отзыве неправда про сроки'); await p.click(f + ' button.p'); await p.waitForTimeout(600);
    await as('u-admin'); await go('#/admin?t=complaints', `[data-rvhold="${rv}"]`); await p.click(`[data-rvhold="${rv}"]`); await toastHas(/проверки/);
    await p.waitForSelector(`[data-rvd="${rv}"]`); await p.click(`[data-rvd="${rv}"]`); await toastHas(/удалён/);
    const left = await p.evaluate((id) => JSON.parse(localStorage.getItem('am24-demo-db-v2')).reviews.some((r) => r.id === id), rv); if (left) throw new Error('не удалён');
  });
  await step('журнал и годовой отчёт', async () => {
    await go('#/admin?t=log', 'table'); if (!/Отзыв/.test(await main())) throw new Error('нет в журнале');
    await go('#/transparency', 'h1'); const t = await main(); if (!/Отчёт за год/.test(t) || !/Принятые меры/.test(t)) throw new Error('нет отчёта');
  });
  await step('автор оценивает снова и удаляет свой отзыв', async () => {
    await as('u-client'); await go('#/request/901', '#revForm'); await p.click('#revForm button.p'); await toastHas(/Спасибо/);
    await p.waitForSelector('[data-rev-del]'); await p.click('[data-rev-del]'); await toastHas(/удалён/); await p.waitForSelector('#revForm');
  });
  await step('правила отзывов RU/KK', async () => {
    await go('legal/reviews.html', 'article'); if (!/3\.5\./.test(await p.textContent('article'))) throw new Error('ru');
    await go('legal/kk/reviews.html', 'article'); if (!/орындалған өтінім бойынша/.test(await p.textContent('article'))) throw new Error('kk');
  });
  await b.close(); console.log(errors.length ? 'ERRORS: ' + JSON.stringify(errors) : 'NO ERRORS'); process.exit(errors.length ? 1 : 0);
})();
