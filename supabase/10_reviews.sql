-- =====================================================================
--  АвтоМастер24 — Обновление 7: отзывы по закону (ст. 11, 13, 15, 16 Закона РК
--  «Об онлайн-платформах и онлайн-рекламе», ст. 143 ГК, ст. 7 Закона «О рекламе»).
--  1) рейтинг — только по опубликованным отзывам;
--  2) модератор не стирает отзыв, а скрывает с пунктом правил; всё пишется в журнал;
--  3) скрытие на время проверки жалобы, удаление — только после скрытия (подтверждение);
--  4) автор может удалить свой отзыв или исправить его в течение 30 дней;
--  5) владелец и сотрудники не могут оценивать свою организацию;
--  6) годовой отчёт о модерации отзывов (am_transparency);
--  7) автоматическая отметка «возможны персональные данные» (телефон, госномер, ИИН, e-mail).
--  Применять после 08_admin.sql и 09_roles_fix.sql. Только am_*, повторный запуск безопасен.
-- =====================================================================

alter table am_reviews add column if not exists hidden_at timestamptz;
alter table am_reviews add column if not exists hidden_rule text;
alter table am_reviews add column if not exists hidden_reason text;
alter table am_reviews add column if not exists hidden_by uuid references am_profiles(id) on delete set null;
alter table am_reviews add column if not exists edited_at timestamptz;
alter table am_reviews add column if not exists pii_flag boolean not null default false;
create index if not exists am_reviews_moder_idx on am_reviews(is_published, hidden_at);

-- пункты правил отзывов (legal/reviews.html), по которым можно скрыть отзыв
create or replace function am_review_rule_name(p_rule text) returns text
language sql immutable set search_path = public as $$
  select case p_rule
    when 'insult'  then 'п. 3.1 — оскорбления, нецензурная лексика, угрозы, дискриминация'
    when 'false'   then 'п. 3.2 — заведомо ложные утверждения о фактах'
    when 'pii'     then 'п. 3.3 — персональные данные'
    when 'ads'     then 'п. 3.4 — реклама, ссылки, призывы к другому исполнителю'
    when 'fake'    then 'п. 3.5 — отзыв за вознаграждение, от сотрудника или конкурента'
    when 'illegal' then 'п. 3.6 — противоправный контент'
    when 'hold'    then 'п. 5 — скрыт на время проверки жалобы'
    else null end;
$$;
grant execute on function am_review_rule_name(text) to anon, authenticated;

-- возможные персональные данные в тексте: телефон, госномер РК, ИИН/БИН, e-mail
create or replace function am_text_has_pii(t text) returns boolean
language sql immutable set search_path = public as $$
  select coalesce(t, '') ~* '(\+?[78][\s\-\(\)]*)?\d{3}[\s\-\)]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}'
      or coalesce(t, '') ~* '\m\d{3}\s?[a-zа-я]{2,3}\s?\d{2}\M'
      or coalesce(t, '') ~* '\m\d{12}\M'
      or coalesce(t, '') ~* '[^\s@]+@[^\s@]+\.[a-z]{2,}';
$$;
grant execute on function am_text_has_pii(text) to anon, authenticated;

create or replace function am_reviews_pii() returns trigger
language plpgsql set search_path = public as $$
begin
  new.pii_flag := am_text_has_pii(new.comment) or am_text_has_pii(new.reply);
  return new;
end $$;
drop trigger if exists am_reviews_pii on am_reviews;
create trigger am_reviews_pii before insert or update of comment, reply on am_reviews for each row execute function am_reviews_pii();
update am_reviews set comment = comment where not pii_flag and (am_text_has_pii(comment) or am_text_has_pii(reply));

-- 1) рейтинг — среднее опубликованных оценок
create or replace function am_recalc_rating(p_provider int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('am.sys', 'on', true);
  update am_providers set
    rating = coalesce((select round(avg(rating)::numeric, 2) from am_reviews where provider_id = p_provider and is_published), 0),
    reviews_count = (select count(*) from am_reviews where provider_id = p_provider and is_published)
  where id = p_provider;
  perform set_config('am.sys', '', true);
end $$;
revoke execute on function am_recalc_rating(int) from public, anon, authenticated;

-- проверка: текущий пользователь — админ города организации отзыва (NULL → false)
create or replace function am_review_admin(p_review bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select am_is_admin(am_provider_city(provider_id)) from am_reviews where id = p_review), false);
$$;
revoke execute on function am_review_admin(bigint) from public, anon;
grant execute on function am_review_admin(bigint) to authenticated;

