// ДЕМО-бэкенд: та же логика, что в функциях Supabase (supabase/01_schema.sql), но данные хранятся
// только в этом браузере (localStorage). Все люди и организации здесь — вымышленные.
import { SEED } from './seed.js';

const KEY = 'am24-demo-db-v2', UKEY = 'am24-demo-user', PKEY = 'am24-demo-photos';
const now = () => new Date().toISOString();
const plus = (min) => new Date(Date.now() + min * 60000).toISOString();
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const C = 'Талдыкорган';

function initial() {
  const P = (id, kind, name, extra = {}) => ({ id, kind, owner_id: null, name, city: C, address: '', phone: '+7 700 000 00 ' + String(id).padStart(2, '0'),
    working_hours: '09:00-19:00', specs: [], supplier_type: null, service_type: null, boxes: 1, slot_minutes: 60, delivery: false,
    rating: 0, reviews_count: 0, is_active: true, created_at: ago(9000), about: '', photos: [], whatsapp: '', verified: false, ...extra });
  const providers = [
    P(1, 'sto', 'Демо-СТО «Мотор»', { owner_id: 'u-master', address: 'ул. Примерная, 1', specs: [1, 2, 7, 8, 9], rating: 4.8, reviews_count: 12, verified: true, whatsapp: '+77000000001',
      about: 'Ремонт двигателя, ходовой и компьютерная диагностика. 4 подъёмника, гарантия на работы 6 месяцев. Можно подождать в зоне отдыха с Wi‑Fi.', photos: ['assets/img/sto.webp', 'assets/img/master.webp'] }),
    P(2, 'sto', 'Демо-СТО «Ходовая+»', { address: 'ул. Примерная, 15', specs: [2, 5, 11], rating: 4.5, reviews_count: 7, about: 'Подвеска, рулевое, развал-схождение 3D.' }),
    P(3, 'sto', 'Демо-СТО «Автоэлектрик»', { address: 'пр. Демо, 8', specs: [3, 15], rating: 4.2, reviews_count: 3 }),
    P(4, 'tow', 'Демо-эвакуатор «Быстрый»', { owner_id: 'u-master', rating: 4.9, reviews_count: 20, working_hours: 'Круглосуточно', verified: true, whatsapp: '+77000000004', about: 'Ломаная платформа, город и межгород. Подача 20–40 минут.', photos: ['assets/img/tow.webp'] }),
    P(5, 'tow', 'Демо-эвакуатор «Сокол»', { rating: 4.4, reviews_count: 5, working_hours: 'Круглосуточно' }),
    P(6, 'wash', 'Демо-мойка «Блеск»', { owner_id: 'u-master', address: 'ул. Чистая, 3', boxes: 3, slot_minutes: 30, working_hours: '08:00-22:00', rating: 4.7, reviews_count: 15, verified: true, photos: ['assets/img/wash.webp'], about: 'Три бокса, бесконтактная и ручная мойка, химчистка.' }),
    P(7, 'wash', 'Демо-мойка «Аква»', { address: 'ул. Водная, 9', boxes: 2, working_hours: '09:00-21:00', rating: 4.3, reviews_count: 4 }),
    P(8, 'parts', 'Демо-магазин «Запчасть»', { owner_id: 'u-master', supplier_type: 'shop', delivery: true, rating: 4.6, reviews_count: 9, photos: ['assets/img/parts.webp'] }),
    P(9, 'parts', 'Демо-авторазбор «Японец»', { supplier_type: 'razborka', rating: 4.1, reviews_count: 6 }),
    P(10, 'urgent', 'Демо-мастер «Замки 24»', { owner_id: 'u-master', service_type: 'locksmith', working_hours: 'Круглосуточно', rating: 5, reviews_count: 8, photos: ['assets/img/help.webp'] }),
    P(11, 'urgent', 'Демо-шиномонтаж на выезде', { service_type: 'tire', rating: 4.5, reviews_count: 4 }),
    P(12, 'urgent', 'Демо-электрик на выезде', { service_type: 'electrician', rating: 4.0, reviews_count: 2 }),
    P(13, 'sto', 'Демо-СТО «Алматы Сервис»', { city: 'Алматы', specs: [], rating: 4.6, reviews_count: 30 }),
  ];
  const profiles = {
    'u-client': { id: 'u-client', username: 'demo_client', full_name: 'Демо Клиент', phone: '+77001112233', city: C, role: 'client', consent: true },
    'u-master': { id: 'u-master', username: 'demo_master', full_name: 'Демо Мастер', phone: '+77002223344', city: C, role: 'client', consent: true },
    'u-admin': { id: 'u-admin', username: 'demo_admin', full_name: 'Демо Админ', phone: '+77003334455', city: C, role: 'global_admin', consent: true },
    'u-other': { id: 'u-other', username: null, full_name: 'Другой клиент (демо)', phone: '+77009990000', city: C, role: 'client', consent: true },
  };
  const R = (id, type, extra) => ({ id, type, user_id: 'u-other', city: C, status: 'new', category_id: null, subcategory: null, service_type: null,
    supplier_type: null, target_provider_id: null, description: '', vehicle_info: '', details: {}, desired_time: null, assigned_time: null,
    price: null, accepted_by: null, accepted_offer_id: null, final_amount: null, expires_at: plus(55), created_at: ago(5), updated_at: ago(5), ...extra });
  const requests = [
    R(1, 'sto', { category_id: 2, subcategory: 'Замена амортизаторов', description: 'Стук спереди справа на кочках', vehicle_info: 'Toyota Camry 2014' }),
    R(2, 'tow', { description: 'Не заводится, нужно отвезти на СТО', vehicle_info: 'Hyundai Solaris', details: { vehicle: 'Легковой автомобиль', wheels: 'Колёса крутятся', location: 'ул. Демо, 10 (у ТЦ)' } }),
    R(3, 'parts', { supplier_type: 'shop', description: 'Фара передняя левая', vehicle_info: 'Kia Rio 2017', expires_at: plus(170), details: { urgency: 'В течение недели', original: 'Неважно', delivery: 'Заберу сам' } }),
    R(4, 'wash', { target_provider_id: 6, service_type: 'Комплексная мойка', details: { car_type: 'Внедорожник' }, desired_time: plus(180), expires_at: null }),
    R(5, 'sto', { user_id: 'u-client', category_id: 7, subcategory: 'Компьютерная диагностика', description: 'Горит Check Engine', vehicle_info: 'Toyota Corolla 2012',
      status: 'completed', accepted_by: 2, accepted_at: ago(3992), final_amount: 5000, created_at: ago(4000), updated_at: ago(3900), expires_at: ago(3940) }),
  ];
  const reviews = [
    { id: 1, user_id: 'u-other', provider_id: 1, request_id: null, rating: 5, comment: 'Быстро нашли причину стука, цена как договаривались.', is_published: true, created_at: ago(20000), reply: 'Спасибо! Ждём на плановое ТО.', reply_at: ago(19000) },
    { id: 2, user_id: 'u-other', provider_id: 4, request_id: null, rating: 5, comment: 'Приехал за 25 минут.', is_published: true, created_at: ago(15000) },
    { id: 3, user_id: 'u-other', provider_id: 2, request_id: null, rating: 4, comment: 'Хорошо, но пришлось подождать.', is_published: false, created_at: ago(100) },
  ];
  let pid = 1;
  const prices = SEED.ref_prices.map((p) => ({ id: pid++, provider_id: null, service: p.service, brand: p.brand, model: p.model, price: p.price, notes: 'Справочная цена', year_from: null, year_to: null }));
  for (const [svc, pr] of [['Замена масла', 4000], ['Компьютерная диагностика', 5000], ['Замена передних колодок', 4500], ['Развал-схождение', 7000], ['Замена ремня ГРМ', 25000]]) {
    prices.push({ id: pid++, provider_id: 1, service: svc, brand: '', model: '', price: pr, notes: '', year_from: null, year_to: null });
    prices.push({ id: pid++, provider_id: 2, service: svc, brand: '', model: '', price: Math.round(pr * 1.15 / 100) * 100, notes: '', year_from: null, year_to: null });
  }
  return { seq: 100, profiles, providers, requests, reviews, prices, offers: [], declines: [], messages: [], vehicles: [
    { id: 1, user_id: 'u-client', brand: 'Toyota', model: 'Corolla', year: 2012, plate: '123ABC05', engine_volume: '1.6' }],
    registrations: [{ id: 1, user_id: 'u-other', kind: 'sto', name: 'Демо-заявка: СТО «Новое»', phone: '+77005550000', address: 'ул. Новая, 1', city: C, details: { specs: [1, 2] }, status: 'pending', created_at: ago(60) }],
    cities: SEED.cities.map((c) => ({ ...c })) };
}

