-- Тест обновления 4 (правовое). Локально, не запускать в Supabase.
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u, 'role','authenticated')::text end, false) $$;
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select 'принято: ' || (am_accept_legal(array['pd','cross_border','terms','age18'], '2026-10-26', 'test-ua')).legal_version;
select 'записей в журнале: ' || count(*) from am_consents where user_id = '00000000-0000-0000-0000-00000000000c';
select 'обращение: ' || (am_submit_complaint('review', '1', 'Оскорбление', 'В отзыве есть оскорбления', '', 'ru') ->> 'status');
select 'срок 20 дней: ' || ((due_at - created_at) = interval '20 days') from am_complaints order by id desc limit 1;
select 'export keys: ' || (select string_agg(k, ',' order by k) from jsonb_object_keys(am_export_my_data()) k);
-- аноним
reset role; set role anon; select pg_temp.as_user(null);
do $$ begin perform am_submit_complaint('platform', '', '', 'Без контакта нельзя', '', 'ru'); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK аноним без контакта: %', sqlerrm; end $$;
select 'аноним с контактом: ' || (am_submit_complaint('platform', '', '', 'Жалоба гостя на сайт', '+77001112233', 'kk') ->> 'status');
select am_hit(); select am_hit();
select 'визиты: ' || visitors from am_daily_visits;
select 'прозрачность: ' || (am_transparency() ->> 'complaints_total');
do $$ begin perform 1 from am_complaints; raise notice 'аноним видит обращений: %', (select count(*) from am_complaints); end $$;
do $$ begin perform am_export_my_data(); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK аноним без выгрузки: %', sqlerrm; end $$;
reset role; set role authenticated;
-- чужой не видит чужие обращения; клиент не отвечает
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select 'чужой видит обращений: ' || count(*) from am_complaints;
do $$ begin perform am_answer_complaint(1, 'resolved', 'x'); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK не-админ не отвечает: %', sqlerrm; end $$;
-- админ отвечает
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
do $$ begin perform am_answer_complaint(1, 'resolved', ''); raise exception 'FAIL'; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK без мотивировки нельзя: %', sqlerrm; end $$;
select am_answer_complaint(1, 'resolved', 'Отзыв скрыт как нарушающий правила');
select 'статус: ' || status from am_complaints where id = 1;
-- отзыв согласия и удаление
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select am_withdraw_consent('ua');
select 'после отзыва consent=' || consent || ' phone=' || coalesce(phone,'null') from am_profiles where id = '00000000-0000-0000-0000-00000000000c';
select am_delete_my_account('ua');
select 'после удаления: ' || full_name || ' tg=' || coalesce(tg_id::text,'null') || ' авто=' || (select count(*) from am_vehicles where user_id = '00000000-0000-0000-0000-00000000000c') from am_profiles where id = '00000000-0000-0000-0000-00000000000c';
select 'сообщения обезличены: ' || bool_and(body = '[удалено]') from am_messages where sender_id = '00000000-0000-0000-0000-00000000000c';
reset role;
select 'LEGAL TESTS PASSED';
