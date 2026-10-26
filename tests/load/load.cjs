// Нагрузочный тест боевого API (PostgREST Supabase) — бережный к бесплатному тарифу.
// Профиль: 70% гостей читают каталог/отзывы/цены, 20% клиентов смотрят свои заявки и пишут в чат,
// 10% исполнителей опрашивают ленту. Заявки создаются редко (антиспам: ≤10 открытых и ≤20/час на пользователя).
// Запуск: NODE_PATH=... node tests/load/load.cjs [макс_VU=100] [минут_на_пике=2]
const { URL_, ANON, session } = require('../e2e/common.cjs');
const MAX = +(process.argv[2] || 100), PEAK_MIN = +(process.argv[3] || 2);
const STAGES = [[0.5, Math.round(MAX * 0.1)], [1, Math.round(MAX * 0.25)], [1, Math.round(MAX * 0.5)], [PEAK_MIN, MAX], [0.5, 0]]; // [минут, целевых VU]
const CITY = 'Талдыкорган';
const H = (tok) => ({ apikey: ANON, Authorization: 'Bearer ' + (tok || ANON), 'content-type': 'application/json' });
const stats = {}; let stage = 0, active = 0; const t0 = Date.now();
function rec(name, ms, ok, code) { const s = (stats[name] ||= { lat: [], err: 0, codes: {} }); s.lat.push(ms); if (!ok) { s.err++; s.codes[code] = (s.codes[code] || 0) + 1; } }
async function call(name, path, { method = 'GET', body, tok, expect } = {}) {
  const t = performance.now(); let code = 0, ok = false, j = null;
  try {
    const r = await fetch(URL_ + path, { method, headers: H(tok), body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
    code = r.status; const txt = await r.text(); try { j = JSON.parse(txt); } catch { j = txt; }
    ok = r.ok || (expect && expect.test(typeof j === 'string' ? j : JSON.stringify(j)));
  } catch (e) { code = e.name === 'TimeoutError' ? 'timeout' : 'net'; }
  rec(name, performance.now() - t, ok, code); return ok ? (j === '' ? true : j) : null;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pick = (a) => a[Math.floor(Math.random() * a.length)];
const think = () => sleep(1000 + Math.random() * 2000);
const enc = encodeURIComponent;
let PROVS = [], CLIENTS = [], PROVIDERS = [];

async function guest() {
  await call('ref:cities', '/rest/v1/am_cities?select=*&order=id');
  await call('ref:categories', '/rest/v1/am_categories?select=*&order=id');
  const kind = pick(['sto', 'tow', 'wash', 'parts', 'urgent']);
  await call('catalog:list', `/rest/v1/am_providers?select=*&is_active=eq.true&kind=eq.${kind}&city=eq.${enc(CITY)}&order=rating.desc`);
  const pid = PROVS.length ? pick(PROVS) : 1;
  await call('provider:reviews', `/rest/v1/am_reviews?select=id,rating,comment,created_at,reply&provider_id=eq.${pid}&order=created_at.desc&limit=50`);
  await call('provider:stats', '/rest/v1/rpc/am_provider_stats', { method: 'POST', body: { p_id: pid } });
  await call('prices:search', `/rest/v1/am_prices?select=*,provider:am_providers(id,name,city,is_active)&service=ilike.*${enc('масл')}*&order=price&limit=200`);
}
async function client(u) {
  await call('client:profile', '/rest/v1/rpc/am_ensure_profile', { method: 'POST', body: {}, tok: u.tok });
  const mine = await call('client:myRequests', `/rest/v1/am_requests?select=*&user_id=eq.${u.id}&order=id.desc&limit=100`, { tok: u.tok });
  if (u.chat) {
    await call('chat:read', `/rest/v1/am_messages?select=*&request_id=eq.${u.chat}&order=id&limit=500`, { tok: u.tok });
    if (Math.random() < 0.3) await call('chat:send', '/rest/v1/rpc/am_send_message', { method: 'POST', body: { p_id: u.chat, p_body: 'ТЕСТ нагрузка ' + Date.now() }, tok: u.tok, expect: /Слишком много сообщений/ });
  }
  if (Math.random() < 0.05 && (!u.lastCreate || Date.now() - u.lastCreate > 180000)) {   // редкая запись: создать и сразу отменить
    u.lastCreate = Date.now();
    const id = await call('request:create', '/rest/v1/rpc/am_create_request', { method: 'POST', tok: u.tok, expect: /Слишком много/, body: { p: { type: 'tow', city: CITY, description: 'ТЕСТ нагрузка', details: { location: 'ТЕСТ' } } } });
    if (typeof id === 'number') await call('request:cancel', '/rest/v1/rpc/am_cancel_request', { method: 'POST', body: { p_id: id }, tok: u.tok });
  }
}
async function provider(u) { await call('provider:feed', '/rest/v1/rpc/am_provider_feed', { method: 'POST', body: { p_provider: u.pid }, tok: u.tok }); }

async function vu(n) {
  active++;
  const role = n % 10 < 7 ? 'guest' : n % 10 < 9 ? 'client' : 'provider';
  while (n < target()) {
    try { if (role === 'guest') await guest(); else if (role === 'client' && CLIENTS.length) await client(CLIENTS[n % CLIENTS.length]); else if (PROVIDERS.length) await provider(PROVIDERS[n % PROVIDERS.length]); else await guest(); } catch { /* учтено */ }
    await think();
  }
  active--;
}
let tgt = 0; const target = () => tgt;
const pct = (a, p) => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(s.length * p))]; };