let db = null;
const load = () => { if (!db) { try { db = JSON.parse(localStorage.getItem(KEY)); } catch { db = null; } if (!db) { db = initial(); save(); } } return db; };
const save = () => localStorage.setItem(KEY, JSON.stringify(db));
const id = () => ++load().seq;
const uid = () => localStorage.getItem(UKEY);
const me = () => load().profiles[uid()] || null;
const fail = (m) => { throw new Error(m); };
const isAdmin = (city) => { const m = me(); return !!m && (m.role === 'global_admin' || (m.role === 'regional_admin' && (!city || m.managed_city === city))); };
const prov = (pid) => load().providers.find((p) => p.id === +pid);
const myProv = (pid) => { const p = prov(pid); if (!p || p.owner_id !== uid()) fail('Это не ваша организация'); if (!p.is_active) fail('Организация отключена администратором'); return p; };
const req = (rid) => load().requests.find((r) => r.id === +rid) || fail('Заявка не найдена');
const myReq = (rid) => { const r = req(rid); if (r.user_id !== uid()) fail('Заявка не найдена'); return r; };
const live = (r) => ['new', 'offers'].includes(r.status) && (!r.expires_at || new Date(r.expires_at) > new Date());
function matches(r, p) {
  return p.is_active && p.kind === r.type && p.city === r.city && (!r.target_provider_id || r.target_provider_id === p.id)
    && (r.type !== 'urgent' || !r.service_type || r.service_type === p.service_type)
    && (r.type !== 'parts' || !r.supplier_type || r.supplier_type === p.supplier_type)
    && (r.type !== 'sto' || !r.category_id || !p.specs.length || p.specs.includes(r.category_id) || r.target_provider_id === p.id);
}
const touch = (r, patch) => { const was = r.accepted_by; Object.assign(r, patch, { updated_at: now() }); if (!was && r.accepted_by && !r.accepted_at) r.accepted_at = now(); save(); };
const recalc = (pid) => { const rs = load().reviews.filter((x) => x.provider_id === pid); const p = prov(pid);
  p.reviews_count = rs.length; p.rating = rs.length ? Math.round(rs.reduce((s, x) => s + x.rating, 0) / rs.length * 100) / 100 : 0; };
