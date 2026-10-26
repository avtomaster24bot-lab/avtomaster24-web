-- АвтоМастер24 — Обновление 5: изоляция тестовых аккаунтов на боевой базе.
-- Только добавления (колонки, функции, триггеры) и замена политик am_* таблиц. Чужие таблицы не трогаются.
-- Идея: тестовые пользователи (e-mail …@am24.test) и их организации помечены is_test.
--   * обычные посетители НЕ видят тестовые организации, их цены и отзывы;
--   * заявки тестовых клиентов уходят только тестовым исполнителям, а реальные — только реальным;
--   * am_test_cleanup() удаляет все тестовые данные одной командой (запускается только из SQL Editor).

alter table am_profiles  add column if not exists is_test boolean not null default false;
alter table am_providers add column if not exists is_test boolean not null default false;

create or replace function am_provider_city(p_id int) returns text
language sql stable security definer set search_path = public as $$ select city from am_providers where id = p_id $$;

-- текущий пользователь — тестовый?
create or replace function am_viewer_is_test() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_test from am_profiles where id = auth.uid()), false);
$$;
grant execute on function am_viewer_is_test() to anon, authenticated;

-- пометка профиля: только по e-mail в зарезервированном домене .test (подделать через Telegram нельзя)
create or replace function am_profiles_mark_test() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  new.is_test := coalesce(new.is_test, false)
    or exists (select 1 from auth.users u where u.id = new.id and u.email like '%@am24.test');
  return new;
end $$;
drop trigger if exists am_profiles_mark_test on am_profiles;
create trigger am_profiles_mark_test before insert on am_profiles for each row execute function am_profiles_mark_test();
update am_profiles p set is_test = true
  from auth.users u where u.id = p.id and u.email like '%@am24.test' and not p.is_test;

-- организация тестового владельца — тоже тестовая; владелец сам флаг не меняет
create or replace function am_providers_mark_test() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.is_test := coalesce(new.is_test, false)
      or coalesce((select is_test from am_profiles where id = new.owner_id), false);
  elsif new.is_test is distinct from old.is_test and not am_is_admin() then
    new.is_test := old.is_test;
  end if;
  return new;
end $$;
drop trigger if exists am_providers_mark_test on am_providers;
create trigger am_providers_mark_test before insert or update on am_providers for each row execute function am_providers_mark_test();
update am_providers p set is_test = true from am_profiles o where o.id = p.owner_id and o.is_test and not p.is_test;

-- каталог: тестовые организации видят только тестовые пользователи, владелец и админы
drop policy if exists "public active" on am_providers;
create policy "public active" on am_providers for select using (
  (is_active and (not is_test or am_viewer_is_test())) or owner_id = auth.uid() or am_is_admin(city));

drop policy if exists "read" on am_prices;
create policy "read" on am_prices for select using (
  provider_id is null or not exists (select 1 from am_providers p where p.id = provider_id and p.is_test)
  or am_viewer_is_test() or am_is_admin());

drop policy if exists "published or own" on am_reviews;
create policy "published or own" on am_reviews for select using (
  (is_published and (not exists (select 1 from am_providers p where p.id = provider_id and p.is_test) or am_viewer_is_test()))
  or user_id = auth.uid() or am_is_admin(am_provider_city(provider_id)));

-- подбор исполнителей: тестовые заявки ↔ тестовые исполнители, реальные ↔ реальные
create or replace function am_matches(r am_requests, p am_providers) returns boolean
language sql stable security definer set search_path = public as $$
  select p.is_active and p.kind = r.type and p.city = r.city
    and p.is_test = coalesce((select pr.is_test from am_profiles pr where pr.id = r.user_id), false)
    and (r.target_provider_id is null or r.target_provider_id = p.id)
    and (r.type <> 'urgent' or r.service_type is null or r.service_type = p.service_type)
    and (r.type <> 'parts' or r.supplier_type is null or r.supplier_type = p.supplier_type)
    and (r.type <> 'sto' or r.category_id is null or cardinality(p.specs) = 0 or r.category_id = any(p.specs) or r.target_provider_id = p.id);
$$;

-- заявку «конкретному исполнителю» нельзя адресовать организации из другого мира (тест ↔ реальный)
create or replace function am_requests_test_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_provider_id is not null and
     coalesce((select is_test from am_providers where id = new.target_provider_id), false)
       <> coalesce((select is_test from am_profiles where id = new.user_id), false) then
    raise exception 'Исполнитель недоступен';
  end if;
  return new;
end $$;
drop trigger if exists am_requests_test_guard on am_requests;
create trigger am_requests_test_guard before insert on am_requests for each row execute function am_requests_test_guard();

