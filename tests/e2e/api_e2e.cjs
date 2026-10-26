// Боевой сквозной тест API (Supabase prod) тестовыми аккаунтами @am24.test.
// Запуск: NODE_PATH=<node_modules с @supabase/supabase-js> node tests/e2e/api_e2e.cjs
// Требует применённых supabase/05_testing.sql и тестовых аккаунтов (см. README → «Тестирование»).
const { mk, login, must, rpc, ok, denied, summary, assert, URL_ } = require('./common.cjs');
const CITY = 'Талдыкорган', VER = '2026-10-26', ALL = ['pd', 'cross_border', 'terms', 'age18'];
const ORGS = {
  test_sto_1: { kind: 'sto', name: 'ТЕСТ СТО «Ходовая»', details: { specs: [2, 7], working_hours: '9:00–19:00' } },
  test_sto_2: { kind: 'sto', name: 'ТЕСТ СТО «Универсал»', details: {} },
  test_wash_1: { kind: 'wash', name: 'ТЕСТ Мойка', details: { boxes: 2, slot_minutes: 30 } },
  test_tow_1: { kind: 'tow', name: 'ТЕСТ Эвакуатор', details: {} },
  test_parts_1: { kind: 'parts', name: 'ТЕСТ Автомагазин', details: { supplier_type: 'shop', delivery: true } },
  test_parts_2: { kind: 'parts', name: 'ТЕСТ Разборка', details: { supplier_type: 'razborka' } },
  test_mobile_1: { kind: 'urgent', name: 'ТЕСТ Выездной мастер', details: { service_type: 'locksmith' } },
};
const PHOTO = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64');

