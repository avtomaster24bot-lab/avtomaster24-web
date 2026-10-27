// Боевой бэкенд: Supabase (Postgres + RLS). Все изменения статусов — через функции am_* (supabase/01_schema.sql).
import { CONFIG } from './config.js';
import { stems } from './backend-demo.js';

let sb = null, capsCache = null;
async function client() {
  if (sb) return sb;
  const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
  sb = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'am24-auth' } });
  return sb;
}
function human(e) {
  const m = e?.message || String(e);
  if (/JWT|session|not authenticated/i.test(m)) return 'Сессия истекла — войдите снова';
  if (/row-level security|permission denied|42501/i.test(m)) return 'Недостаточно прав для этого действия';
  return m;
}
const must = ({ data, error }) => { if (error) throw new Error(human(error)); return data; };
const rpc = async (fn, args = {}) => must(await (await client()).rpc(fn, args));
const from = async (t) => (await client()).from(t);
// id текущего пользователя из локальной сессии (без лишнего запроса к /auth/v1/user; права всё равно проверяет база)
async function me() { const s = await client(); const { data } = await s.auth.getSession(); return data.session?.user || null; }

export async function supabaseReady() {
  if (CONFIG.FORCE_DEMO || !/^https:\/\//.test(CONFIG.SUPABASE_URL || '') || !CONFIG.SUPABASE_ANON_KEY) return false;
  try {
    const c = JSON.parse(sessionStorage.getItem('am24-ready') || 'null');
    if (c && Date.now() - c.t < 60000) return c.ok;
  } catch { /* ignore */ }
  let ok = false;
  try {
    const ctrl = new AbortController(); const tm = setTimeout(() => ctrl.abort(), 7000);
    const r = await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/am_cities?select=id&limit=1`, { headers: { apikey: CONFIG.SUPABASE_ANON_KEY }, signal: ctrl.signal });
    clearTimeout(tm); ok = r.ok;
  } catch { ok = false; }
  try { sessionStorage.setItem('am24-ready', JSON.stringify({ ok, t: Date.now() })); } catch { /* ignore */ }
  return ok;
}

export const live = {
  mode: 'live',
  async ref() {
    const q = async (t, order = 'id') => must(await (await from(t)).select('*').order(order));
    const [cities, categories, subcategories, price_services, brands, models] = await Promise.all(
      ['am_cities', 'am_categories', 'am_subcategories', 'am_price_services', 'am_brands', 'am_models'].map((t) => q(t)));
    const { SEED } = await import('./seed.js');
    return { cities, categories, subcategories, price_services, brands, models, price_categories: [...new Set(price_services.map((s) => s.category))], maintenance: SEED.maintenance };
  },
  async session() {
    const s = await client(); const { data } = await s.auth.getSession();
    if (!data.session) return null;
    try { return await rpc('am_ensure_profile'); } catch (e) { if (/сесс/i.test(e.message)) { await s.auth.signOut({ scope: 'local' }); return null; } throw e; }
  },
  async loginTelegram(tgUser) {
    const r = await fetch(CONFIG.TELEGRAM_AUTH_URL, { method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: CONFIG.SUPABASE_ANON_KEY, Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}` }, body: JSON.stringify(tgUser) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const map = { invalid_hash: 'Подпись Telegram не прошла проверку', auth_expired: 'Данные входа устарели, попробуйте ещё раз', too_many_requests: 'Слишком много попыток, подождите минуту', banned: 'Аккаунт заблокирован' };
      throw new Error(map[j.error] || `Ошибка входа (${j.error || r.status})`);
    }
    const s = await client();
    const { error } = await s.auth.setSession({ access_token: j.access_token, refresh_token: j.refresh_token });
    if (error) throw new Error(human(error));
  },
  async logout() { const s = await client(); await s.auth.signOut({ scope: 'local' }).catch(() => {}); },
  async updateProfile({ full_name, phone, city, consent }) { return rpc('am_update_profile', { p_full_name: full_name, p_phone: phone, p_city: city, p_consent: !!consent }); },
  async deleteMyData() { return rpc('am_delete_my_data'); },

  async listProviders({ kind, city } = {}) {
    let q = (await from('am_providers')).select('*').eq('is_active', true).order('rating', { ascending: false });
    if (kind) q = q.eq('kind', kind); if (city) q = q.eq('city', city); return must(await q);
  },
  async getProvider(id) { return must(await (await from('am_providers')).select('*').eq('id', id).single()); },
  async providerReviews(id) {
    const q = async (cols) => (await from('am_reviews')).select(cols).eq('provider_id', id).order('created_at', { ascending: false }).limit(50);
    const r = await q('id,rating,comment,is_published,created_at,request_id,provider_id,reply,reply_at');
    return r.error ? must(await q('id,rating,comment,is_published,created_at,request_id,provider_id')) : r.data;
  },
  async myProviders() {
    const u = await me(); if (!u) return [];
    if ((await this.caps()).v8) { const r = await rpc('am_my_orgs'); return (r || []).map((x) => ({ ...x.org, my_role: x.my_role })); }
    return must(await (await from('am_providers')).select('*').eq('owner_id', u.id).order('id')).map((x) => ({ ...x, my_role: 'owner' }));
  },
  async updateProvider(id, patch) { return must(await (await from('am_providers')).update(patch).eq('id', id).select().single()); },

  async createRequest(p) { return rpc('am_create_request', { p }); },
  async myRequests() {
    const s = await client(); const u = await me(); if (!u) return [];
    return must(await (await from('am_requests')).select('*').eq('user_id', u.id).order('id', { ascending: false }).limit(100));
  },
  async cancelRequest(id) { return rpc('am_cancel_request', { p_id: id }); },
  async requestOffers(id) { return rpc('am_request_offers', { p_id: id }); },
  async selectOffer(oid) { return rpc('am_select_offer', { p_offer: oid }); },
  async washApprove(id) { return rpc('am_wash_approve', { p_id: id }); },
  async clientConfirm(id) { return rpc('am_client_confirm', { p_id: id }); },
  async leaveReview(id, rating, comment) { return rpc('am_leave_review', { p_id: id, p_rating: +rating, p_comment: comment || '' }); },
  async myReviewFor(id) { return must(await (await from('am_reviews')).select('*').eq('request_id', id).maybeSingle()); },

  async providerFeed(pid) { return rpc('am_provider_feed', { p_provider: +pid }); },
  async myOffers(pid) { return must(await (await from('am_offers')).select('*').eq('provider_id', pid)); },
  async accept(id, pid) { return rpc('am_accept_request', { p_id: id, p_provider: +pid }); },
  async decline(id, pid) { return rpc('am_decline_request', { p_id: id, p_provider: +pid }); },
  async complete(id, pid, amount) { return rpc('am_complete_request', { p_id: id, p_provider: +pid, p_amount: amount ? +amount : null }); },
  async makeOffer(id, pid, price, comment) { return rpc('am_make_offer', { p_id: id, p_provider: +pid, p_price: +price, p_comment: comment || '' }); },
  async washQuote(id, pid, price, time) { return rpc('am_wash_quote', { p_id: id, p_provider: +pid, p_price: +price, p_time: new Date(time).toISOString() }); },
  async washStatus(id, pid, st) { return rpc('am_wash_status', { p_id: id, p_provider: +pid, p_status: st }); },
  async clientContact(id) { const r = await rpc('am_client_contact', { p_id: id }); return r?.[0] || null; },

  async vehicles() { return must(await (await from('am_vehicles')).select('*').order('id')); },
  async addVehicle(v) { if (!v.brand) throw new Error('Укажите марку'); return must(await (await from('am_vehicles')).insert(v)); },
  async deleteVehicle(id) { return must(await (await from('am_vehicles')).delete().eq('id', id)); },

  async searchPrices({ service, brand }) {
    let q = (await from('am_prices')).select('*, provider:am_providers(id,name,city,address,phone,rating,is_active)').order('price').limit(200);
    for (const w of stems(service)) q = q.ilike('service', `%${w}%`);
    if (brand) q = q.or(`brand.eq.,brand.is.null,brand.ilike.${brand}`);
    return (must(await q) || []).filter((p) => !p.provider_id || p.provider?.is_active);   // цена скрытой организации не показывается
  },
  async providerPrices(pid) { return must(await (await from('am_prices')).select('*').eq('provider_id', pid).order('service')); },
  async addPrice(x) { return must(await (await from('am_prices')).insert({ ...x, price: +x.price })); },
  async deletePrice(id) { return must(await (await from('am_prices')).delete().eq('id', id)); },

  async registerBusiness(p) { return rpc('am_register_business', { p }); },
  async myRegistrations() {
    const s = await client(); const u = await me(); if (!u) return [];
    return must(await (await from('am_registrations')).select('*').eq('user_id', u.id).order('id', { ascending: false }));
  },
  async adminRegistrations() { return must(await (await from('am_registrations')).select('*').order('id', { ascending: false }).limit(200)); },
  async reviewRegistration(id, approve, reason) { return rpc('am_review_registration', { p_id: id, p_approve: !!approve, p_reason: reason || null }); },
  async adminRequests() { return rpc('am_admin_requests'); },
  async adminStats() { return rpc('am_admin_stats'); },
  async pendingReviews() {
    let q = (await from('am_reviews')).select('*, p:am_providers(name)').eq('is_published', false);
    if ((await this.caps()).v10) q = q.is('hidden_at', null);
    return must(await q.order('id')).map((x) => ({ ...x, provider_name: x.p?.name }));
  },
  async hiddenReviews() { return must(await (await from('am_reviews')).select('*, p:am_providers(name)').not('hidden_at', 'is', null).order('hidden_at', { ascending: false }).limit(100)).map((x) => ({ ...x, provider_name: x.p?.name })); },
  async getReview(id) { const r = must(await (await from('am_reviews')).select('*, p:am_providers(name)').eq('id', +id).maybeSingle()); return r ? { ...r, provider_name: r.p?.name } : null; },
  async reviewDecide(id, action, rule = null, reason = '') { return rpc('am_review_decide', { p_id: +id, p_action: action, p_rule: rule, p_reason: reason || null }); },
  async deleteMyReview(id) { return rpc('am_delete_my_review', { p_id: +id }); },
  async editMyReview(id, rating, comment) { return rpc('am_edit_my_review', { p_id: +id, p_rating: +rating, p_comment: comment || '' }); },
  async moderateReview(id, publish) { return rpc('am_moderate_review', { p_id: id, p_publish: !!publish }); },
  async adminProviders() { return must(await (await from('am_providers')).select('*').order('id')); },
  async setProviderActive(id, active) { return must(await (await from('am_providers')).update({ is_active: !!active }).eq('id', id)); },
  async setCityActive(id, active) { return must(await (await from('am_cities')).update({ active: !!active }).eq('id', id)); },
  async setProviderVerified(id, v) { return must(await (await from('am_providers')).update({ verified: !!v }).eq('id', id)); },

  // ---- обновление 3 (supabase/03_features.sql): фото, чат, статистика, ответы на отзывы
  async caps() {
    if (capsCache) return capsCache;
    // обновление 3 — функция am_provider_stats (доступна и гостю, без ошибки 401 в консоли); обновление 4 — таблица am_complaints
    const [r, r4] = await Promise.all([(await client()).rpc('am_provider_stats', { p_id: 0 }), (await from('am_complaints')).select('id').limit(1)]);
    const missing = (x) => !!(x.error && /does not exist|42P01|PGRST20[25]|schema cache|Could not find/i.test(x.error.message + x.error.code));
    const [r8, r10] = await Promise.all([(await from('am_settings')).select('key').limit(1), (await client()).rpc('am_review_rule_name', { p_rule: 'hold' })]);
    capsCache = { v3: !missing(r), v4: !missing(r4), v8: !missing(r8), v10: !missing(r10) };
    return capsCache;
  },
  async uploadRequestPhoto(blob) {
    const s = await client(); const u = await me(); if (!u) throw new Error('Войдите');
    const path = `req/${u.id}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`;
    must(await s.storage.from('am-photos').upload(path, blob, { contentType: 'image/jpeg', upsert: false }));
    return path;
  },
  async photoUrls(paths) {
    const list = (paths || []).filter((x) => !/^(assets|https?:|data:)/.test(x));
    let signed = [];
    if (list.length) { const r = await (await client()).storage.from('am-photos').createSignedUrls(list, 3600); signed = r.data || []; }
    return (paths || []).map((x) => /^(assets|https?:|data:)/.test(x) ? x : (signed.find((y) => y.path === x)?.signedUrl || ''));
  },
  async uploadProviderPhoto(pid, blob) {
    const s = await client(); const path = `prov/${+pid}/${Date.now()}-${Math.random().toString(36).slice(2, 6)}.jpg`;
    must(await s.storage.from('am-public').upload(path, blob, { contentType: 'image/jpeg', upsert: false }));
    return s.storage.from('am-public').getPublicUrl(path).data.publicUrl;
  },
  async providerStats(id) { try { return await rpc('am_provider_stats', { p_id: +id }); } catch { return {}; } },
  async pricesFrom(ids) {
    if (!ids.length) return {};
    const r = must(await (await from('am_prices')).select('provider_id,price').in('provider_id', ids).limit(2000));
    const out = {}; for (const x of r) out[x.provider_id] = Math.min(out[x.provider_id] ?? Infinity, x.price); return out;
  },
  async getRequest(id) { const r = must(await (await from('am_requests')).select('*').eq('id', id).maybeSingle()); if (!r) throw new Error('Заявка не найдена'); return r; },
  async messages(id) { return must(await (await from('am_messages')).select('*').eq('request_id', id).order('id').limit(500)); },
  async sendMessage(id, body) { return rpc('am_send_message', { p_id: +id, p_body: body }); },
  subscribeMessages(id, cb) {
    let ch = null, off = false;
    client().then((s) => { if (off) return; ch = s.channel('am-msg-' + id).on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'am_messages', filter: `request_id=eq.${+id}` }, (e) => cb(e.new)).subscribe(); });
    return () => { off = true; if (ch) sb.removeChannel(ch); };
  },
  // все новые сообщения, которые пользователю разрешено видеть (RLS фильтрует на сервере) — для уведомлений
  subscribeInbox(cb) {
    let ch = null, off = false;
    client().then((s) => { if (off) return; ch = s.channel('am-inbox').on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'am_messages' }, (e) => cb(e.new)).subscribe(); });
    return () => { off = true; if (ch) sb.removeChannel(ch); };
  },
  async replyReview(id, text) { return rpc('am_reply_review', { p_id: +id, p_text: text || '' }); },

  // ---- обновление 6 (supabase/08_admin.sql): админы и права, пользователи, настройки, журнал, сотрудники
  async adminList() { return rpc('am_admin_list'); },
  async adminUsers(q = '') { return rpc('am_admin_users', { p_q: q || '', p_limit: 100 }); },
  async setRole(userId, role, city = null) { return rpc('am_admin_set_role', { p_user: userId, p_role: role, p_city: city || null }); },
  async blockUser(userId, block, reason = '') { return rpc('am_admin_block', { p_user: userId, p_block: !!block, p_reason: reason || '' }); },
  async adminLog() {
    const r = must(await (await from('am_admin_log')).select('*, actor:am_profiles!am_admin_log_actor_id_fkey(username,full_name), target:am_profiles!am_admin_log_target_user_fkey(username,full_name)').order('id', { ascending: false }).limit(100));
    return r;
  },
  async settings(city = '') { return must(await (await from('am_settings')).select('*').in('city', ['', city || ''])); },
  async setSetting(key, city, value) { return rpc('am_set_setting', { p_key: key, p_city: city || '', p_value: value }); },
  async cityNotice(city) { try { const v = await rpc('am_setting', { p_key: 'city_notice', p_city: city || '' }); return typeof v === 'string' ? v : ''; } catch { return ''; } },
  async staffList(pid) { return rpc('am_staff_list', { p_provider: +pid }); },
  async staffAdd(pid, username, role) { return rpc('am_staff_add', { p_provider: +pid, p_username: username, p_role: role }); },
  async staffRemove(pid, userId) { return rpc('am_staff_remove', { p_provider: +pid, p_user: userId }); },
  async assign(rid, userId) { return rpc('am_assign_request', { p_id: +rid, p_user: userId || null }); },

  // ---- обновление 4 (supabase/04_legal.sql): согласия, обращения, права субъекта ПД, прозрачность
  async acceptLegal(kinds, version) { return rpc('am_accept_legal', { p_kinds: kinds, p_version: version, p_ua: navigator.userAgent.slice(0, 300) }); },
  async withdrawConsent() { return rpc('am_withdraw_consent', { p_ua: navigator.userAgent.slice(0, 300) }); },
  async exportMyData() { return rpc('am_export_my_data'); },
  async deleteAccount() { await rpc('am_delete_my_account', { p_ua: navigator.userAgent.slice(0, 300) }); const s = await client(); await s.auth.signOut({ scope: 'local' }).catch(() => {}); },
  async submitComplaint({ type, target = '', reason = '', body = '', contact = '', lang = 'ru' }) {
    return rpc('am_submit_complaint', { p_type: type, p_target: String(target), p_reason: reason, p_body: body, p_contact: contact, p_lang: lang });
  },
  async myComplaints(userId) { return must(await (await from('am_complaints')).select('*').eq('user_id', userId).order('id', { ascending: false }).limit(50)); },
  async adminComplaints() { return must(await (await from('am_complaints')).select('*').order('id', { ascending: false }).limit(200)); },
  async answerComplaint(id, status, answer) { return rpc('am_answer_complaint', { p_id: +id, p_status: status, p_answer: answer || '' }); },
  async hit() { try { await rpc('am_hit'); } catch { /* миграция 04 ещё не применена */ } },
  async transparency() { return rpc('am_transparency'); },

  async addCity(name) { return must(await (await from('am_cities')).insert({ name })); },
};