-- защита от спама заявками: не больше 10 открытых и 20 новых за час на одного пользователя
create or replace function am_requests_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from am_requests where user_id = new.user_id and status in ('new','offers')
        and (expires_at is null or expires_at > now())) >= 10 then
    raise exception 'Слишком много открытых заявок — дождитесь ответа или отмените лишние';
  end if;
  if (select count(*) from am_requests where user_id = new.user_id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Слишком много заявок за час — попробуйте позже';
  end if;
  return new;
end $$;
drop trigger if exists am_requests_rate_limit on am_requests;
create trigger am_requests_rate_limit before insert on am_requests for each row execute function am_requests_rate_limit();

-- публичная статистика — без тестовых данных
create or replace function am_transparency() returns jsonb
language sql stable security definer set search_path = public as $$
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
    'reviews_published', (select count(*) from am_reviews r where is_published and not exists (select 1 from am_providers p where p.id = r.provider_id and p.is_test)),
    'reviews_hidden', (select count(*) from am_reviews r where not is_published and not exists (select 1 from am_providers p where p.id = r.provider_id and p.is_test))
  );
$$;
grant execute on function am_transparency() to anon, authenticated;


-- ======================================================================
-- Безопасность: региональный админ действует только в своём городе
-- (найдено при тестировании: через am_make_admin региональный админ мог сделать себя глобальным)
-- ======================================================================
create or replace function am_is_global_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from am_profiles where id = auth.uid() and role = 'global_admin');
$$;
grant execute on function am_is_global_admin() to anon, authenticated;

create or replace function am_make_admin(p_username text, p_city text default null) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not am_is_global_admin() then raise exception 'Нет прав'; end if;
  update am_profiles set role = case when p_city is null then 'global_admin' else 'regional_admin' end, managed_city = p_city
  where lower(username) = lower(trim(leading '@' from p_username));
  get diagnostics n = row_count;
  return case when n = 0 then 'Пользователь не найден: сначала войдите на сайт через Telegram' else 'Готово' end;
end $$;
revoke execute on function am_make_admin(text, text) from anon;


create or replace function am_moderate_review(p_id bigint, p_publish boolean) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or not am_is_admin(am_provider_city(rv.provider_id)) then raise exception 'Нет прав'; end if;
  if p_publish then update am_reviews set is_published = true where id = p_id;
  else delete from am_reviews where id = p_id; perform am_recalc_rating(rv.provider_id); end if;
end $$;

