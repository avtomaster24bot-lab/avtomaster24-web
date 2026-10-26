-- Тест обновления 6 (роли, настройки, сотрудники, блокировка). Локально, не запускать в Supabase.
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u, 'role','authenticated')::text end, false) $$;
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL %', label; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK %: %', label, sqlerrm; end $$;
insert into auth.users(id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000201', 'own@example.com', '{"username":"org_owner","first_name":"Владелец"}'),
  ('00000000-0000-0000-0000-000000000202', 'mgr@example.com', '{"username":"org_manager","first_name":"Менеджер"}'),
  ('00000000-0000-0000-0000-000000000203', 'mst@example.com', '{"username":"org_master","first_name":"Мастер"}'),
  ('00000000-0000-0000-0000-000000000204', 'cli@example.com', '{"username":"cli6","first_name":"Клиент6"}'),
  ('00000000-0000-0000-0000-000000000205', 'rg@example.com',  '{"username":"reg6","first_name":"Регионал"}');
set role authenticated;
do $$ declare u text; begin foreach u in array array['201','202','203','204','205'] loop
  perform pg_temp.as_user('00000000-0000-0000-0000-000000000' || u); perform am_ensure_profile();
  perform am_update_profile(null, '+7 701 000 0' || u, 'Талдыкорган', true); end loop; end $$;
-- главный админ (00a из flow_test) назначает регионала
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select am_admin_set_role('00000000-0000-0000-0000-000000000205', 'regional_admin', 'Талдыкорган');
select 'админов в списке: ' || count(*) from am_admin_list();
select pg_temp.expect_fail($$select am_admin_set_role('00000000-0000-0000-0000-00000000000a', 'client', null)$$, 'нельзя снять последнего главного');
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select pg_temp.expect_fail($$select am_admin_set_role('00000000-0000-0000-0000-000000000204', 'global_admin', null)$$, 'регионал не назначает админов');
select pg_temp.expect_fail($$select am_set_setting('max_open_requests', '', '5')$$, 'регионал не меняет общие лимиты');
select am_set_setting('ttl_tow', 'Талдыкорган', '15');
select am_set_setting('city_notice', 'Талдыкорган', '"Сегодня гололёд — эвакуаторы загружены"');
select pg_temp.expect_fail($$select am_set_setting('ttl_tow', 'Алматы', '15')$$, 'регионал не трогает чужой город');
select pg_temp.expect_fail($$select am_set_setting('ttl_tow', 'Талдыкорган', '5')$$, 'вне диапазона');
select 'пользователей видит регионал: ' || count(*) from am_admin_users('', 200);
-- блокировка клиента регионалом
select am_admin_block('00000000-0000-0000-0000-000000000204', true, 'Спам заявками');
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select pg_temp.expect_fail($$select am_create_request('{"type":"tow","city":"Талдыкорган"}')$$, 'заблокированный не создаёт заявки');
select pg_temp.expect_fail($$select am_register_business('{"kind":"sto","name":"X","phone":"+77010000000","city":"Талдыкорган"}')$$, 'заблокированный не регистрирует бизнес');
select 'обращение заблокированного: ' || (am_submit_complaint('appeal', '', 'Блокировка', 'Прошу разблокировать', '', 'ru') ->> 'status');
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select pg_temp.expect_fail($$select am_admin_block('00000000-0000-0000-0000-00000000000a', true, 'x')$$, 'админа не заблокировать');
select am_admin_block('00000000-0000-0000-0000-000000000204', false, '');
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select 'после разблокировки заявка: ' || (am_create_request('{"type":"tow","city":"Талдыкорган"}') > 0);
select 'срок из настройки города, мин: ' || round(extract(epoch from (expires_at - created_at)) / 60) from am_requests where user_id = '00000000-0000-0000-0000-000000000204' order by id desc limit 1;
-- организация эвакуатора с сотрудниками
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select am_register_business('{"kind":"tow","name":"Эвакуатор Команда","phone":"+77010001111","city":"Талдыкорган"}');
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select am_review_registration((select max(id) from am_registrations), true, null);
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select am_staff_add((select id from am_providers where name = 'Эвакуатор Команда'), '@org_manager', 'manager');
select am_staff_add((select id from am_providers where name = 'Эвакуатор Команда'), 'org_master', 'master');
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select pg_temp.expect_fail($$select am_staff_add((select id from am_providers where name = 'Эвакуатор Команда'), 'cli6', 'manager')$$, 'менеджер не добавляет сотрудников');
select 'менеджер видит свои организации: ' || count(*) || ' роль ' || max(my_role) from am_my_orgs();
-- менеджер принимает заявку клиента; кто принял — записано
select am_accept_request((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204'), (select id from am_providers where name = 'Эвакуатор Команда'));
select 'принял менеджер: ' || (handled_by = '00000000-0000-0000-0000-000000000202') from am_requests where id = (select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204');
select 'контакт менеджеру: ' || (select count(*) from am_client_contact((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204')));
-- мастер до поручения ничего не видит
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select 'мастер видит до поручения: ' || count(*) from am_provider_feed((select id from am_providers where name = 'Эвакуатор Команда'));
select pg_temp.expect_fail($$select am_accept_request(1, (select id from am_providers where name = 'Эвакуатор Команда'))$$, 'мастер не принимает заявки');
select pg_temp.expect_fail($$select am_complete_request((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204'), (select id from am_providers where name = 'Эвакуатор Команда'), 1)$$, 'мастер не завершает чужую');
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select am_assign_request((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204'), '00000000-0000-0000-0000-000000000203');
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select 'мастер видит порученную: ' || count(*) from am_provider_feed((select id from am_providers where name = 'Эвакуатор Команда'));
select (am_send_message((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204'), 'Мастер выехал')).from_provider;
select am_complete_request((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204'), (select id from am_providers where name = 'Эвакуатор Команда'), 9000);
select 'статус: ' || status from am_requests where id = (select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204');
-- пауза: новые заявки не приходят
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
update am_providers set paused = true, days_off = '{0}' where name = 'Эвакуатор Команда';
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select am_create_request('{"type":"tow","city":"Талдыкорган","description":"после паузы"}');
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select 'на паузе видно новых: ' || count(*) from am_provider_feed((select id from am_providers where name = 'Эвакуатор Команда')) where description = 'после паузы';
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select 'сотрудники: ' || string_agg(role || '=' || handled, ',' order by role) from am_staff_list((select id from am_providers where name = 'Эвакуатор Команда'));
select am_staff_remove((select id from am_providers where name = 'Эвакуатор Команда'), '00000000-0000-0000-0000-000000000202');
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select pg_temp.expect_fail($$select am_provider_feed((select id from am_providers where name = 'Эвакуатор Команда'))$$, 'удалённый менеджер без доступа');
-- журнал
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select 'журнал регионала: ' || string_agg(distinct action, ',') from am_admin_log;
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select 'журнал клиента: ' || count(*) from am_admin_log;
reset role; set role anon; select pg_temp.as_user(null);
select 'гость читает объявление города: ' || (am_setting('city_notice', 'Талдыкорган') #>> '{}');
reset role;
select 'ADMIN TESTS PASSED';
