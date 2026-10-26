-- Тест 09_roles_fix.sql: посторонний пользователь (клиент 204, не сотрудник) получает отказ везде. Локально.
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u, 'role','authenticated')::text end, false) $$;
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL %', label; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK %: %', label, sqlerrm; end $$;
insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000206', 'out@example.com', '{"username":"outsider6","first_name":"Посторонний"}') on conflict do nothing;
set role authenticated;
-- посторонний: пользователь без роли в организации и без админских прав
select pg_temp.as_user('00000000-0000-0000-0000-000000000206'); select am_ensure_profile() is not null;
select pg_temp.expect_fail($$select * from am_staff_list((select id from am_providers where name = 'Эвакуатор Команда'))$$, 'посторонний: список сотрудников');
select pg_temp.expect_fail($$select am_staff_remove((select id from am_providers where name = 'Эвакуатор Команда'), '00000000-0000-0000-0000-000000000203')$$, 'посторонний: удалить сотрудника');
select pg_temp.expect_fail($$select * from am_client_contact((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204' and accepted_by is not null))$$, 'посторонний: телефон клиента');
select pg_temp.expect_fail($$select * from am_request_staff((select max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204' and accepted_by is not null))$$, 'посторонний: кто принял');
select pg_temp.expect_fail($$select am_assign_request((select max(id) from am_requests where accepted_by = (select id from am_providers where name = 'Эвакуатор Команда') and status not in ('completed','cancelled')), null)$$, 'посторонний: поручение');
select pg_temp.expect_fail($$select am_reply_review((select max(id) from am_reviews), 'взлом')$$, 'посторонний: ответ на отзыв');
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select 'мастер в составе: ' || count(*) from am_provider_staff where user_id = '00000000-0000-0000-0000-000000000203';
reset role;
select 'ROLES FIX TESTS PASSED';