export const stems = (q) => (q || '').toLowerCase().split(/[^a-zа-яё0-9]+/i).filter((w) => w.length > 1).map((w) => w.length > 4 ? w.slice(0, Math.max(4, w.length - 2)) : w);
const clone = (x) => JSON.parse(JSON.stringify(x));

export const demo = {
  mode: 'demo',
  async ref() { return { ...SEED, cities: load().cities }; },
  async session() { return me() ? clone(me()) : null; },
  async loginDemo(role) { localStorage.setItem(UKEY, { client: 'u-client', master: 'u-master', admin: 'u-admin' }[role]); },
  async logout() { localStorage.removeItem(UKEY); },
  async resetDemo() { localStorage.removeItem(KEY); localStorage.removeItem(PKEY); db = null; load(); },
  async updateProfile({ full_name, phone, city, consent }) {
    const m = me() || fail('Войдите');
    const digits = (phone || '').replace(/\D/g, '');
    if (phone && !/^[78]\d{10}$/.test(digits)) fail('Телефон в формате +7 7XX XXX XX XX');
    Object.assign(m, { full_name: full_name || m.full_name, phone: phone ? '+7' + digits.slice(1) : null, city, consent: !!consent }); save(); return clone(m);
  },
  async deleteMyData() { const m = me(); m.phone = null; m.consent = false; save(); },

  async listProviders({ kind, city } = {}) {
    return clone(load().providers.filter((p) => p.is_active && (!kind || p.kind === kind) && (!city || p.city === city)).sort((a, b) => b.rating - a.rating));
  },
  async getProvider(pid) { return clone(prov(pid) || fail('Не найдено')); },
  async providerReviews(pid) { return clone(load().reviews.filter((x) => x.provider_id === +pid && (x.is_published || x.user_id === uid()))); },
  async myProviders() { return clone(load().providers.filter((p) => p.owner_id === uid())); },
  async updateProvider(pid, patch) {
    const p = prov(pid); if (!p || (p.owner_id !== uid() && !isAdmin(p.city))) fail('Нет прав');
    const allowed = ['name', 'address', 'phone', 'working_hours', 'specs', 'boxes', 'slot_minutes', 'delivery', 'supplier_type', 'service_type', 'about', 'photos', 'whatsapp'];
    for (const k of Object.keys(patch)) if (allowed.includes(k) || isAdmin(p.city)) p[k] = patch[k];
    save(); return clone(p);
  },

  async createRequest(p) {
    const m = me() || fail('Войдите');
    if (!m.consent) fail('Нужно согласие на обработку персональных данных (Профиль)');
    if (!m.phone) fail('Укажите телефон в профиле — без него исполнитель не сможет связаться');
    const ttl = p.type === 'parts' ? 180 : p.type === 'wash' ? null : 60;
    const r = { id: id(), type: p.type, user_id: m.id, city: p.city || m.city, status: 'new', category_id: p.category_id ? +p.category_id : null,
      subcategory: p.subcategory || null, service_type: p.service_type || null, supplier_type: p.supplier_type || null,
      target_provider_id: p.target_provider_id ? +p.target_provider_id : null, description: p.description || '', vehicle_info: p.vehicle_info || '',
      details: p.details || {}, desired_time: p.desired_time || null, assigned_time: null, price: null, accepted_by: null, accepted_offer_id: null,
      final_amount: null, expires_at: ttl ? plus(ttl) : null, created_at: now(), updated_at: now() };
    load().requests.push(r); save();
    // в демо через 4 секунды «откликается» исполнитель, чтобы было видно весь путь
    setTimeout(() => demoAutoReply(r.id), 4000);
    return r.id;
  },
  async myRequests() { return clone(load().requests.filter((r) => r.user_id === uid()).sort((a, b) => b.id - a.id)); },
  async cancelRequest(rid) { const r = myReq(rid); if (['completed', 'cancelled'].includes(r.status)) fail('Заявку уже нельзя отменить'); touch(r, { status: 'cancelled' }); },
  async requestOffers(rid) {
    const r = myReq(rid);
    return load().offers.filter((o) => o.request_id === r.id).sort((a, b) => a.price - b.price).map((o) => { const p = prov(o.provider_id);
      return { id: o.id, price: o.price, comment: o.comment, is_selected: o.is_selected, created_at: o.created_at, provider_id: o.is_selected ? p.id : null,
        provider_name: o.is_selected ? p.name : 'Поставщик №' + p.id, provider_phone: o.is_selected ? p.phone : null,
        provider_address: o.is_selected ? p.address : null, provider_rating: p.rating, delivery: p.delivery }; });
  },
  async selectOffer(oid) {
    const o = load().offers.find((x) => x.id === +oid) || fail('Предложение не найдено'); const r = myReq(o.request_id);
    if (!['new', 'offers'].includes(r.status)) fail('Предложение уже выбрано');
    load().offers.filter((x) => x.request_id === r.id).forEach((x) => { x.is_selected = x.id === o.id; });
    touch(r, { status: 'active', accepted_by: o.provider_id, accepted_offer_id: o.id, final_amount: o.price });
    setTimeout(() => { const rr = req(r.id); if (rr.status === 'active' && prov(rr.accepted_by)?.owner_id !== 'u-master') touch(rr, { status: 'delivered' }); }, 6000);
  },
  async washApprove(rid) { const r = myReq(rid); if (r.status !== 'price_offered') fail('Мойка ещё не предложила цену и время'); touch(r, { status: 'client_approved', final_amount: r.price }); },
  async clientConfirm(rid) { const r = myReq(rid); if (!['active', 'delivered', 'waiting_client', 'in_progress'].includes(r.status)) fail('Нельзя завершить заявку в этом статусе'); touch(r, { status: 'completed' }); },
  async leaveReview(rid, rating, comment) {
    const r = myReq(rid); if (r.status !== 'completed' || !r.accepted_by) fail('Оценить можно только выполненную заявку');
    if (load().reviews.some((x) => x.request_id === r.id)) fail('Вы уже оценили эту заявку');
    load().reviews.push({ id: id(), user_id: uid(), provider_id: r.accepted_by, request_id: r.id, rating: +rating, comment: comment || '', is_published: !(comment || '').trim(), created_at: now() });
    recalc(r.accepted_by); save();
  },
  async myReviewFor(rid) { return clone(load().reviews.find((x) => x.request_id === +rid) || null); },

  async providerFeed(pid) {
    const p = myProv(pid); const dec = load().declines.filter((d) => d.provider_id === p.id).map((d) => d.request_id);
    return clone(load().requests.filter((r) => r.accepted_by === p.id || r.target_provider_id === p.id || (live(r) && matches(r, p) && !dec.includes(r.id))).sort((a, b) => b.id - a.id));
  },
  async myOffers(pid) { myProv(pid); return clone(load().offers.filter((o) => o.provider_id === +pid)); },
  async accept(rid, pid) {
    const p = myProv(pid); const r = req(rid);
    if (!matches(r, p)) fail('Заявка недоступна'); if (['parts', 'wash'].includes(r.type)) fail('Для этой заявки отправьте предложение');
    if (r.status !== 'new') fail('Заявку уже принял другой исполнитель'); if (!live(r)) fail('Срок заявки истёк');
    touch(r, { status: 'active', accepted_by: p.id });
  },
  async decline(rid, pid) { const p = myProv(pid); load().declines.push({ request_id: +rid, provider_id: p.id }); save(); },
  async complete(rid, pid, amount) {
    const p = myProv(pid); const r = req(rid); if (r.accepted_by !== p.id) fail('Заявка не ваша');
    if (r.type === 'parts') { if (r.status !== 'active') fail('Неверный статус'); touch(r, { status: 'delivered' }); }
    else { if (!['active', 'in_progress', 'waiting_client', 'client_approved'].includes(r.status)) fail('Неверный статус'); touch(r, { status: 'completed', final_amount: amount ? +amount : r.final_amount }); }
  },
  async makeOffer(rid, pid, price, comment) {
    const p = myProv(pid); const r = req(rid);
    if (r.type !== 'parts' || !matches(r, p)) fail('Заявка недоступна'); if (!live(r)) fail('Заявка уже закрыта'); if (!(+price > 0)) fail('Укажите цену');
    const ex = load().offers.find((o) => o.request_id === r.id && o.provider_id === p.id);
    if (ex) Object.assign(ex, { price: +price, comment: comment || '' }); else load().offers.push({ id: id(), request_id: r.id, provider_id: p.id, price: +price, comment: comment || '', is_selected: false, created_at: now() });
    if (r.status === 'new') r.status = 'offers'; touch(r, {});
  },
  async washQuote(rid, pid, price, time) {
    const p = myProv(pid); const r = req(rid);
    if (r.type !== 'wash' || !(matches(r, p) || r.accepted_by === p.id)) fail('Заявка недоступна');
    if (!['new', 'price_offered'].includes(r.status)) fail('Запись уже подтверждена');
    if (!(+price > 0) || !time) fail('Укажите цену и время');
    touch(r, { status: 'price_offered', accepted_by: p.id, price: +price, assigned_time: new Date(time).toISOString() });
  },
  async washStatus(rid, pid, st) {
    const p = myProv(pid); const r = req(rid); if (r.accepted_by !== p.id) fail('Заявка не ваша');
    const ok = (r.status === 'client_approved' && st === 'in_progress') || (r.status === 'in_progress' && st === 'waiting_client') || (['waiting_client', 'in_progress'].includes(r.status) && st === 'completed');
    if (!ok) fail('Неверный переход статуса'); touch(r, { status: st });
  },
  async clientContact(rid) {
    const r = req(rid); const p = prov(r.accepted_by);
    if (!((p && p.owner_id === uid()) || isAdmin(r.city))) fail('Контакт доступен после принятия заявки');
    if (r.type === 'wash' && ['new', 'price_offered'].includes(r.status) && !isAdmin(r.city)) fail('Контакт доступен после подтверждения клиентом');
    const c = load().profiles[r.user_id]; return { full_name: c.full_name, phone: c.phone, username: c.username };
  },

  async vehicles() { return clone(load().vehicles.filter((v) => v.user_id === uid())); },
  async addVehicle(v) { if (!uid()) fail('Войдите'); if (!v.brand) fail('Укажите марку'); load().vehicles.push({ ...v, id: id(), user_id: uid() }); save(); },
  async deleteVehicle(vid) { const d = load(); d.vehicles = d.vehicles.filter((v) => !(v.id === +vid && v.user_id === uid())); save(); },

  async searchPrices({ service, brand }) {
    const words = stems(service), b = (brand || '').toLowerCase();
    return clone(load().prices.filter((p) => words.every((w) => p.service.toLowerCase().includes(w)) && (!b || !p.brand || p.brand.toLowerCase() === b))
      .map((p) => ({ ...p, provider: p.provider_id ? prov(p.provider_id) : null })).filter((p) => !p.provider || p.provider.is_active).sort((a, b2) => a.price - b2.price).slice(0, 200));
  },
  async providerPrices(pid) { return clone(load().prices.filter((p) => p.provider_id === +pid)); },
  async addPrice(x) { const p = prov(x.provider_id); if (!p || (p.owner_id !== uid() && !isAdmin())) fail('Нет прав'); if (!(+x.price > 0)) fail('Цена должна быть больше 0');
    load().prices.push({ ...x, id: id(), price: +x.price }); save(); },
  async deletePrice(xid) { const d = load(); const x = d.prices.find((p) => p.id === +xid); if (!x || !(prov(x.provider_id)?.owner_id === uid() || isAdmin())) fail('Нет прав');
    d.prices = d.prices.filter((p) => p.id !== +xid); save(); },

  async registerBusiness(p) {
    const m = me() || fail('Войдите'); if (!p.name || !p.phone || !p.city) fail('Заполните название, телефон и город');
    load().registrations.push({ id: id(), user_id: m.id, kind: p.kind, name: p.name, phone: p.phone, address: p.address || '', city: p.city, details: p.details || {}, status: 'pending', created_at: now() }); save();
  },
  async myRegistrations() { return clone(load().registrations.filter((g) => g.user_id === uid()).sort((a, b) => b.id - a.id)); },

  async adminRegistrations() { if (!isAdmin()) fail('Нет прав'); return clone(load().registrations.filter((g) => isAdmin(g.city)).sort((a, b) => b.id - a.id)); },
  async reviewRegistration(gid, approve, reason) {
    const g = load().registrations.find((x) => x.id === +gid); if (!g || !isAdmin(g.city)) fail('Нет прав'); if (g.status !== 'pending') fail('Заявка уже рассмотрена');
    if (approve) { const d = g.details || {}; const p = { id: id(), kind: g.kind, owner_id: g.user_id, name: g.name, city: g.city, address: g.address, phone: g.phone,
      working_hours: d.working_hours || '', specs: (d.specs || []).map(Number), supplier_type: d.supplier_type || null, service_type: d.service_type || null,
      boxes: +d.boxes || 1, slot_minutes: +d.slot_minutes || 60, delivery: !!d.delivery, rating: 0, reviews_count: 0, is_active: true, created_at: now() };
      load().providers.push(p); g.provider_id = p.id; }
    Object.assign(g, { status: approve ? 'approved' : 'rejected', reason: reason || null, reviewed_at: now() }); save();
  },
  async adminRequests() { if (!isAdmin()) fail('Нет прав'); return clone(load().requests.filter((r) => isAdmin(r.city)).sort((a, b) => b.id - a.id)); },
  async adminStats() {
    if (!isAdmin()) fail('Нет прав'); const d = load(); const rs = d.requests.filter((r) => isAdmin(r.city));
    return { users: Object.keys(d.profiles).length, providers: d.providers.filter((p) => isAdmin(p.city)).length, requests: rs.length,
      completed: rs.filter((r) => r.status === 'completed').length, active: rs.filter((r) => !['completed', 'cancelled'].includes(r.status) && r.status !== 'expired').length,
      pending_regs: d.registrations.filter((g) => g.status === 'pending').length, pending_reviews: d.reviews.filter((x) => !x.is_published).length,
      turnover: rs.filter((r) => r.status === 'completed').reduce((s, r) => s + (r.final_amount || 0), 0) };
  },
  async pendingReviews() { if (!isAdmin()) fail('Нет прав'); return clone(load().reviews.filter((x) => !x.is_published).map((x) => ({ ...x, provider_name: prov(x.provider_id)?.name }))); },
  async moderateReview(rid, publish) {
    if (!isAdmin()) fail('Нет прав'); const d = load(); const x = d.reviews.find((r) => r.id === +rid); if (!x) return;
    if (publish) x.is_published = true; else { d.reviews = d.reviews.filter((r) => r.id !== x.id); recalc(x.provider_id); } save();
  },
  async adminProviders() { if (!isAdmin()) fail('Нет прав'); return clone(load().providers.filter((p) => isAdmin(p.city))); },
  async setProviderActive(pid, active) { const p = prov(pid); if (!p || !isAdmin(p.city)) fail('Нет прав'); p.is_active = !!active; save(); },
  async setCityActive(cid, active) { if (!isAdmin()) fail('Нет прав'); const c = load().cities.find((x) => x.id === +cid); c.active = !!active; save(); },
  async setProviderVerified(pid, v) { const p = prov(pid); if (!p || !isAdmin(p.city)) fail('Нет прав'); p.verified = !!v; save(); },

  // ---- обновление 3: фото, чат, статистика, ответы на отзывы
  async caps() { return { v3: true, v4: true }; },
  async uploadRequestPhoto(blob) { if (!uid()) fail('Войдите'); return putPhoto(`req/${uid()}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`, blob); },
  async photoUrls(paths) { const m = photos(); return (paths || []).map((x) => (/^(assets|https?:|data:)/.test(x) ? x : m[x]) || ''); },
  async uploadProviderPhoto(pid, blob) { const p = prov(pid); if (!p || (p.owner_id !== uid() && !isAdmin(p.city))) fail('Нет прав'); return new Promise((ok, no) => { const fr = new FileReader(); fr.onload = () => ok(fr.result); fr.onerror = () => no(new Error('Не удалось прочитать фото')); fr.readAsDataURL(blob); }); },
  async providerStats(pid) {
    const rs = load().requests.filter((r) => r.accepted_by === +pid);
    const ts = rs.filter((r) => r.accepted_at).map((r) => (new Date(r.accepted_at) - new Date(r.created_at)) / 60000).sort((a, b) => a - b);
    const pr = load().prices.filter((x) => x.provider_id === +pid).map((x) => x.price);
    return { completed: rs.filter((r) => r.status === 'completed').length + (+pid === 1 ? 37 : +pid === 4 ? 52 : +pid === 6 ? 120 : 0),
      response_min: ts.length ? Math.round(ts[Math.floor(ts.length / 2)]) : (+pid === 1 ? 6 : +pid === 4 ? 3 : null), price_from: pr.length ? Math.min(...pr) : null };
  },
  async pricesFrom(ids) { const out = {}; for (const x of load().prices) if (x.provider_id && ids.includes(x.provider_id)) out[x.provider_id] = Math.min(out[x.provider_id] ?? Infinity, x.price); return out; },
  async getRequest(rid) {
    const r = req(rid); const p = prov(r.accepted_by);
    if (!(r.user_id === uid() || (p && p.owner_id === uid()) || (r.target_provider_id && prov(r.target_provider_id)?.owner_id === uid()) || isAdmin(r.city)
      || load().providers.some((pp) => pp.owner_id === uid() && matches(r, pp)))) fail('Заявка не найдена');
    return clone(r);
  },
  async messages(rid) { chatRole(rid); return clone(load().messages.filter((m) => m.request_id === +rid)); },
  async sendMessage(rid, body) {
    const role = chatRole(rid); const r = req(rid);
    if (role === 'admin') fail('Чат доступен клиенту и исполнителю, который взял заявку');
    if (r.status === 'cancelled') fail('Чат по этой заявке закрыт');
    if (!(body || '').trim()) fail('Пустое сообщение');
    const m = { id: id(), request_id: r.id, sender_id: uid(), from_provider: role === 'provider', body: body.trim().slice(0, 2000), created_at: now() };
    load().messages.push(m); save(); bus.forEach((f) => f(m));
    // в демо чужой исполнитель/клиент отвечает сам
    const other = role === 'client' ? prov(r.accepted_by)?.owner_id !== 'u-master' : r.user_id !== 'u-client';
    if (other && load().messages.filter((x) => x.request_id === r.id).length < 8) setTimeout(() => {
      const a = { id: id(), request_id: r.id, sender_id: null, from_provider: role === 'client', created_at: now(),
        body: role === 'client' ? 'Понял вас 👍 Если удобно, пришлите фото — так быстрее оценим работу.' : 'Хорошо, спасибо! Жду.' };
      load().messages.push(a); save(); bus.forEach((f) => f(a)); }, 2500);
    return clone(m);
  },
  subscribeInbox(cb) { const f = (m) => cb(m); bus.add(f); return () => bus.delete(f); },
  subscribeMessages(rid, cb) { const f = (m) => { if (m.request_id === +rid) cb(m); }; bus.add(f); return () => bus.delete(f); },
  async replyReview(rvid, text) {
    const x = load().reviews.find((r) => r.id === +rvid) || fail('Отзыв не найден');
    if (!(prov(x.provider_id)?.owner_id === uid() || isAdmin())) fail('Нет прав');
    x.reply = (text || '').trim().slice(0, 1000) || null; x.reply_at = now(); save();
  },

  // ---- обновление 4: согласия, обращения, права субъекта ПД, прозрачность
  async acceptLegal(kinds, version) {
    const m = me() || fail('Нужно войти'); const d = load(); d.consents ||= [];
    for (const k of kinds) d.consents.push({ id: id(), user_id: m.id, kind: k, version, accepted: true, user_agent: navigator.userAgent.slice(0, 300), created_at: now() });
    if (['pd', 'cross_border', 'terms', 'age18'].every((k) => kinds.includes(k))) Object.assign(m, { consent: true, consent_at: now(), legal_version: version, age_confirmed: true });
    save(); return clone(m);
  },
  async withdrawConsent() {
    const m = me() || fail('Нужно войти'); const d = load(); d.consents ||= [];
    for (const k of ['pd', 'cross_border']) d.consents.push({ id: id(), user_id: m.id, kind: k, version: m.legal_version || '-', accepted: false, created_at: now() });
    Object.assign(m, { phone: null, consent: false, legal_version: null }); save();
  },
  async exportMyData() {
    const u = uid() || fail('Нужно войти'); const d = load();
    return clone({ exported_at: now(), profile: me(), vehicles: d.vehicles.filter((x) => x.user_id === u), requests: d.requests.filter((x) => x.user_id === u),
      reviews: d.reviews.filter((x) => x.user_id === u), messages: d.messages.filter((x) => x.sender_id === u).map(({ request_id, body, created_at }) => ({ request_id, body, created_at })),
      registrations: d.registrations.filter((x) => x.user_id === u), providers: d.providers.filter((x) => x.owner_id === u),
      consents: (d.consents || []).filter((x) => x.user_id === u), complaints: (d.complaints || []).filter((x) => x.user_id === u) });
  },
  async deleteAccount() {
    const m = me() || fail('Нужно войти'); if (m.role !== 'client') fail('Администратор не может удалить себя — сначала передайте права');
    const d = load(), u = m.id;
    d.vehicles = d.vehicles.filter((x) => x.user_id !== u);
    d.messages.forEach((x) => { if (x.sender_id === u) x.body = '[удалено]'; });
    d.reviews.forEach((x) => { if (x.user_id === u) x.user_id = null; });
    d.requests.forEach((x) => { if (x.user_id === u) { const { photos, lat, lon, ...rest } = x.details || {}; x.details = rest; } });
    d.providers.forEach((x) => { if (x.owner_id === u) { x.owner_id = null; x.is_active = false; } });
    Object.assign(m, { username: null, full_name: 'Удалённый пользователь', phone: null, consent: false, legal_version: null, deleted_at: now() });
    save(); localStorage.removeItem(UKEY);
  },
  async submitComplaint({ type, target = '', reason = '', body = '', contact = '', lang = 'ru' }) {
    if (!uid() && !contact.trim()) fail('Укажите телефон, e-mail или Telegram для ответа');
    if (body.trim().length < 5) fail('Опишите суть обращения (не короче 5 символов)');
    const d = load(); d.complaints ||= [];
    const c = { id: id(), user_id: uid() || null, target_type: type, target_id: String(target), reason, body: body.trim().slice(0, 3000), contact, lang,
      status: 'new', answer: null, created_at: now(), due_at: new Date(Date.now() + 20 * 864e5).toISOString(), answered_at: null };
    d.complaints.push(c); save(); return { id: c.id, created_at: c.created_at, due_at: c.due_at, status: c.status };
  },
  async myComplaints() { return clone((load().complaints || []).filter((c) => c.user_id && c.user_id === uid()).reverse()); },
  async adminComplaints() { if (!isAdmin()) fail('Нет прав'); return clone((load().complaints || []).slice().reverse()); },
  async answerComplaint(cid, status, answer) {
    if (!isAdmin()) fail('Нет прав'); if (['resolved', 'rejected'].includes(status) && !(answer || '').trim()) fail('Нужен мотивированный ответ');
    const c = (load().complaints || []).find((x) => x.id === +cid) || fail('Не найдено');
    Object.assign(c, { status, answer: (answer || '').trim() || null, answered_at: ['resolved', 'rejected'].includes(status) ? now() : c.answered_at }); save();
  },
  async hit() { const d = load(); d.visits ||= {}; const k = now().slice(0, 10); d.visits[k] = (d.visits[k] || 0) + 1; save(); },
  async transparency() {
    const d = load(), by = {}; for (const [day, v] of Object.entries(d.visits || {})) { const m = day.slice(0, 7); (by[m] ||= []).push(v); }
    const cs = d.complaints || [];
    return { generated_at: now(), monthly: Object.entries(by).sort().reverse().slice(0, 6).map(([month, a]) => ({ month, visitors: a.reduce((x, y) => x + y, 0), avg_daily: Math.round(a.reduce((x, y) => x + y, 0) / a.length) })),
      registered_users: Object.values(d.profiles).filter((p) => !p.deleted_at).length, providers_active: d.providers.filter((p) => p.is_active).length,
      complaints_total: cs.length, complaints_resolved: cs.filter((c) => ['resolved', 'rejected'].includes(c.status)).length,
      complaints_overdue: cs.filter((c) => ['new', 'in_review'].includes(c.status) && new Date(c.due_at) < new Date()).length,
      reviews_published: d.reviews.filter((r) => r.is_published).length, reviews_hidden: d.reviews.filter((r) => !r.is_published).length };
  },

  async addCity(name) { if (!isAdmin()) fail('Нет прав'); if (!name) fail('Введите название'); load().cities.push({ id: id(), name, region: '', active: true }); save(); },
};

