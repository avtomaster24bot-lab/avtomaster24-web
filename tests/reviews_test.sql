-- Тест 10_reviews.sql (локально, после admin_test и roles_fix_test). Не запускать в Supabase.
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u, 'role','authenticated')::text end, false) $$;
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL %', label; exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'OK %: %', label, sqlerrm; end $$;
create or replace function pg_temp.check(c boolean, label text) returns text language plpgsql as $$
begin if not coalesce(c, false) then raise exception 'FAIL %', label; end if; return 'OK ' || label; end $$;
select pg_temp.check(am_text_has_pii('звоните +7 701 123 45 67'), 'телефон найден'),
       pg_temp.check(am_text_has_pii('номер 123 ABC 05'), 'госномер найден'),
       pg_temp.check(not am_text_has_pii('всё отлично, 5 звёзд, 2 часа'), 'обычный текст без отметки');
create temp table t_ids(k text primary key, v bigint);
grant all on t_ids to authenticated, anon;
insert into t_ids select 'pid', id from am_providers where name = 'Эвакуатор Команда';
insert into t_ids select 'rid', max(id) from am_requests where user_id = '00000000-0000-0000-0000-000000000204' and status = 'completed';
select pg_temp.check((select v from t_ids where k = 'rid') is not null, 'есть выполненная заявка');
set role authenticated;
-- клиент 204 оставляет отзыв с телефоном → на модерации, в рейтинг не идёт
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select am_leave_review((select v from t_ids where k = 'rid'), 2, 'Плохо. Мастер дал свой номер 8 701 111 22 33');
insert into t_ids select 'rv', id from am_reviews where request_id = (select v from t_ids where k = 'rid');
select pg_temp.check((select pii_flag and not is_published from am_reviews where id = (select v from t_ids where k = 'rv')), 'отметка ПД и модерация');
reset role;
select pg_temp.check((select rating = 0 and reviews_count = 0 from am_providers where id = (select v from t_ids where k = 'pid')), 'неопубликованный не в рейтинге');
set role authenticated;
-- посторонний
select pg_temp.as_user('00000000-0000-0000-0000-000000000206');
select pg_temp.expect_fail($$select am_review_decide((select v from t_ids where k = 'rv'), 'publish')$$, 'посторонний не модерирует');
select pg_temp.expect_fail($$select am_moderate_review((select v from t_ids where k = 'rv'), true)$$, 'посторонний: старая функция');
select pg_temp.expect_fail($$select am_delete_my_review((select v from t_ids where k = 'rv'))$$, 'посторонний не удаляет чужой отзыв');
select pg_temp.expect_fail($$select am_edit_my_review((select v from t_ids where k = 'rv'), 5, 'взлом')$$, 'посторонний не правит');
select pg_temp.expect_fail($$select am_recalc_rating(1)$$, 'пересчёт рейтинга закрыт');
-- гость
reset role; set role anon; select pg_temp.as_user(null);
select pg_temp.expect_fail($$select am_review_decide(1, 'publish')$$, 'гость не модерирует');
reset role; set role authenticated;
-- регионал 205: скрыть на время проверки, автор не правит, удалить без основания нельзя
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select pg_temp.expect_fail($$select am_review_decide((select v from t_ids where k = 'rv'), 'hide', 'xxx')$$, 'без пункта правил');
select pg_temp.expect_fail($$select am_review_decide((select v from t_ids where k = 'rv'), 'delete', null, 'x')$$, 'удаление только после скрытия');
select am_review_decide((select v from t_ids where k = 'rv'), 'hold', null, 'Жалоба №1');
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select pg_temp.check((select hidden_rule = 'hold' from am_reviews where id = (select v from t_ids where k = 'rv')), 'автор видит причину скрытия');
select pg_temp.expect_fail($$select am_edit_my_review((select v from t_ids where k = 'rv'), 3, 'исправил')$$, 'на проверке не правится');
select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select pg_temp.expect_fail($$select am_review_decide((select v from t_ids where k = 'rv'), 'delete')$$, 'удаление без основания');
select am_review_decide((select v from t_ids where k = 'rv'), 'delete', null, 'Подтверждено: персональные данные');
select pg_temp.check(not exists (select 1 from am_reviews where id = (select v from t_ids where k = 'rv')), 'удалён после проверки');
select pg_temp.check(exists (select 1 from am_admin_log where action = 'review' and details->>'action' = 'delete'), 'удаление в журнале');
-- автор снова оценивает (только оценка → сразу), правит, удаляет
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select am_leave_review((select v from t_ids where k = 'rid'), 4, '');
update t_ids set v = (select id from am_reviews where request_id = (select v from t_ids where k = 'rid')) where k = 'rv';
reset role;
select pg_temp.check((select rating = 4 and reviews_count = 1 from am_providers where id = (select v from t_ids where k = 'pid')), 'опубликованная оценка в рейтинге');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select am_edit_my_review((select v from t_ids where k = 'rv'), 5, 'Исправил: всё хорошо');
reset role;
select pg_temp.check((select not is_published and edited_at is not null from am_reviews where id = (select v from t_ids where k = 'rv')), 'исправленный текст — на модерацию');
select pg_temp.check((select reviews_count = 0 from am_providers where id = (select v from t_ids where k = 'pid')), 'на модерации — не в рейтинге');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select am_moderate_review((select v from t_ids where k = 'rv'), false);
select pg_temp.check((select hidden_at is not null from am_reviews where id = (select v from t_ids where k = 'rv')), 'старая функция скрывает, а не стирает');
select am_review_decide((select v from t_ids where k = 'rv'), 'publish');
reset role;
select pg_temp.check((select rating = 5 and reviews_count = 1 from am_providers where id = (select v from t_ids where k = 'pid')), 'после публикации рейтинг 5');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select am_delete_my_review((select v from t_ids where k = 'rv'));
reset role;
select pg_temp.check((select reviews_count = 0 from am_providers where id = (select v from t_ids where k = 'pid')), 'автор удалил — рейтинг пересчитан');
-- сотрудник (мастер 203) не оценивает свою организацию
update am_providers set paused = false where id = (select v from t_ids where k = 'pid');
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
insert into t_ids select 'r2', am_create_request('{"type":"tow","city":"Талдыкорган","description":"сам себе"}');
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select am_accept_request((select v from t_ids where k = 'r2'), (select v::int from t_ids where k = 'pid'));
select am_complete_request((select v from t_ids where k = 'r2'), (select v::int from t_ids where k = 'pid'), 1000);
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select pg_temp.expect_fail($$select am_leave_review((select v from t_ids where k = 'r2'), 5, '')$$, 'сотрудник не оценивает свою организацию');
-- отчёт
reset role; set role anon;
select pg_temp.check((am_transparency() ? 'reviews_hidden_by_rule') and (am_transparency() ? 'reviews_deleted_by_moderator'), 'отчёт с модерацией отзывов');
reset role;
select 'REVIEWS TESTS PASSED';
