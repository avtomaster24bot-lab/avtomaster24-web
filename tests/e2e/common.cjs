// Общие помощники для боевых автотестов. Пароли/ключи НЕ в репозитории:
// AM24_CREDS — путь к JSON {users:{test_client_1:{email,password}, ...}} (по умолчанию /workspace/am24-private/test-creds.json)
const fs = require('fs'); const path = require('path');
const { createClient } = require('@supabase/supabase-js');
let WS; try { WS = globalThis.WebSocket || require('ws'); } catch { WS = undefined; }
const RT = WS ? { realtime: { transport: WS } } : {};
const cfg = fs.readFileSync(path.join(__dirname, '../../site/js/config.js'), 'utf8');
const URL_ = cfg.match(/SUPABASE_URL:\s*'([^']+)'/)[1];
const ANON = cfg.match(/SUPABASE_ANON_KEY:\s*'([^']+)'/)[1];
const CREDS = JSON.parse(fs.readFileSync(process.env.AM24_CREDS || '/workspace/am24-private/test-creds.json', 'utf8')).users;
const mk = () => createClient(URL_, ANON, { ...RT, auth: { persistSession: false, autoRefreshToken: false } });
// Сессии кэшируются в файле рядом с паролями (лимит Supabase на входы ~30 за 5 минут с одного IP)
const SESS_FILE = (process.env.AM24_CREDS || '/workspace/am24-private/test-creds.json').replace(/[^/]+$/, 'sessions.json');
const sessCache = () => { try { return JSON.parse(fs.readFileSync(SESS_FILE, 'utf8')); } catch { return {}; } };
async function session(name) {
  const c = CREDS[name]; if (!c) throw new Error('нет тестового пользователя ' + name);
  const cache = sessCache(); const x = cache[name];
  if (x && x.expires_at * 1000 > Date.now() + 10 * 60000) return x;
  const r = await fetch(`${URL_}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email: c.email, password: c.password }) });
  const j = await r.json(); if (!r.ok) throw new Error(name + ': ' + (j.error_description || j.msg || j.message || r.status));
  const fresh = sessCache(); fresh[name] = j; fs.writeFileSync(SESS_FILE, JSON.stringify(fresh), { mode: 0o600 }); return j;
}
async function login(name) {
  const sess = await session(name);
  const s = createClient(URL_, ANON, { ...RT, auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${sess.access_token}` } } });
  s.realtime.setAuth(sess.access_token);
  s.uid = sess.user.id; s.session = sess; s.name = name; return s;
}
const must = (r) => { if (r.error) throw new Error(r.error.message); return r.data; };
const rpc = async (s, fn, args = {}) => must(await s.rpc(fn, args));
let passed = 0, failed = 0; const fails = [];
async function ok(name, fn) {
  const t = Date.now();
  try { const v = await fn(); passed++; console.log('OK  ', name, `(${Date.now() - t} мс)`); return v; }
  catch (e) { failed++; fails.push(name + ': ' + e.message); console.log('FAIL', name, '—', e.message.slice(0, 400)); }
}
async function denied(name, fn, re = /./) {
  return ok(name, async () => {
    let r; try { r = await fn(); } catch (e) { if (!re.test(e.message)) throw new Error('не та ошибка: ' + e.message); return; }
    if (r && r.error) { if (!re.test(r.error.message)) throw new Error('не та ошибка: ' + r.error.message); return; }
    if (Array.isArray(r?.data) && r.data.length === 0) return;          // RLS: пусто
    if (r && 'data' in r && r.data === null) return;
    throw new Error('ожидался отказ, а получилось: ' + JSON.stringify(r?.data ?? r).slice(0, 200));
  });
}
const summary = () => { console.log(`\nИТОГО: ${passed} OK, ${failed} FAIL`); fails.forEach((f) => console.log(' -', f)); return failed; };
const assert = (c, m) => { if (!c) throw new Error(m); };
module.exports = { URL_, ANON, CREDS, mk, login, session, must, rpc, ok, denied, summary, assert };