const bus = new Set();
const photos = () => { try { return JSON.parse(localStorage.getItem(PKEY)) || {}; } catch { return {}; } };
function putPhoto(path, blob) {
  return new Promise((ok, no) => { const fr = new FileReader(); fr.onerror = () => no(new Error('Не удалось прочитать фото'));
    fr.onload = () => { const m = photos(); m[path] = fr.result;
      try { localStorage.setItem(PKEY, JSON.stringify(m)); ok(path); } catch { no(new Error('В демо-режиме место для фото закончилось — нажмите «Сбросить демо»')); } };
    fr.readAsDataURL(blob); });
}
function chatRole(rid) {
  const r = req(rid); const p = prov(r.accepted_by);
  if (r.user_id === uid()) return 'client';
  if (p && p.owner_id === uid()) return 'provider';
  if (isAdmin(r.city)) return 'admin';
  fail('Чат недоступен');
}

// Имитация исполнителей в демо: чужие организации «откликаются» сами
function demoAutoReply(rid) {
  const r = load().requests.find((x) => x.id === rid); if (!r || r.status !== 'new') return;
  const cands = load().providers.filter((p) => p.owner_id !== 'u-master' && matches(r, p));
  if (!cands.length) return;
  const p = cands[0];
  if (r.type === 'parts') {
    cands.slice(0, 2).forEach((pp, i) => load().offers.push({ id: id(), request_id: r.id, provider_id: pp.id, price: 15000 + i * 3500, comment: i ? 'Б/у, в хорошем состоянии' : 'Новая, оригинал, в наличии', is_selected: false, created_at: now() }));
    touch(r, { status: 'offers' });
  } else if (r.type === 'wash') {
    touch(r, { status: 'price_offered', accepted_by: p.id, price: 6000, assigned_time: r.desired_time || plus(120) });
  } else touch(r, { status: 'active', accepted_by: p.id });
  let msg = null;
  if (r.type !== 'parts') load().messages.push(msg = { id: id(), request_id: r.id, sender_id: null, from_provider: true, created_at: now(),
    body: r.type === 'parts' ? 'Здравствуйте! Есть в наличии, можем отложить.' : r.type === 'wash' ? 'Здравствуйте! Предложили вам время — подтвердите, пожалуйста.' : 'Здравствуйте! Заявку принял, могу уточнить детали здесь в чате.' });
  save(); bus.forEach((f) => f(msg ? clone(msg) : { request_id: r.id }));
}