(async () => {
  const anon = mk();
  const U = {};
  for (const n of ['test_admin', 'test_client_1', 'test_client_2', ...Object.keys(ORGS)]) U[n] = await ok('вход ' + n, () => login(n));
  if (Object.values(U).some((x) => !x)) { summary(); process.exit(1); }
  const A = U.test_admin, C = U.test_client_1, C2 = U.test_client_2;

  // ---------- профиль, согласия ----------
  for (const [n, s] of Object.entries(U)) await ok('профиль тестовый: ' + n, async () => { const p = await rpc(s, 'am_ensure_profile'); assert(p.is_test === true, 'is_test=' + p.is_test); });
  await ok('согласия (4 отдельных) — все пользователи', async () => { for (const s of Object.values(U)) await rpc(s, 'am_accept_legal', { p_kinds: ALL, p_version: VER, p_ua: 'e2e' }); });
  await ok('журнал согласий виден владельцу', async () => { const r = must(await C.from('am_consents').select('kind').eq('user_id', C.uid)); assert(r.length >= 4, 'записей ' + r.length); });
  await denied('телефон в неверном формате отклоняется', () => rpc(C2, 'am_update_profile', { p_full_name: 'ТЕСТ', p_phone: '123', p_city: CITY, p_consent: true }), /Телефон/);
  let i = 1;
  await ok('телефоны и город в профилях', async () => { for (const s of Object.values(U)) await rpc(s, 'am_update_profile', { p_full_name: null, p_phone: `+7 700 000 00 ${String(i++).padStart(2, '0')}`, p_city: CITY, p_consent: true }); });

  // ---------- организации: заявка → одобрение админом ----------
  const P = {};
  for (const [n, o] of Object.entries(ORGS)) {
    const s = U[n];
    await ok('организация ' + n, async () => {
      let mine = must(await s.from('am_providers').select('*').eq('owner_id', s.uid));
      if (!mine.length) {
        const regs = must(await s.from('am_registrations').select('*').eq('user_id', s.uid).eq('status', 'pending'));
        if (!regs.length) { await rpc(s, 'am_accept_legal', { p_kinds: ['provider_offer'], p_version: VER, p_ua: 'e2e' }); await rpc(s, 'am_register_business', { p: { ...o, phone: '+77000000099', city: CITY, address: 'ул. Тестовая, 1' } }); }
        const pend = must(await A.from('am_registrations').select('*').eq('user_id', s.uid).eq('status', 'pending'));
        assert(pend.length, 'админ не видит заявку на регистрацию');
        if (n === 'test_sto_1') await denied('клиент не может одобрить регистрацию', () => rpc(C, 'am_review_registration', { p_id: pend[0].id, p_approve: true, p_reason: null }), /прав/);
        await rpc(A, 'am_review_registration', { p_id: pend[0].id, p_approve: true, p_reason: null });
        mine = must(await s.from('am_providers').select('*').eq('owner_id', s.uid));
      }
      assert(mine.length && mine[0].is_test, 'организация не тестовая');
      P[n] = mine[0];
    });
  }
  await ok('админ ставит «Проверен» СТО 1', async () => { must(await A.from('am_providers').update({ verified: true }).eq('id', P.test_sto_1.id)); });
  await ok('владелец не может сам поднять рейтинг/«Проверен»', async () => {
    must(await U.test_sto_2.from('am_providers').update({ verified: true, rating: 5, about: 'ТЕСТ: о нас', whatsapp: '+77000000098' }).eq('id', P.test_sto_2.id));
    const p = must(await U.test_sto_2.from('am_providers').select('*').eq('id', P.test_sto_2.id).single());
    assert(!p.verified && +p.rating === 0 && p.about === 'ТЕСТ: о нас', JSON.stringify({ v: p.verified, r: p.rating, a: p.about }));
  });

  // ---------- каталог: изоляция тестовых ----------
  await ok('гость НЕ видит тестовые организации', async () => { const r = must(await anon.from('am_providers').select('id').eq('is_test', true)); assert(r.length === 0, 'видно ' + r.length); });
  await ok('тестовый клиент видит тестовые организации', async () => { const r = must(await C.from('am_providers').select('id').eq('city', CITY).eq('is_active', true)); assert(r.length >= 7, 'видно ' + r.length); });
  await ok('прайс исполнителя + поиск цен', async () => {
    const s = U.test_sto_1; const ex = must(await s.from('am_prices').select('id').eq('provider_id', P.test_sto_1.id));
    if (!ex.length) must(await s.from('am_prices').insert({ provider_id: P.test_sto_1.id, service: 'ТЕСТ Замена масла', price: 5000 }));
    const r = must(await C.from('am_prices').select('*, provider:am_providers(id,name)').ilike('service', '%ТЕСТ Замена%'));
    assert(r.length && r[0].provider, 'клиент не нашёл цену');
    const g = must(await anon.from('am_prices').select('id').eq('provider_id', P.test_sto_1.id)); assert(!g.length, 'гость видит тестовую цену');
  });
  await denied('чужой прайс не изменить', () => U.test_sto_2.from('am_prices').insert({ provider_id: P.test_sto_1.id, service: 'взлом', price: 1 }), /security|policy|violat/);
  await ok('фото организации (публичное) — владелец', async () => { must(await U.test_sto_1.storage.from('am-public').upload(`prov/${P.test_sto_1.id}/e2e-${Date.now()}.jpg`, PHOTO, { contentType: 'image/jpeg' })); });
  await denied('фото в чужую организацию — запрещено', () => U.test_sto_2.storage.from('am-public').upload(`prov/${P.test_sto_1.id}/hack-${Date.now()}.jpg`, PHOTO, { contentType: 'image/jpeg' }), /security|policy|Unauthorized|denied|row-level/i);

  // ---------- гараж ----------
  await ok('гараж: добавить авто', async () => { must(await C.from('am_vehicles').insert({ brand: 'Toyota', model: 'Camry', year: 2015, plate: 'TEST01' })); });
  await ok('гараж чужого не виден', async () => { const r = must(await C2.from('am_vehicles').select('id').eq('user_id', C.uid)); assert(!r.length, 'видно ' + r.length); });

  // ---------- СТО всем: фото, отказ, принятие, контакт, чат, отзыв ----------
  let photo;
  await ok('фото к заявке (приватное хранилище)', async () => { photo = `req/${C.uid}/e2e-${Date.now()}.jpg`; must(await C.storage.from('am-photos').upload(photo, PHOTO, { contentType: 'image/jpeg' })); });
  await denied('фото в чужую папку — запрещено', () => C2.storage.from('am-photos').upload(`req/${C.uid}/x-${Date.now()}.jpg`, PHOTO, { contentType: 'image/jpeg' }), /security|policy|Unauthorized|row-level/i);
  const r1 = await ok('СТО всем: заявка создана', () => rpc(C, 'am_create_request', { p: { type: 'sto', city: CITY, category_id: 2, subcategory: 'Стук в подвеске', description: 'ТЕСТ: стук спереди', vehicle_info: 'Toyota Camry 2015', details: { photos: [photo] } } }));
  await ok('заявка видна СТО 1 и СТО 2 (подходящие)', async () => {
    for (const n of ['test_sto_1', 'test_sto_2']) { const f = await rpc(U[n], 'am_provider_feed', { p_provider: P[n].id }); assert(f.some((x) => x.id === r1), n + ' не видит'); }
  });
  await ok('мойка/эвакуатор заявку СТО не видят', async () => { for (const n of ['test_wash_1', 'test_tow_1']) { const f = await rpc(U[n], 'am_provider_feed', { p_provider: P[n].id }); assert(!f.some((x) => x.id === r1), n + ' видит'); } });
  await ok('подходящий исполнитель видит фото (signed URL)', async () => { const r = must(await U.test_sto_1.storage.from('am-photos').createSignedUrl(photo, 60)); const h = await fetch(r.signedUrl); assert(h.ok, 'HTTP ' + h.status); });
  await denied('другой клиент не видит фото', () => C2.storage.from('am-photos').createSignedUrl(photo, 60), /not found|Object|denied|row/i);
  await denied('другой клиент не видит заявку', () => C2.from('am_requests').select('id').eq('id', r1));
  await denied('гость не видит заявку', () => anon.from('am_requests').select('id').eq('id', r1), /permission|denied/);
  await denied('телефон клиента скрыт до принятия', () => rpc(U.test_sto_1, 'am_client_contact', { p_id: r1 }), /после принятия/);
  await denied('профиль клиента недоступен исполнителю', () => U.test_sto_1.from('am_profiles').select('phone').eq('id', C.uid));
  await denied('чат до принятия закрыт', () => rpc(U.test_sto_1, 'am_send_message', { p_id: r1, p_body: 'привет' }), /Чат/);
  await ok('СТО 2 отказывается', () => rpc(U.test_sto_2, 'am_decline_request', { p_id: r1, p_provider: P.test_sto_2.id }));
  await ok('после отказа заявка исчезла из ленты СТО 2', async () => { const f = await rpc(U.test_sto_2, 'am_provider_feed', { p_provider: P.test_sto_2.id }); assert(!f.some((x) => x.id === r1), 'видна'); });
  await denied('чужая организация не принимает от моего имени', () => rpc(U.test_sto_2, 'am_accept_request', { p_id: r1, p_provider: P.test_sto_1.id }), /не ваша/);
  await ok('СТО 1 принимает', () => rpc(U.test_sto_1, 'am_accept_request', { p_id: r1, p_provider: P.test_sto_1.id }));
  await denied('повторное принятие другим — нельзя', () => rpc(U.test_sto_2, 'am_accept_request', { p_id: r1, p_provider: P.test_sto_2.id }), /недоступна|принял/);
  await ok('после принятия СТО 1 видит телефон клиента', async () => { const r = await rpc(U.test_sto_1, 'am_client_contact', { p_id: r1 }); assert(r[0]?.phone, 'нет телефона'); });
  await denied('СТО 2 телефон не видит', () => rpc(U.test_sto_2, 'am_client_contact', { p_id: r1 }), /после принятия/);

  // чат + realtime
  await ok('чат в реальном времени (клиент ↔ СТО)', async () => {
    const got = new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('сообщение не пришло по realtime за 15 с')), 15000);
      C.realtime.setAuth(C.session.access_token);
      const ch = C.channel('e2e-' + r1).on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'am_messages', filter: `request_id=eq.${r1}` }, (p) => { if (p.new.body === 'ТЕСТ: Выезжаю') { clearTimeout(t); ch.unsubscribe(); res(); } })
        .subscribe(async (st) => { if (st === 'SUBSCRIBED') { await new Promise((z) => setTimeout(z, 2500)); await rpc(U.test_sto_1, 'am_send_message', { p_id: r1, p_body: 'ТЕСТ: Выезжаю' }); } });
    });
    await got;
    await rpc(C, 'am_send_message', { p_id: r1, p_body: 'ТЕСТ: Жду, спасибо' });
    const m = must(await U.test_sto_1.from('am_messages').select('*').eq('request_id', r1)); assert(m.length >= 2, 'сообщений ' + m.length);
  });
  await denied('чужой не читает чат', () => C2.from('am_messages').select('id').eq('request_id', r1));
  await denied('чужой не пишет в чат', () => rpc(U.test_sto_2, 'am_send_message', { p_id: r1, p_body: 'spam' }), /Чат/);
  await ok('СТО 1 завершает (сумма 15000)', () => rpc(U.test_sto_1, 'am_complete_request', { p_id: r1, p_provider: P.test_sto_1.id, p_amount: 15000 }));
  let rev;
  await ok('клиент оставляет отзыв с текстом → на модерации', async () => {
    await rpc(C, 'am_leave_review', { p_id: r1, p_rating: 5, p_comment: 'ТЕСТ: всё отлично' });
    rev = must(await C.from('am_reviews').select('*').eq('request_id', r1).single()); assert(!rev.is_published, 'сразу опубликован');
  });
  await denied('другой клиент не видит неопубликованный отзыв', () => C2.from('am_reviews').select('id').eq('id', rev?.id));
  await denied('отзыв на чужую заявку — нельзя', () => rpc(C2, 'am_leave_review', { p_id: r1, p_rating: 1, p_comment: 'фейк' }), /не найдена/);
  await denied('клиент не модерирует', () => rpc(C2, 'am_moderate_review', { p_id: rev?.id, p_publish: true }), /прав/);
  await ok('админ публикует отзыв', () => rpc(A, 'am_moderate_review', { p_id: rev.id, p_publish: true }));
  await ok('ответ исполнителя на отзыв', () => rpc(U.test_sto_1, 'am_reply_review', { p_id: rev.id, p_text: 'ТЕСТ: спасибо!' }));
  await denied('чужой исполнитель не отвечает', () => rpc(U.test_sto_2, 'am_reply_review', { p_id: rev.id, p_text: 'x' }), /прав/);
  await ok('рейтинг пересчитан, статистика', async () => { const p = must(await C.from('am_providers').select('rating,reviews_count').eq('id', P.test_sto_1.id).single()); assert(+p.rating > 0 && p.reviews_count >= 1, JSON.stringify(p)); await rpc(C, 'am_provider_stats', { p_id: P.test_sto_1.id }); });
  await ok('гость не видит отзывы тестовых организаций', async () => { const r = must(await anon.from('am_reviews').select('id').eq('provider_id', P.test_sto_1.id)); assert(!r.length, 'видно ' + r.length); });

  // ---------- СТО конкретному + отмена ----------
  const r2 = await ok('заявка конкретному СТО 2', () => rpc(C, 'am_create_request', { p: { type: 'sto', city: CITY, category_id: 8, target_provider_id: P.test_sto_2.id, description: 'ТЕСТ: ТО' } }));
  await ok('СТО 1 её не видит, СТО 2 видит', async () => {
    const f1 = await rpc(U.test_sto_1, 'am_provider_feed', { p_provider: P.test_sto_1.id }); const f2 = await rpc(U.test_sto_2, 'am_provider_feed', { p_provider: P.test_sto_2.id });
    assert(!f1.some((x) => x.id === r2) && f2.some((x) => x.id === r2), 'маршрутизация');
  });
  await ok('клиент отменяет', () => rpc(C, 'am_cancel_request', { p_id: r2 }));
  await denied('отменённую нельзя принять', () => rpc(U.test_sto_2, 'am_accept_request', { p_id: r2, p_provider: P.test_sto_2.id }), /принял|недоступна/);

  // ---------- эвакуатор ----------
  const r3 = await ok('эвакуатор: заявка', () => rpc(C, 'am_create_request', { p: { type: 'tow', city: CITY, description: 'ТЕСТ: не заводится', details: { vehicle: 'Легковой автомобиль', wheels: 'Колёса крутятся', from: 'ул. Тестовая 1', to: 'ул. Тестовая 2' } } }));
  await ok('эвакуатор принимает и завершает', async () => { await rpc(U.test_tow_1, 'am_accept_request', { p_id: r3, p_provider: P.test_tow_1.id }); await rpc(U.test_tow_1, 'am_complete_request', { p_id: r3, p_provider: P.test_tow_1.id, p_amount: 8000 }); });
  await ok('клиент: отзыв без текста публикуется сразу', async () => { await rpc(C, 'am_leave_review', { p_id: r3, p_rating: 4, p_comment: '' }); const v = must(await C.from('am_reviews').select('is_published').eq('request_id', r3).single()); assert(v.is_published, 'не опубликован'); });

  // ---------- мойка ----------
  const r4 = await ok('мойка: заявка', () => rpc(C, 'am_create_request', { p: { type: 'wash', city: CITY, service_type: 'Комплексная мойка', desired_time: new Date(Date.now() + 864e5).toISOString(), details: { car_type: 'Седан' } } }));
  await denied('мойка: принять без цены нельзя', () => rpc(U.test_wash_1, 'am_accept_request', { p_id: r4, p_provider: P.test_wash_1.id }), /предложение/);
  await ok('мойка предлагает цену и время', () => rpc(U.test_wash_1, 'am_wash_quote', { p_id: r4, p_provider: P.test_wash_1.id, p_price: 4000, p_time: new Date(Date.now() + 9e7).toISOString() }));
  await denied('мойка: телефон клиента до подтверждения скрыт', () => rpc(U.test_wash_1, 'am_client_contact', { p_id: r4 }), /подтверждения/);
  await ok('клиент подтверждает', () => rpc(C, 'am_wash_approve', { p_id: r4 }));
  await ok('мойка: в работе → ожидает клиента → готово', async () => { for (const st of ['in_progress', 'waiting_client', 'completed']) await rpc(U.test_wash_1, 'am_wash_status', { p_id: r4, p_provider: P.test_wash_1.id, p_status: st }); });
  await ok('мойка: итог', async () => { const r = must(await C.from('am_requests').select('status,final_amount').eq('id', r4).single()); assert(r.status === 'completed' && r.final_amount === 4000, JSON.stringify(r)); });

  // ---------- запчасти: анонимные предложения ----------
  const r5 = await ok('запчасти: заявка «везде»', () => rpc(C, 'am_create_request', { p: { type: 'parts', city: CITY, description: 'ТЕСТ: фара передняя левая', vehicle_info: 'Toyota Camry 2015', details: { urgency: 'Сегодня', original: 'Любая' } } }));
  await denied('запчасти: «принять» нельзя, только предложение', () => rpc(U.test_parts_1, 'am_accept_request', { p_id: r5, p_provider: P.test_parts_1.id }), /предложение/);
  await ok('магазин и разборка предлагают цены', async () => { await rpc(U.test_parts_1, 'am_make_offer', { p_id: r5, p_provider: P.test_parts_1.id, p_price: 25000, p_comment: 'ТЕСТ: оригинал' }); await rpc(U.test_parts_2, 'am_make_offer', { p_id: r5, p_provider: P.test_parts_2.id, p_price: 12000, p_comment: 'ТЕСТ: б/у' }); });
  let offers;
  await ok('клиент видит предложения анонимно', async () => { offers = await rpc(C, 'am_request_offers', { p_id: r5 }); assert(offers.length === 2 && offers.every((o) => !o.provider_phone && /Поставщик/.test(o.provider_name)), JSON.stringify(offers)); });
  await denied('поставщик не видит чужие предложения', () => U.test_parts_2.from('am_offers').select('id').eq('provider_id', P.test_parts_1.id));
  await ok('клиент выбирает магазин → контакты открылись', async () => { const o = offers.find((x) => x.price === 25000); await rpc(C, 'am_select_offer', { p_offer: o.id }); const after = await rpc(C, 'am_request_offers', { p_id: r5 }); assert(after.find((x) => x.is_selected)?.provider_phone, 'нет телефона'); });
  await denied('разборка не может завершить чужую', () => rpc(U.test_parts_2, 'am_complete_request', { p_id: r5, p_provider: P.test_parts_2.id, p_amount: null }), /не ваша/);
  await ok('магазин передал → клиент подтвердил получение', async () => { await rpc(U.test_parts_1, 'am_complete_request', { p_id: r5, p_provider: P.test_parts_1.id, p_amount: null }); await rpc(C, 'am_client_confirm', { p_id: r5 }); const r = must(await C.from('am_requests').select('status').eq('id', r5).single()); assert(r.status === 'completed', r.status); });

  // ---------- выездная помощь ----------
  const r6 = await ok('выездная помощь (вскрытие замков)', () => rpc(C2, 'am_create_request', { p: { type: 'urgent', city: CITY, service_type: 'locksmith', description: 'ТЕСТ: ключи в машине' } }));
  await ok('мастер другой специализации не видит; профильный принимает', async () => {
    const f = await rpc(U.test_mobile_1, 'am_provider_feed', { p_provider: P.test_mobile_1.id }); assert(f.some((x) => x.id === r6), 'не видит');
    await rpc(U.test_mobile_1, 'am_accept_request', { p_id: r6, p_provider: P.test_mobile_1.id }); await rpc(C2, 'am_client_confirm', { p_id: r6 });
  });
  await ok('клиент 1 не видит заявку клиента 2', async () => { const r = must(await C.from('am_requests').select('id').eq('id', r6)); assert(!r.length, 'видно'); });

  // ---------- обращения ----------
  let comp;
  await ok('жалоба клиента на исполнителя', async () => { comp = await rpc(C, 'am_submit_complaint', { p_type: 'provider', p_target: String(P.test_sto_2.id), p_reason: 'Не приехал', p_body: 'ТЕСТ: жалоба', p_contact: '', p_lang: 'ru' }); assert(comp.id, 'нет id'); });
  await ok('жалоба гостя (с контактом)', () => rpc(anon, 'am_submit_complaint', { p_type: 'platform', p_target: '', p_reason: '', p_body: 'ТЕСТ: гость', p_contact: 'guest@am24.test', p_lang: 'kk' }));
  await denied('клиент 2 не видит чужую жалобу', () => C2.from('am_complaints').select('id').eq('id', comp?.id));
  await denied('не-админ не отвечает', () => rpc(C2, 'am_answer_complaint', { p_id: comp?.id, p_status: 'resolved', p_answer: 'x' }), /прав/);
  await ok('админ отвечает, клиент видит ответ', async () => { await rpc(A, 'am_answer_complaint', { p_id: comp.id, p_status: 'resolved', p_answer: 'ТЕСТ: связались с исполнителем' }); const c = must(await C.from('am_complaints').select('status,answer').eq('id', comp.id).single()); assert(c.status === 'resolved' && c.answer, JSON.stringify(c)); });

  // ---------- админ: права региона ----------
  await ok('админ: статистика и заявки региона', async () => { const s = await rpc(A, 'am_admin_stats'); assert(s.requests >= 1, JSON.stringify(s)); await rpc(A, 'am_admin_requests'); });
  await denied('регионал не может назначать админов', () => rpc(A, 'am_make_admin', { p_username: 'test_client_2', p_city: null }), /прав/);
  await denied('регионал не меняет справочник городов', async () => { const r = await A.from('am_cities').update({ region: 'взлом' }).eq('name', 'Алматы').select(); return r; });
  await denied('клиент не видит админ-статистику', () => rpc(C, 'am_admin_stats'), /прав/);
  await denied('клиент не видит чужие профили', () => C.from('am_profiles').select('id').neq('id', C.uid));

  // ---------- права субъекта ПД ----------
  await ok('выгрузка «мои данные»', async () => { const d = await rpc(C, 'am_export_my_data'); assert(d.profile && d.requests?.length >= 1, Object.keys(d).join(',')); });
  await ok('прозрачность не считает тестовые данные', async () => { const t = await rpc(anon, 'am_transparency'); assert(t.providers_active === 0 || t.providers_active < 7, JSON.stringify(t)); });

  // ---------- отзыв согласия и удаление аккаунта — на одноразовом пользователе ----------
  const D = await ok('вход одноразового test_load_40', () => login('test_load_40'));
  if (D) {
    const prof = await rpc(D, 'am_ensure_profile');
    if (prof.deleted_at) console.log('     (test_load_40 уже удалён в прошлом прогоне — пропуск)');
    else {
      await rpc(D, 'am_accept_legal', { p_kinds: ALL, p_version: VER, p_ua: 'e2e' }); await rpc(D, 'am_update_profile', { p_full_name: null, p_phone: '+77000000040', p_city: CITY, p_consent: true });
      await ok('отзыв согласия → заявки создавать нельзя', async () => { await rpc(D, 'am_withdraw_consent', { p_ua: 'e2e' }); let e; try { await rpc(D, 'am_create_request', { p: { type: 'tow', city: CITY } }); } catch (x) { e = x; } assert(e && /согласие/.test(e.message), 'создалась'); });
      await ok('удаление аккаунта обезличивает профиль', async () => { await rpc(D, 'am_delete_my_account', { p_ua: 'e2e' }); const p = await rpc(D, 'am_ensure_profile'); assert(p.deleted_at && !p.phone, JSON.stringify(p)); });
    }
  }
  process.exit(summary() ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