create or replace function am_reply_review(p_id bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or not (am_owns(rv.provider_id) or am_is_admin(am_provider_city(rv.provider_id))) then raise exception 'Нет прав'; end if;
  update am_reviews set reply = nullif(left(trim(coalesce(p_text,'')), 1000), ''), reply_at = now() where id = p_id;
end $$;
revoke execute on function am_reply_review(bigint, text) from anon;

create or replace function am_can_edit_prov_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when split_part(p_name, '/', 1) = 'prov' and split_part(p_name, '/', 2) ~ '^\d{1,9}$'
    then am_owns(split_part(p_name, '/', 2)::int) or am_is_admin(am_provider_city(split_part(p_name, '/', 2)::int)) else false end;
$$;

-- справочники (города, категории, марки) меняет только глобальный админ
do $$ declare t text; begin
  foreach t in array array['am_cities','am_categories','am_subcategories','am_price_services','am_brands','am_models'] loop
    execute format('drop policy if exists "admin write" on %I', t);
    execute format('create policy "admin write" on %I for all to authenticated using (am_is_global_admin()) with check (am_is_global_admin())', t);
  end loop;
end $$;

drop policy if exists "owner write" on am_prices;
create policy "owner write" on am_prices for all to authenticated
  using ((provider_id is not null and (am_owns(provider_id) or am_is_admin(am_provider_city(provider_id)))) or (provider_id is null and am_is_global_admin()))
  with check ((provider_id is not null and (am_owns(provider_id) or am_is_admin(am_provider_city(provider_id)))) or (provider_id is null and am_is_global_admin()));

drop policy if exists "provider or admin" on am_offers;
create policy "provider or admin" on am_offers for select to authenticated using (am_owns(provider_id) or am_is_admin(am_provider_city(provider_id)));

-- журнал согласий (персональные данные) — только глобальный админ
drop policy if exists "own or admin" on am_consents;
create policy "own or admin" on am_consents for select to authenticated using (user_id = auth.uid() or am_is_global_admin());

-- Исправление: при удалении аккаунта владельца организация не отключалась
-- (защитный триггер возвращал owner_id/is_active). Теперь служебное изменение проходит.
create or replace function am_providers_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin(old.city) and coalesce(current_setting('am.sys', true), '') <> 'on' then
    new.owner_id := old.owner_id; new.kind := old.kind; new.rating := old.rating;
    new.reviews_count := old.reviews_count; new.is_active := old.is_active; new.city := old.city;
    new.verified := old.verified;
  end if;
  new.about := left(coalesce(new.about, ''), 2000);
  if cardinality(new.photos) > 12 then new.photos := new.photos[1:12]; end if;
  return new;
end $$;

create or replace function am_delete_my_account(p_ua text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); auth_deleted boolean := false;
begin
  if u is null then raise exception 'Нужно войти'; end if;
  if exists (select 1 from am_profiles where id = u and role <> 'client') then
    raise exception 'Администратор не может удалить себя — сначала передайте права';
  end if;
  insert into am_consents(user_id, kind, version, accepted, user_agent)
  select u, k, 'account-deleted', false, left(coalesce(p_ua,''),300) from unnest(array['pd','cross_border','terms']) k;
  delete from am_vehicles where user_id = u;
  update am_messages set body = '[удалено]' where sender_id = u;
  update am_reviews set user_id = null where user_id = u;
  update am_requests set details = details - 'photos' - 'lat' - 'lon' - 'address' - 'phone' where user_id = u;
  perform set_config('am.sys', 'on', true);   -- служебное изменение: защитный триггер организаций пропускает
  update am_providers set owner_id = null, is_active = false where owner_id = u;
  perform set_config('am.sys', '', true);
  update am_profiles set tg_id = null, username = null, full_name = 'Удалённый пользователь', phone = null,
    consent = false, legal_version = null, deleted_at = now() where id = u;
  begin
    update auth.users set raw_user_meta_data = '{}'::jsonb where id = u;
  exception when others then null;
  end;
  insert into am_complaints(user_id, target_type, target_id, reason, body, status, answer, answered_at)
  values (u, 'personal_data', u::text, 'Удаление аккаунта',
          'Пользователь удалил аккаунт. Проверить удаление фото из хранилища и учётной записи Telegram-входа (auth.users).',
          'in_review', null, null);
  return jsonb_build_object('ok', true);
end $$;

-- индексы под частые запросы (каталог, лента исполнителя, чат, «мои заявки»)
create index if not exists am_providers_city_kind_idx on am_providers(city, kind) where is_active;
create index if not exists am_providers_owner_idx on am_providers(owner_id);
create index if not exists am_requests_user_idx on am_requests(user_id, created_at desc);
create index if not exists am_requests_open_idx on am_requests(city, type, created_at desc) where status in ('new','offers');
create index if not exists am_requests_accepted_idx on am_requests(accepted_by);
create index if not exists am_requests_target_idx on am_requests(target_provider_id);
create index if not exists am_offers_request_idx on am_offers(request_id);
create index if not exists am_offers_provider_idx on am_offers(provider_id);
create index if not exists am_reviews_provider_idx on am_reviews(provider_id, created_at desc);
create index if not exists am_prices_provider_idx on am_prices(provider_id);
create index if not exists am_messages_request_idx on am_messages(request_id, id);
create index if not exists am_vehicles_user_idx on am_vehicles(user_id);
create index if not exists am_registrations_user_idx on am_registrations(user_id);

-- полная очистка тестовых данных. Вызывать ТОЛЬКО из SQL Editor: select am_test_cleanup();
create or replace function am_test_cleanup() returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare uids uuid[]; pids int[]; n_req int; n_prov int; n_usr int;
begin
  select coalesce(array_agg(id), '{}') into uids from auth.users where email like '%@am24.test';
  select coalesce(array_agg(id), '{}') into pids from am_providers where is_test or owner_id = any(uids);
  delete from am_complaints where user_id = any(uids) or coalesce(contact,'') like '%@am24.test'
    or (target_type = 'provider' and target_id = any(select x::text from unnest(pids) x));
  delete from am_consents where user_id = any(uids);
  delete from am_reviews where user_id = any(uids) or provider_id = any(pids);
  delete from am_requests where user_id = any(uids) or accepted_by = any(pids) or target_provider_id = any(pids);
  get diagnostics n_req = row_count;
  delete from am_registrations where user_id = any(uids);
  delete from am_providers where id = any(pids);
  get diagnostics n_prov = row_count;
  delete from am_profiles where id = any(uids);
  delete from auth.users where id = any(uids);
  get diagnostics n_usr = row_count;
  return jsonb_build_object('users', n_usr, 'providers', n_prov, 'requests', n_req);
end $$;
revoke execute on function am_test_cleanup() from public, anon, authenticated;

notify pgrst, 'reload schema';