(async () => {
  // подготовка: тестовые клиенты (load-пользователи) и исполнители
  const loadUsers = process.env.GUEST_ONLY ? [] : Object.keys(require('../e2e/common.cjs').CREDS).filter((k) => /^test_load_([1-9]|1\d|20)$/.test(k));
  for (const name of loadUsers) { try { const s = await session(name); CLIENTS.push({ name, tok: s.access_token, id: s.user.id }); } catch (e) { console.log('вход', name, e.message); } await sleep(300); }
  for (const name of process.env.GUEST_ONLY ? [] : ['test_sto_1', 'test_sto_2', 'test_tow_1', 'test_wash_1']) {
    try { const s = await session(name); const p = await call('setup', `/rest/v1/am_providers?select=id&owner_id=eq.${s.user.id}`, { tok: s.access_token }); if (p?.[0]) PROVIDERS.push({ name, tok: s.access_token, pid: p[0].id }); } catch (e) { console.log('вход', name, e.message); }
  }
  const pv = await call('setup', `/rest/v1/am_providers?select=id&city=eq.${enc(CITY)}`, { tok: CLIENTS[0]?.tok }); delete stats.setup; PROVS = (pv || []).map((x) => x.id);
  // профили/согласия/телефоны и по одному чату у части клиентов (заявка эвакуатору, тестовый эвакуатор принимает)
  const towP = PROVIDERS.find((p) => p.name === 'test_tow_1');
  for (const [i, u] of CLIENTS.entries()) {
    await call('setup', '/rest/v1/rpc/am_accept_legal', { method: 'POST', tok: u.tok, body: { p_kinds: ['pd', 'cross_border', 'terms', 'age18'], p_version: '2026-10-26', p_ua: 'load' } });
    await call('setup', '/rest/v1/rpc/am_update_profile', { method: 'POST', tok: u.tok, body: { p_full_name: null, p_phone: `+7 700 100 00 ${String(i + 1).padStart(2, '0')}`, p_city: CITY, p_consent: true } });
    if (towP && i < 10) {
      const ex = await call('setup', `/rest/v1/am_requests?select=id,status&user_id=eq.${u.id}&status=eq.active&limit=1`, { tok: u.tok });
      if (ex?.[0]) u.chat = ex[0].id;
      else { const id = await call('setup', '/rest/v1/rpc/am_create_request', { method: 'POST', tok: u.tok, body: { p: { type: 'tow', city: CITY, description: 'ТЕСТ нагрузка: чат', details: { location: 'ТЕСТ' } } } });
        if (typeof id === 'number' && await call('setup', '/rest/v1/rpc/am_accept_request', { method: 'POST', tok: towP.tok, body: { p_id: id, p_provider: towP.pid } })) u.chat = id; }
    }
  }
  delete stats.setup;
  console.log(`подготовка: клиентов ${CLIENTS.length}, исполнителей ${PROVIDERS.length}, организаций в каталоге ${PROVS.length}, чатов ${CLIENTS.filter((u) => u.chat).length}`);
  // этапы
  const perStage = [];
  for (const [min, to] of STAGES) {
    const from = tgt, start = Date.now(), dur = min * 60000, snap = JSON.parse(JSON.stringify(Object.fromEntries(Object.entries(stats).map(([k, v]) => [k, v.lat.length]))));
    while (Date.now() - start < dur) {
      const want = Math.round(from + (to - from) * Math.min(1, (Date.now() - start) / Math.max(1, dur * 0.5)));
      while (tgt < want) vu(tgt++); if (tgt > want) tgt = want;
      await sleep(500);
    }
    const lat = [], errs = { n: 0 }; let calls = 0;
    for (const [k, v] of Object.entries(stats)) { const s = v.lat.slice(snap[k] || 0); calls += s.length; lat.push(...s); }
    const errNow = Object.values(stats).reduce((a, v) => a + v.err, 0);
    perStage.push({ stage: `${from}→${to} VU, ${min} мин`, calls, rps: +(calls / (min * 60)).toFixed(1), p50: Math.round(pct(lat, 0.5)), p95: Math.round(pct(lat, 0.95)), p99: Math.round(pct(lat, 0.99)), errors_total: errNow });
    console.log(JSON.stringify(perStage.at(-1)));
  }
  while (active > 0) await sleep(300);
  const rows = Object.entries(stats).map(([k, v]) => ({ endpoint: k, n: v.lat.length, p50: Math.round(pct(v.lat, 0.5)), p95: Math.round(pct(v.lat, 0.95)), p99: Math.round(pct(v.lat, 0.99)), max: Math.round(Math.max(...v.lat)), err: v.err, err_pct: +(100 * v.err / v.lat.length).toFixed(2), codes: v.codes }));
  console.table(rows);
  const all = Object.values(stats).flatMap((v) => v.lat), errs = Object.values(stats).reduce((a, v) => a + v.err, 0);
  const res = { max_vu: MAX, duration_s: Math.round((Date.now() - t0) / 1000), requests: all.length, p50: Math.round(pct(all, 0.5)), p95: Math.round(pct(all, 0.95)), p99: Math.round(pct(all, 0.99)), error_rate_pct: +(100 * errs / all.length).toFixed(2), stages: perStage, endpoints: rows };
  require('fs').writeFileSync(process.env.OUT || '/workspace/am24-load-result.json', JSON.stringify(res, null, 1));
  console.log('ИТОГО', JSON.stringify({ requests: res.requests, p50: res.p50, p95: res.p95, p99: res.p99, error_rate_pct: res.error_rate_pct }));
  process.exit(0);
})();