-- 2–3) решение модератора: publish | hide | hold | delete (delete — только уже скрытого)
create or replace function am_review_decide(p_id bigint, p_action text, p_rule text default null, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews; city text;
begin
  select * into rv from am_reviews where id = p_id;
  if not found then raise exception 'Отзыв не найден'; end if;
  city := am_provider_city(rv.provider_id);
  if auth.uid() is null or not coalesce(am_is_admin(city), false) then raise exception 'Нет прав'; end if;
  if p_action = 'publish' then
    update am_reviews set is_published = true, hidden_at = null, hidden_rule = null, hidden_reason = null, hidden_by = null where id = p_id;
  elsif p_action in ('hide', 'hold') then
    if p_action = 'hold' then p_rule := 'hold'; end if;
    if am_review_rule_name(p_rule) is null then raise exception 'Укажите пункт правил'; end if;
    update am_reviews set is_published = false, hidden_at = now(), hidden_rule = p_rule,
      hidden_reason = nullif(left(trim(coalesce(p_reason, '')), 500), ''), hidden_by = auth.uid() where id = p_id;
  elsif p_action = 'delete' then
    if rv.hidden_at is null then raise exception 'Сначала скройте отзыв (удаление — после проверки)'; end if;
    if coalesce(trim(p_reason), '') = '' then raise exception 'Укажите основание удаления'; end if;
    delete from am_reviews where id = p_id;
  else raise exception 'Неизвестное действие';
  end if;
  perform am_log('review', rv.user_id, city, jsonb_build_object('review', p_id, 'provider', rv.provider_id, 'action', p_action,
    'rule', case when p_action in ('hide','hold') then p_rule when p_action = 'delete' then rv.hidden_rule end,
    'reason', nullif(left(trim(coalesce(p_reason, '')), 200), ''), 'test', am_provider_is_test(rv.provider_id)));
  perform am_recalc_rating(rv.provider_id);
end $$;
revoke execute on function am_review_decide(bigint, text, text, text) from public, anon;
grant execute on function am_review_decide(bigint, text, text, text) to authenticated;

-- старая функция больше не стирает отзыв: «отказ» = скрыть по правилам
create or replace function am_moderate_review(p_id bigint, p_publish boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_publish then perform am_review_decide(p_id, 'publish');
  else perform am_review_decide(p_id, 'hide', 'insult', 'Нарушение правил отзывов'); end if;
end $$;
revoke execute on function am_moderate_review(bigint, boolean) from public, anon;
grant execute on function am_moderate_review(bigint, boolean) to authenticated;

-- 4) автор: удалить свой отзыв / исправить в течение 30 дней
create or replace function am_delete_my_review(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or auth.uid() is null or rv.user_id is distinct from auth.uid() then raise exception 'Это не ваш отзыв'; end if;
  delete from am_reviews where id = p_id;
  perform am_recalc_rating(rv.provider_id);
end $$;
revoke execute on function am_delete_my_review(bigint) from public, anon;
grant execute on function am_delete_my_review(bigint) to authenticated;

create or replace function am_edit_my_review(p_id bigint, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews; c text := left(trim(coalesce(p_comment, '')), 1000);
begin
  select * into rv from am_reviews where id = p_id;
  if not found or auth.uid() is null or rv.user_id is distinct from auth.uid() then raise exception 'Это не ваш отзыв'; end if;
  if am_is_blocked(auth.uid()) then raise exception 'Аккаунт заблокирован администратором'; end if;
  if rv.created_at < now() - interval '30 days' then raise exception 'Исправить отзыв можно в течение 30 дней. Можно удалить его.'; end if;
  if rv.hidden_rule = 'hold' then raise exception 'Отзыв на проверке по жалобе — исправить можно после решения'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Оценка от 1 до 5'; end if;
  update am_reviews set rating = p_rating, comment = c, edited_at = now(), is_published = (c = ''),
    hidden_at = null, hidden_rule = null, hidden_reason = null, hidden_by = null where id = p_id;
  perform am_recalc_rating(rv.provider_id);
end $$;
revoke execute on function am_edit_my_review(bigint, int, text) from public, anon;
grant execute on function am_edit_my_review(bigint, int, text) to authenticated;

-- 5) отзыв: только клиент выполненной заявки и не владелец/сотрудник этой организации
create or replace function am_leave_review(p_id bigint, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id); c text := left(trim(coalesce(p_comment, '')), 1000);
begin
  if r.status <> 'completed' or r.accepted_by is null then raise exception 'Оценить можно только выполненную заявку'; end if;
  if exists (select 1 from am_providers where id = r.accepted_by and owner_id = auth.uid())
     or exists (select 1 from am_provider_staff where provider_id = r.accepted_by and user_id = auth.uid()) then
    raise exception 'Нельзя оценивать свою организацию (п. 3.5 правил отзывов)'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Оценка от 1 до 5'; end if;
  insert into am_reviews(user_id, provider_id, request_id, rating, comment, is_published)
  values (auth.uid(), r.accepted_by, r.id, p_rating, c, c = '')
  on conflict (request_id) do nothing;
  perform am_recalc_rating(r.accepted_by);
end $$;
revoke execute on function am_leave_review(bigint, int, text) from public, anon;
grant execute on function am_leave_review(bigint, int, text) to authenticated;

-- счётчик «на модерации» в админке: только ожидающие решения и только в своём городе
create or replace function am_admin_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(am_is_admin(), false) then raise exception 'Нет прав'; end if;
  return jsonb_build_object(
    'users', (select count(*) from am_profiles),
    'providers', (select count(*) from am_providers where am_is_admin(city)),
    'requests', (select count(*) from am_requests where am_is_admin(city)),
    'completed', (select count(*) from am_requests where am_is_admin(city) and status = 'completed'),
    'active', (select count(*) from am_requests where am_is_admin(city) and status in ('new','offers','active','price_offered','client_approved','in_progress','waiting_client','delivered')),
    'pending_regs', (select count(*) from am_registrations where am_is_admin(city) and status = 'pending'),
    'pending_reviews', (select count(*) from am_reviews where not is_published and hidden_at is null and am_is_admin(am_provider_city(provider_id))),
    'turnover', (select coalesce(sum(final_amount),0) from am_requests where am_is_admin(city) and status = 'completed'));
end $$;

-- 6) отчёт о прозрачности: + модерация отзывов за 12 месяцев (без тестовых данных)
create or replace function am_transparency() returns jsonb
language sql stable security definer set search_path = public as $$
  with lg as (select details from am_admin_log where action = 'review' and created_at > now() - interval '1 year'
              and not coalesce((details->>'test')::boolean, false)),
       rv as (select r.* from am_reviews r where not am_provider_is_test(r.provider_id))
  select jsonb_build_object(
    'generated_at', now(),
    'monthly', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'visitors', v, 'avg_daily', a) order by m desc)
      from (select to_char(date_trunc('month', day), 'YYYY-MM') m, sum(visitors) v, round(avg(visitors)) a
            from am_daily_visits where day >= (date_trunc('month', now()) - interval '5 months')::date group by 1) s), '[]'),
    'registered_users', (select count(*) from am_profiles where deleted_at is null and not is_test),
    'providers_active', (select count(*) from am_providers where is_active and not is_test),
    'complaints_total', (select count(*) from am_complaints c where created_at > now() - interval '1 year'
                           and not coalesce((select is_test from am_profiles where id = c.user_id), false) and coalesce(c.contact,'') not like '%@am24.test'),
    'complaints_resolved', (select count(*) from am_complaints c where status in ('resolved','rejected') and created_at > now() - interval '1 year'
                           and not coalesce((select is_test from am_profiles where id = c.user_id), false) and coalesce(c.contact,'') not like '%@am24.test'),
    'complaints_overdue', (select count(*) from am_complaints c where status in ('new','in_review') and due_at < now()
                           and not coalesce((select is_test from am_profiles where id = c.user_id), false) and coalesce(c.contact,'') not like '%@am24.test'),
    'complaints_reviews', (select count(*) from am_complaints c where target_type = 'review' and created_at > now() - interval '1 year'
                           and not coalesce((select is_test from am_profiles where id = c.user_id), false) and coalesce(c.contact,'') not like '%@am24.test'),
    'reviews_published', (select count(*) from rv where is_published),
    'reviews_pending', (select count(*) from rv where not is_published and hidden_at is null),
    'reviews_hidden', (select count(*) from rv where not is_published and hidden_at is not null),
    'reviews_pii_flagged', (select count(*) from rv where pii_flag),
    'reviews_hidden_by_rule', coalesce((select jsonb_object_agg(k, n) from (select details->>'rule' k, count(*) n from lg
                              where details->>'action' in ('hide','hold') and details->>'rule' is not null group by 1) s), '{}'),
    'reviews_deleted_by_moderator', (select count(*) from lg where details->>'action' = 'delete'),
    'reviews_restored', (select count(*) from lg where details->>'action' = 'publish')
  );
$$;
grant execute on function am_transparency() to anon, authenticated;

-- пересчитать рейтинги по новому правилу
do $$ declare x int; begin for x in select id from am_providers loop perform am_recalc_rating(x); end loop; end $$;

notify pgrst, 'reload schema';
