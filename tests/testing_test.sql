-- Тест обновления 5 (изоляция тестовых аккаунтов). Локально, не запускать в Supabase.
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u, 'role','authenticated')::text end, false) $$;
insert into auth.users(id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000101', 'test_client_1@am24.test', '{"username":"test_client_1","first_name":"ТЕСТ Клиент"}'),
  ('00000000-0000-0000-0000-000000000102', 'test_sto_1@am24.test',    '{"username":"test_sto_1","first_name":"ТЕСТ СТО"}'),
  ('00000000-0000-0000-0000-000000000103', 'real@example.com',        '{"username":"real_client","first_name":"Реальный"}');
set role authenticated;
-- тестовый мастер подаёт заявку на организацию, админ одобряет
select pg_temp.as_user('00000000-0000-0000-0000-000000000102');
select 'тестовый профиль: ' || (am_ensure_profile()).is_test;
select am_register_business('{"kind":"sto","name":"ТЕСТ СТО изоляция","phone":"+77010009999","city":"Талдыкорган"}');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select am_review_registration((select max(id) from am_registrations), true, null);
select 'организация тестовая: ' || is_test from am_providers where name = 'ТЕСТ СТО изоляция';
-- владелец не может снять флаг
select pg_temp.as_user('00000000-0000-0000-0000-000000000102');
update am_providers set is_test = false where name = 'ТЕСТ СТО изоляция';
do $$ begin if not (select is_test from am_providers where name = 'ТЕСТ СТО изоляция') then raise exception 'FAIL флаг снят'; end if; raise notice 'OK владелец не снимает флаг'; end $$;
-- видимость в каталоге
reset role; set role anon; select pg_temp.as_user(null);
do $$ begin if exists (select 1 from am_providers where name = 'ТЕСТ СТО изоляция') then raise exception 'FAIL гость видит тест'; end if; raise notice 'OK гость не видит тестовую организацию'; end $$;
reset role; set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-000000000103');
select (am_update_profile('Реальный', '+7 701 555 44 33', 'Талдыкорган', true)).city;
do $$ begin if exists (select 1 from am_providers where name = 'ТЕСТ СТО изоляция') then raise exception 'FAIL реальный видит тест'; end if; raise notice 'OK реальный клиент не видит тестовую организацию'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select (am_update_profile('ТЕСТ Клиент', '+7 701 000 00 01', 'Талдыкорган', true)).city;
do $$ begin if not exists (select 1 from am_providers where name = 'ТЕСТ СТО изоляция') then raise exception 'FAIL тестовый не видит тест'; end if; raise notice 'OK тестовый клиент видит тестовую организацию'; end $$;
-- адресовать реальной организации нельзя
do $$ begin perform am_create_request(jsonb_build_object('type','sto','city','Талдыкорган','target_provider_id', (select id from am_providers where not is_test and kind='sto' limit 1)));
  raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK тест → реальному нельзя: %', sqlerrm; end $$;
-- заявки расходятся по «мирам»
select am_create_request('{"type":"sto","city":"Талдыкорган","description":"ТЕСТ заявка"}');
select pg_temp.as_user('00000000-0000-0000-0000-000000000103');
select am_create_request('{"type":"sto","city":"Талдыкорган","description":"Реальная заявка"}');
select pg_temp.as_user('00000000-0000-0000-0000-000000000102');
do $$ declare pid int := (select id from am_providers where name = 'ТЕСТ СТО изоляция'); begin
  if exists (select 1 from am_provider_feed(pid) where description = 'Реальная заявка') then raise exception 'FAIL тест-СТО видит реальную'; end if;
  if not exists (select 1 from am_provider_feed(pid) where description = 'ТЕСТ заявка') then raise exception 'FAIL тест-СТО не видит тестовую'; end if;
  raise notice 'OK тестовое СТО видит только тестовые заявки'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ declare pid int := (select id from am_providers where owner_id = '00000000-0000-0000-0000-00000000000b' and kind='sto' and is_active limit 1); begin
  if pid is null then raise notice 'нет активного реального СТО — пропуск'; return; end if;
  if exists (select 1 from am_provider_feed(pid) where description = 'ТЕСТ заявка') then raise exception 'FAIL реальное СТО видит тестовую'; end if;
  if exists (select 1 from am_requests where description = 'ТЕСТ заявка') then raise exception 'FAIL реальное СТО читает тестовую'; end if;
  raise notice 'OK реальное СТО не видит тестовые заявки'; end $$;
reset role; set role anon; select pg_temp.as_user(null);
select 'прозрачность без тестов: ' || ((am_transparency()->>'providers_active')::int = (select count(*) from am_providers where is_active and not is_test));
-- удаление аккаунта владельцем организации: организация отключается и отвязывается
select pg_temp.as_user('00000000-0000-0000-0000-000000000102');
select am_delete_my_account('test');
do $$ begin if (select is_active or owner_id is not null from am_providers where name = 'ТЕСТ СТО изоляция') then raise exception 'FAIL организация удалённого владельца активна'; end if; raise notice 'OK удаление владельца отключает организацию'; end $$;
reset role;
select 'очистка: ' || am_test_cleanup()::text;
do $$ begin if exists (select 1 from am_profiles where is_test) or exists (select 1 from am_requests where description = 'ТЕСТ заявка') or not exists (select 1 from am_requests where description = 'Реальная заявка') then raise exception 'FAIL очистка'; end if; raise notice 'OK очистка удалила только тестовое'; end $$;
-- антиспам: 11-я открытая заявка отклоняется
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000103');
do $$ declare i int; begin
  for i in 1..9 loop perform am_create_request('{"type":"tow","city":"Талдыкорган"}'); end loop;
  begin perform am_create_request('{"type":"tow","city":"Талдыкорган"}'); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK антиспам: %', sqlerrm; end;
end $$;
reset role;
-- региональный админ не может повысить себя и не правит чужие города/справочники
insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000104', 'reg@example.com', '{"username":"reg_admin"}');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000104'); select (am_ensure_profile()).username;
reset role; select pg_temp.as_user(null); select am_make_admin('reg_admin', 'Алматы'); set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-000000000104');
do $$ begin if not am_is_admin('Алматы') or am_is_admin('Талдыкорган') then raise exception 'FAIL регионал'; end if; raise notice 'OK регионал только в своём городе'; end $$;
do $$ begin perform am_make_admin('reg_admin', null); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK регионал не повышает себя: %', sqlerrm; end $$;
update am_cities set active = false where name = 'Талдыкорган';
do $$ begin if not (select active from am_cities where name = 'Талдыкорган') then raise exception 'FAIL регионал выключил город'; end if; raise notice 'OK регионал не меняет справочник городов'; end $$;
select 'TESTING ISOLATION PASSED';
