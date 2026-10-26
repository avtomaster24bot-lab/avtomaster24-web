// Боевой тест ролей и прав (08_admin.sql): сотрудники, блокировка, настройки, границы регионального админа.
// Запуск: NODE_PATH=<node_modules с @supabase/supabase-js> node tests/e2e/roles_e2e.cjs
// Меняет только тестовые аккаунты @am24.test; настройку города ставит равной значению по умолчанию и сразу удаляет.
const { mk, login, must, rpc, ok, denied, summary, assert } = require('./common.cjs');
const CITY = 'Талдыкорган', OTHER = 'Алматы';
(async () => {
  const anon = mk(); const U = {};
  for (const n of ['test_admin', 'test_client_3', 'test_sto_1', 'test_load_1', 'test_load_2', 'test_load_3', 'test_load_5', 'test_load_6']) U[n] = await login(n);
  const A = U.test_admin, C = U.test_client_3, O = U.test_sto_1, M = U.test_load_1, W = U.test_load_2, X = U.test_load_3, B = U.test_load_5, F = U.test_load_6;
  const prof = async (s) => rpc(s, 'am_ensure_profile');
  let k = 50;
  for (const s of [C, M, W, X, B]) await rpc(s, 'am_update_profile', { p_full_name: null, p_phone: `+7 700 000 00 ${k++}`, p_city: CITY, p_consent: true });
  await rpc(F, 'am_update_profile', { p_full_name: null, p_phone: `+7 700 000 00 ${k++}`, p_city: OTHER, p_consent: true });
  const pid = must(await O.from('am_providers').select('id,kind,city').eq('owner_id', O.uid).eq('kind', 'sto'))[0]?.id;
  assert(pid, 'нет СТО у test_sto_1');
  must(await O.from('am_providers').update({ paused: false, days_off: [] }).eq('id', pid).select()); // на случай прерванного прошлого запуска

  // ---------- настройки: публичное чтение, кто что может менять ----------
  await ok('гость читает настройки (am_setting)', () => rpc(anon, 'am_setting', { p_key: 'ttl_sto', p_city: CITY }));
  await denied('гость не меняет настройки', () => rpc(anon, 'am_set_setting', { p_key: 'ttl_parts', p_city: CITY, p_value: 180 }));
  await denied('клиент не меняет настройки', () => rpc(C, 'am_set_setting', { p_key: 'ttl_parts', p_city: CITY, p_value: 180 }), /прав/);
  await denied('регион. админ не меняет общие лимиты', () => rpc(A, 'am_set_setting', { p_key: 'max_requests_hour', p_city: '', p_value: 200 }), /главный/);
  await denied('регион. админ не меняет чужой город', () => rpc(A, 'am_set_setting', { p_key: 'ttl_parts', p_city: OTHER, p_value: 180 }), /прав/);
  await denied('вне диапазона отклоняется', () => rpc(A, 'am_set_setting', { p_key: 'ttl_parts', p_city: CITY, p_value: 1 }), /от/);
  await ok('регион. админ: настройка своего города (= умолчанию) и сброс', async () => {
    await rpc(A, 'am_set_setting', { p_key: 'ttl_parts', p_city: CITY, p_value: 180 });
    const v = await rpc(anon, 'am_setting', { p_key: 'ttl_parts', p_city: CITY }); assert(+v === 180, 'v=' + v);
    await rpc(A, 'am_set_setting', { p_key: 'ttl_parts', p_city: CITY, p_value: null });
    const left = must(await anon.from('am_settings').select('*').eq('key', 'ttl_parts').eq('city', CITY)); assert(!left.length, 'не удалилось');
  });

  // ---------- роли: регион. админ не назначает ----------
  await denied('регион. админ не назначает админов', () => rpc(A, 'am_admin_set_role', { p_user: X.uid, p_role: 'regional_admin', p_city: CITY }), /главный|Только/i);
  await denied('клиент не назначает себя админом', () => rpc(C, 'am_admin_set_role', { p_user: C.uid, p_role: 'global_admin' }));
  await denied('клиент не видит список админов', () => rpc(C, 'am_admin_list'));
  await ok('регион. админ: пользователи только своего города', async () => {
    const r = await rpc(A, 'am_admin_users', { p_q: 'test_load', p_limit: 100 });
    assert(r.some((u) => u.id === B.uid), 'нет своего'); assert(!r.some((u) => u.id === F.uid), 'видит чужой город');
  });
  await denied('клиент не ищет пользователей', () => rpc(C, 'am_admin_users', { p_q: '' }));

  // ---------- блокировка ----------
  await denied('регион. админ не блокирует в чужом городе', () => rpc(A, 'am_admin_block', { p_user: F.uid, p_block: true, p_reason: 'ТЕСТ' }), /прав|город/i);
  await denied('блокировка без причины', () => rpc(A, 'am_admin_block', { p_user: B.uid, p_block: true, p_reason: '' }), /причин/i);
  await denied('клиент не блокирует', () => rpc(C, 'am_admin_block', { p_user: B.uid, p_block: true, p_reason: 'x' }));
  await denied('админ не блокирует себя', () => rpc(A, 'am_admin_block', { p_user: A.uid, p_block: true, p_reason: 'x' }));
  await ok('регион. админ блокирует пользователя своего города', () => rpc(A, 'am_admin_block', { p_user: B.uid, p_block: true, p_reason: 'ТЕСТ: проверка блокировки' }));
  await ok('заблокированный видит отметку в профиле', async () => { const p = await prof(B); assert(p.blocked_at && /ТЕСТ/.test(p.blocked_reason), JSON.stringify(p).slice(0, 200)); });
  await denied('заблокированный не создаёт заявку', () => rpc(B, 'am_create_request', { p: { type: 'sto', city: CITY, category_id: 2, description: 'ТЕСТ', vehicle_info: 'ТЕСТ' } }), /заблок/i);
  await denied('заблокированный не подаёт регистрацию бизнеса', () => rpc(B, 'am_register_business', { p: { kind: 'sto', name: 'ТЕСТ блок', phone: '+77000000099', city: CITY, details: {} } }), /заблок/i);
  await ok('разблокировка', async () => { await rpc(A, 'am_admin_block', { p_user: B.uid, p_block: false, p_reason: '' }); const p = await prof(B); assert(!p.blocked_at, 'всё ещё заблокирован'); });

  // ---------- сотрудники ----------
  const un = async (s) => (await prof(s)).username;
  for (const s of [M, W]) await rpc(O, 'am_staff_remove', { p_provider: pid, p_user: s.uid }).catch(() => {});
  await denied('не владелец не добавляет сотрудников', async () => rpc(X, 'am_staff_add', { p_provider: pid, p_username: await un(X), p_role: 'manager' }), /владел/i);
  await denied('несуществующий username', () => rpc(O, 'am_staff_add', { p_provider: pid, p_username: 'no_such_user_am24_xyz', p_role: 'manager' }), /не найден|войти/i);
  await ok('владелец добавляет менеджера и мастера по username', async () => {
    await rpc(O, 'am_staff_add', { p_provider: pid, p_username: await un(M), p_role: 'manager' });
    await rpc(O, 'am_staff_add', { p_provider: pid, p_username: '@' + await un(W), p_role: 'master' });
    const l = await rpc(O, 'am_staff_list', { p_provider: pid }); assert(l.length >= 3, 'список ' + l.length);
  });
  await ok('сотрудники видят организацию в «мои организации» со своей ролью', async () => {
    const m = await rpc(M, 'am_my_orgs'), w = await rpc(W, 'am_my_orgs');
    assert(m.some((x) => x.org.id === pid && x.my_role === 'manager'), 'manager'); assert(w.some((x) => x.org.id === pid && x.my_role === 'master'), 'master');
  });
  await denied('посторонний не видит список сотрудников', () => rpc(X, 'am_staff_list', { p_provider: pid }));
  await denied('менеджер не меняет профиль организации', async () => { const r = await M.from('am_providers').update({ about: 'ТЕСТ взлом' }).eq('id', pid).select(); return r; });
  await denied('мастер не включает паузу', async () => W.from('am_providers').update({ paused: true }).eq('id', pid).select());

  const rid = await ok('клиент создаёт заявку в СТО', () => rpc(C, 'am_create_request', { p: { type: 'sto', city: CITY, category_id: 2, subcategory: 'ТЕСТ роли', description: 'ТЕСТ: проверка сотрудников', vehicle_info: 'ТЕСТ' } }));
  await ok('менеджер видит заявку в ленте', async () => { const f = await rpc(M, 'am_provider_feed', { p_provider: pid }); assert(f.some((r) => r.id === rid), 'нет'); });
  await ok('мастер не видит непорученную заявку', async () => { const f = await rpc(W, 'am_provider_feed', { p_provider: pid }); assert(!f.some((r) => r.id === rid), 'видит'); });
  await denied('мастер не принимает заявку', () => rpc(W, 'am_accept_request', { p_id: rid, p_provider: pid }));
  await ok('менеджер принимает заявку от организации', () => rpc(M, 'am_accept_request', { p_id: rid, p_provider: pid }));
  await ok('«принял» = менеджер', async () => { const r = must(await O.from('am_requests').select('handled_by,accepted_by').eq('id', rid).single()); assert(r.handled_by === M.uid && r.accepted_by === pid, JSON.stringify(r)); });
  await ok('менеджер пишет в чат', () => rpc(M, 'am_send_message', { p_id: rid, p_body: 'ТЕСТ: менеджер на связи' }));
  await denied('мастер до поручения не пишет в чат', () => rpc(W, 'am_send_message', { p_id: rid, p_body: 'x' }), /Чат/);
  await denied('мастер до поручения не видит телефон', () => rpc(W, 'am_client_contact', { p_id: rid }));
  await denied('посторонний не видит телефон клиента (09)', () => rpc(X, 'am_client_contact', { p_id: rid }), /Контакт/);
  await denied('посторонний не видит, кто принял (09)', () => rpc(X, 'am_request_staff', { p_id: rid }), /прав/);
  await denied('посторонний не удаляет сотрудника (09)', () => rpc(X, 'am_staff_remove', { p_provider: pid, p_user: W.uid }), /прав/);
  await denied('посторонний не поручает', () => rpc(X, 'am_assign_request', { p_id: rid, p_user: W.uid }));
  await denied('нельзя поручить не сотруднику', () => rpc(M, 'am_assign_request', { p_id: rid, p_user: X.uid }), /сотрудник/i);
  await ok('менеджер поручает мастеру', () => rpc(M, 'am_assign_request', { p_id: rid, p_user: W.uid }));
  await ok('мастер видит порученную заявку, чат и телефон', async () => {
    const f = await rpc(W, 'am_provider_feed', { p_provider: pid }); assert(f.some((r) => r.id === rid), 'нет в ленте');
    await rpc(W, 'am_send_message', { p_id: rid, p_body: 'ТЕСТ: мастер, буду в 10:00' }); await rpc(W, 'am_client_contact', { p_id: rid });
  });
  await ok('клиент видит сообщения менеджера и мастера', async () => { const m = must(await C.from('am_messages').select('body').eq('request_id', rid)); assert(m.length >= 2, 'сообщений ' + m.length); });
  await ok('мастер завершает порученную заявку', () => rpc(W, 'am_complete_request', { p_id: rid, p_provider: pid, p_amount: 1000 }));
  await ok('владелец видит, кто сколько заявок принял', async () => { const l = await rpc(O, 'am_staff_list', { p_provider: pid }); assert(l.find((x) => x.user_id === M.uid)?.handled >= 1, JSON.stringify(l)); });
  await ok('владелец удаляет сотрудников — доступ пропадает', async () => {
    for (const s of [M, W]) await rpc(O, 'am_staff_remove', { p_provider: pid, p_user: s.uid });
    const m = await rpc(M, 'am_my_orgs'); assert(!m.some((x) => x.org.id === pid), 'остался');
  });
  await denied('бывший менеджер не видит ленту', () => rpc(M, 'am_provider_feed', { p_provider: pid }));

  // ---------- пауза ----------
  await ok('пауза: новые заявки не приходят, снятие паузы', async () => {
    must(await O.from('am_providers').update({ paused: true, days_off: [0] }).eq('id', pid).select());
    let seen, r2;
    try { r2 = await rpc(C, 'am_create_request', { p: { type: 'sto', city: CITY, category_id: 2, description: 'ТЕСТ: пауза', vehicle_info: 'ТЕСТ' } });
      seen = (await rpc(O, 'am_provider_feed', { p_provider: pid })).some((r) => r.id === r2);
    } finally { must(await O.from('am_providers').update({ paused: false, days_off: [] }).eq('id', pid).select()); }
    await rpc(C, 'am_cancel_request', { p_id: r2 }).catch(() => {});
    assert(!seen, 'на паузе заявка пришла');
  });

  // ---------- журнал ----------
  await ok('журнал: регион. админ видит записи своего города', async () => { const l = must(await A.from('am_admin_log').select('action,city').order('id', { ascending: false }).limit(30)); assert(l.some((x) => x.action === 'block'), 'нет блокировки'); assert(l.every((x) => x.city === CITY), 'чужие записи'); });
  await denied('посторонний не отвечает на отзыв (09)', async () => { const rv = must(await O.from('am_reviews').select('id').eq('provider_id', pid).limit(1)); if (!rv.length) throw new Error('Нет прав (нет отзывов)'); return rpc(X, 'am_reply_review', { p_id: rv[0].id, p_text: 'ТЕСТ взлом' }); }, /прав/);
  await ok('владелец очищает ответы «ТЕСТ взлом» (если прошли до 09)', async () => { for (const r of must(await O.from('am_reviews').select('id,reply').eq('provider_id', pid))) if (r.reply === 'ТЕСТ взлом') await rpc(O, 'am_reply_review', { p_id: r.id, p_text: '' }); });
  await denied('клиент не видит журнал', async () => C.from('am_admin_log').select('*').limit(5));
  process.exit(summary() ? 1 : 0);
})();
