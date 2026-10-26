-- =====================================================================
--  АвтоМастер24 — веб-версия. Схема базы для Supabase (PostgreSQL).
--  Вставить в Supabase → SQL Editor и нажать Run. Повторный запуск безопасен.
--  Все таблицы с префиксом am_, чтобы не мешать другим проектам в той же базе.
--  RLS включён везде. Все изменения статусов — только через функции (RPC).
-- =====================================================================

-- ---------- справочники ----------
create table if not exists am_cities (id serial primary key, name text not null unique, region text default '', active boolean not null default true);
create table if not exists am_categories (id serial primary key, name text not null);
create table if not exists am_subcategories (id serial primary key, name text not null, category_id int references am_categories(id) on delete cascade);
create table if not exists am_price_services (id serial primary key, name text not null, category text);
create table if not exists am_brands (id serial primary key, name text not null unique);
create table if not exists am_models (id serial primary key, brand_id int references am_brands(id) on delete cascade, name text not null);

-- ---------- люди ----------
create table if not exists am_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  tg_id bigint, username text, full_name text, phone text, city text,
  role text not null default 'client' check (role in ('client','regional_admin','global_admin')),
  managed_city text, consent boolean not null default false, consent_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- исполнители (СТО, эвакуаторы, мойки, запчасти, выездные мастера) ----------
create table if not exists am_providers (
  id serial primary key,
  kind text not null check (kind in ('sto','tow','wash','parts','urgent')),
  owner_id uuid references am_profiles(id) on delete set null,
  name text not null, city text not null, address text default '', phone text default '', working_hours text default '',
  specs int[] not null default '{}',                     -- СТО: id категорий am_categories
  supplier_type text check (supplier_type in ('shop','razborka')),       -- запчасти
  service_type text check (service_type in ('locksmith','tire','electrician','mechanic','delivery')), -- выездные
  boxes int not null default 1, slot_minutes int not null default 60,  -- мойка
  delivery boolean not null default false,
  rating numeric(3,2) not null default 0, reviews_count int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists am_providers_city_kind on am_providers(city, kind);

-- ---------- заявки ----------
create table if not exists am_requests (
  id bigserial primary key,
  type text not null check (type in ('sto','tow','wash','parts','urgent')),
  user_id uuid not null references am_profiles(id) on delete cascade,
  city text not null,
  status text not null default 'new',
  category_id int, subcategory text, service_type text, supplier_type text,
  target_provider_id int references am_providers(id) on delete set null,
  description text default '', vehicle_info text default '', details jsonb not null default '{}',
  desired_time timestamptz, assigned_time timestamptz, price int,
  accepted_by int references am_providers(id) on delete set null,
  accepted_offer_id bigint, final_amount int,
  expires_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists am_requests_city_type on am_requests(city, type, status);
create index if not exists am_requests_user on am_requests(user_id);

create table if not exists am_declines (request_id bigint references am_requests(id) on delete cascade,
  provider_id int references am_providers(id) on delete cascade, primary key (request_id, provider_id));

create table if not exists am_offers (
  id bigserial primary key, request_id bigint not null references am_requests(id) on delete cascade,
  provider_id int not null references am_providers(id) on delete cascade,
  price int not null check (price > 0), comment text default '', is_selected boolean not null default false,
  created_at timestamptz not null default now(), unique (request_id, provider_id)
);

create table if not exists am_reviews (
  id bigserial primary key, user_id uuid references am_profiles(id) on delete set null,
  provider_id int not null references am_providers(id) on delete cascade,
  request_id bigint references am_requests(id) on delete set null,
  rating int not null check (rating between 1 and 5), comment text default '',
  is_published boolean not null default false, created_at timestamptz not null default now(),
  unique (request_id)
);

create table if not exists am_vehicles (
  id bigserial primary key, user_id uuid not null default auth.uid() references am_profiles(id) on delete cascade,
  brand text not null, model text default '', year int, plate text default '', engine_volume text default '',
  created_at timestamptz not null default now()
);

create table if not exists am_prices (
  id bigserial primary key, provider_id int references am_providers(id) on delete cascade, -- null = справочная цена
  service text not null, brand text default '', model text default '',
  year_from int, year_to int, engine_volume numeric, price int not null check (price > 0), notes text default '',
  updated_at timestamptz not null default now()
);

create table if not exists am_registrations (
  id bigserial primary key, user_id uuid not null references am_profiles(id) on delete cascade,
  kind text not null check (kind in ('sto','tow','wash','parts','urgent')),
  name text not null, phone text not null, address text default '', city text not null,
  details jsonb not null default '{}', status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reason text, provider_id int, created_at timestamptz not null default now(), reviewed_at timestamptz
);

-- ---------- вспомогательные функции ----------
create or replace function am_is_admin(p_city text default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from am_profiles where id = auth.uid()
    and (role = 'global_admin' or (role = 'regional_admin' and (p_city is null or managed_city = p_city))));
$$;
create or replace function am_owns(p_provider int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from am_providers where id = p_provider and owner_id = auth.uid());
$$;
-- может ли исполнитель (владелец p) видеть новую заявку r
create or replace function am_matches(r am_requests, p am_providers) returns boolean
language sql stable as $$
  select p.is_active and p.kind = r.type and p.city = r.city
    and (r.target_provider_id is null or r.target_provider_id = p.id)
    and (r.type <> 'urgent' or r.service_type is null or r.service_type = p.service_type)
    and (r.type <> 'parts' or r.supplier_type is null or r.supplier_type = p.supplier_type)
    and (r.type <> 'sto' or r.category_id is null or cardinality(p.specs) = 0 or r.category_id = any(p.specs) or r.target_provider_id = p.id);
$$;
create or replace function am_can_see_request(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from am_requests r where r.id = p_id and (
    r.user_id = auth.uid() or am_is_admin(r.city)
    or exists (select 1 from am_providers p where p.owner_id = auth.uid() and p.id in (r.accepted_by, r.target_provider_id))
    or (r.status in ('new','offers') and (r.expires_at is null or r.expires_at > now())
        and exists (select 1 from am_providers p where p.owner_id = auth.uid() and am_matches(r, p)
                    and not exists (select 1 from am_declines d where d.request_id = r.id and d.provider_id = p.id)))));
$$;

-- ---------- RLS ----------
do $$ declare t text; begin
  foreach t in array array['am_cities','am_categories','am_subcategories','am_price_services','am_brands','am_models',
    'am_profiles','am_providers','am_requests','am_declines','am_offers','am_reviews','am_vehicles','am_prices','am_registrations'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
  foreach t in array array['am_cities','am_categories','am_subcategories','am_price_services','am_brands','am_models'] loop
    execute format('drop policy if exists "read" on %I', t);
    execute format('create policy "read" on %I for select using (true)', t);
    execute format('drop policy if exists "admin write" on %I', t);
    execute format('create policy "admin write" on %I for all to authenticated using (am_is_admin()) with check (am_is_admin())', t);
  end loop;
end $$;

drop policy if exists "own or admin" on am_profiles;
create policy "own or admin" on am_profiles for select to authenticated using (id = auth.uid() or am_is_admin(city));

drop policy if exists "public active" on am_providers;
create policy "public active" on am_providers for select using (is_active or owner_id = auth.uid() or am_is_admin(city));
drop policy if exists "owner update" on am_providers;
create policy "owner update" on am_providers for update to authenticated using (owner_id = auth.uid() or am_is_admin(city)) with check (owner_id = auth.uid() or am_is_admin(city));
drop policy if exists "admin insert" on am_providers;
create policy "admin insert" on am_providers for insert to authenticated with check (am_is_admin(city));
drop policy if exists "admin delete" on am_providers;
create policy "admin delete" on am_providers for delete to authenticated using (am_is_admin(city));

create or replace function am_providers_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin(old.city) then
    new.owner_id := old.owner_id; new.kind := old.kind; new.rating := old.rating;
    new.reviews_count := old.reviews_count; new.is_active := old.is_active; new.city := old.city;
  end if;
  return new;
end $$;
drop trigger if exists am_providers_guard on am_providers;
create trigger am_providers_guard before update on am_providers for each row execute function am_providers_guard();

drop policy if exists "visible" on am_requests;
create policy "visible" on am_requests for select to authenticated using (am_can_see_request(id));

drop policy if exists "own provider" on am_declines;
create policy "own provider" on am_declines for select to authenticated using (am_owns(provider_id));

drop policy if exists "provider or admin" on am_offers;
create policy "provider or admin" on am_offers for select to authenticated using (am_owns(provider_id) or am_is_admin());

drop policy if exists "published or own" on am_reviews;
create policy "published or own" on am_reviews for select using (is_published or user_id = auth.uid() or am_is_admin());

drop policy if exists "own" on am_vehicles;
create policy "own" on am_vehicles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "read" on am_prices;
create policy "read" on am_prices for select using (true);
drop policy if exists "owner write" on am_prices;
create policy "owner write" on am_prices for all to authenticated
  using ((provider_id is not null and am_owns(provider_id)) or am_is_admin())
  with check ((provider_id is not null and am_owns(provider_id)) or am_is_admin());

drop policy if exists "own or admin" on am_registrations;
create policy "own or admin" on am_registrations for select to authenticated using (user_id = auth.uid() or am_is_admin(city));

-- anon видит только справочники, исполнителей, цены и опубликованные отзывы
revoke all on am_profiles, am_requests, am_declines, am_offers, am_vehicles, am_registrations from anon;
revoke insert, update, delete on am_requests, am_declines, am_offers, am_reviews, am_registrations, am_profiles from authenticated;

-- ---------- профиль ----------
create or replace function am_ensure_profile() returns am_profiles
language plpgsql security definer set search_path = public as $$
declare me am_profiles; meta jsonb;
begin
  if auth.uid() is null then raise exception 'Войдите через Telegram'; end if;
  select * into me from am_profiles where id = auth.uid();
  if found then return me; end if;
  select raw_user_meta_data into meta from auth.users where id = auth.uid();
  insert into am_profiles(id, tg_id, username, full_name)
  values (auth.uid(), nullif(meta->>'tg_id','')::bigint, meta->>'username', coalesce(meta->>'first_name','Пользователь'))
  returning * into me;
  return me;
end $$;

create or replace function am_update_profile(p_full_name text, p_phone text, p_city text, p_consent boolean) returns am_profiles
language plpgsql security definer set search_path = public as $$
declare me am_profiles;
begin
  perform am_ensure_profile();
  if p_phone is not null and p_phone <> '' and regexp_replace(p_phone, '\D', '', 'g') !~ '^[78]\d{10}$' then
    raise exception 'Телефон в формате +7 7XX XXX XX XX';
  end if;
  update am_profiles set full_name = coalesce(nullif(trim(p_full_name),''), full_name),
    phone = nullif(regexp_replace(coalesce(p_phone,''), '[^\d+]', '', 'g'), ''), city = p_city,
    consent = p_consent, consent_at = case when p_consent and not consent then now() else consent_at end
  where id = auth.uid() returning * into me;
  return me;
end $$;

create or replace function am_delete_my_data() returns void
language sql security definer set search_path = public as $$
  update am_profiles set phone = null, consent = false where id = auth.uid();
$$;

-- ---------- заявки клиента ----------
create or replace function am_create_request(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare me am_profiles; t text := p->>'type'; nid bigint; ttl interval;
begin
  me := am_ensure_profile();
  if not me.consent then raise exception 'Нужно согласие на обработку персональных данных (Профиль)'; end if;
  if coalesce(me.phone,'') = '' then raise exception 'Укажите телефон в профиле — без него исполнитель не сможет связаться'; end if;
  if t not in ('sto','tow','wash','parts','urgent') then raise exception 'Неизвестный тип заявки'; end if;
  ttl := case t when 'parts' then interval '180 minutes' when 'wash' then null else interval '60 minutes' end;
  insert into am_requests(type, user_id, city, category_id, subcategory, service_type, supplier_type, target_provider_id,
    description, vehicle_info, details, desired_time, expires_at)
  values (t, me.id, coalesce(nullif(p->>'city',''), me.city), nullif(p->>'category_id','')::int, p->>'subcategory',
    nullif(p->>'service_type',''), nullif(p->>'supplier_type',''), nullif(p->>'target_provider_id','')::int,
    left(coalesce(p->>'description',''), 2000), left(coalesce(p->>'vehicle_info',''), 300), coalesce(p->'details','{}'),
    nullif(p->>'desired_time','')::timestamptz, now() + ttl)
  returning id into nid;
  return nid;
end $$;

create or replace function am_my_request(p_id bigint) returns am_requests
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.user_id <> auth.uid() then raise exception 'Заявка не найдена'; end if;
  return r;
end $$;

create or replace function am_cancel_request(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id);
begin
  if r.status in ('completed','cancelled') then raise exception 'Заявку уже нельзя отменить'; end if;
  update am_requests set status = 'cancelled', updated_at = now() where id = p_id;
end $$;

create or replace function am_request_offers(p_id bigint) returns table(id bigint, price int, comment text, is_selected boolean,
  created_at timestamptz, provider_id int, provider_name text, provider_phone text, provider_address text, provider_rating numeric, delivery boolean)
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id);
begin
  -- до выбора предложения поставщик анонимен (как в боте)
  return query select o.id, o.price, o.comment, o.is_selected, o.created_at,
    case when o.is_selected then p.id end, case when o.is_selected then p.name else 'Поставщик №' || o.provider_id end,
    case when o.is_selected then p.phone end, case when o.is_selected then p.address end, p.rating, p.delivery
  from am_offers o join am_providers p on p.id = o.provider_id where o.request_id = r.id order by o.price;
end $$;

create or replace function am_select_offer(p_offer bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o am_offers; r am_requests;
begin
  select * into o from am_offers where id = p_offer;
  if not found then raise exception 'Предложение не найдено'; end if;
  r := am_my_request(o.request_id);
  if r.status not in ('new','offers') then raise exception 'Предложение уже выбрано'; end if;
  update am_offers set is_selected = (id = p_offer) where request_id = r.id;
  update am_requests set status = 'active', accepted_by = o.provider_id, accepted_offer_id = o.id, final_amount = o.price, updated_at = now() where id = r.id;
end $$;

create or replace function am_wash_approve(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id);
begin
  if r.status <> 'price_offered' then raise exception 'Мойка ещё не предложила цену и время'; end if;
  update am_requests set status = 'client_approved', final_amount = price, updated_at = now() where id = p_id;
end $$;

create or replace function am_client_confirm(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id);
begin
  if r.status not in ('active','delivered','waiting_client','in_progress') then raise exception 'Нельзя завершить заявку в этом статусе'; end if;
  update am_requests set status = 'completed', updated_at = now() where id = p_id;
end $$;

create or replace function am_recalc_rating(p_provider int) returns void
language sql security definer set search_path = public as $$
  update am_providers set rating = coalesce((select round(avg(rating)::numeric, 2) from am_reviews where provider_id = p_provider), 0),
    reviews_count = (select count(*) from am_reviews where provider_id = p_provider) where id = p_provider;
$$;

create or replace function am_leave_review(p_id bigint, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests := am_my_request(p_id);
begin
  if r.status <> 'completed' or r.accepted_by is null then raise exception 'Оценить можно только выполненную заявку'; end if;
  insert into am_reviews(user_id, provider_id, request_id, rating, comment, is_published)
  values (auth.uid(), r.accepted_by, r.id, p_rating, left(coalesce(p_comment,''), 1000), coalesce(trim(p_comment),'') = '')
  on conflict (request_id) do nothing;
  perform am_recalc_rating(r.accepted_by);
end $$;

-- ---------- исполнитель ----------
create or replace function am_my_provider(p_provider int) returns am_providers
language plpgsql security definer set search_path = public as $$
declare p am_providers;
begin
  select * into p from am_providers where id = p_provider and owner_id = auth.uid();
  if not found then raise exception 'Это не ваша организация'; end if;
  if not p.is_active then raise exception 'Организация отключена администратором'; end if;
  return p;
end $$;

create or replace function am_provider_feed(p_provider int) returns setof am_requests
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider);
begin
  return query select r.* from am_requests r
  where r.accepted_by = p.id or r.target_provider_id = p.id
     or (r.status in ('new','offers') and (r.expires_at is null or r.expires_at > now()) and am_matches(r, p)
         and not exists (select 1 from am_declines d where d.request_id = r.id and d.provider_id = p.id))
  order by r.created_at desc limit 200;
end $$;

create or replace function am_accept_request(p_id bigint, p_provider int) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider); r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or not am_matches(r, p) then raise exception 'Заявка недоступна'; end if;
  if r.type in ('parts','wash') then raise exception 'Для этой заявки отправьте предложение'; end if;
  if r.status <> 'new' then raise exception 'Заявку уже принял другой исполнитель'; end if;
  if r.expires_at is not null and r.expires_at < now() then raise exception 'Срок заявки истёк'; end if;
  update am_requests set status = 'active', accepted_by = p.id, updated_at = now() where id = p_id;
end $$;

create or replace function am_decline_request(p_id bigint, p_provider int) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider);
begin
  insert into am_declines values (p_id, p.id) on conflict do nothing;
end $$;

create or replace function am_complete_request(p_id bigint, p_provider int, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider); r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is distinct from p.id then raise exception 'Заявка не ваша'; end if;
  if r.type = 'parts' then
    if r.status <> 'active' then raise exception 'Неверный статус'; end if;
    update am_requests set status = 'delivered', updated_at = now() where id = p_id;   -- клиент подтвердит получение
  else
    if r.status not in ('active','in_progress','waiting_client','client_approved') then raise exception 'Неверный статус'; end if;
    update am_requests set status = 'completed', final_amount = coalesce(p_amount, final_amount), updated_at = now() where id = p_id;
  end if;
end $$;

create or replace function am_make_offer(p_id bigint, p_provider int, p_price int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider); r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.type <> 'parts' or not am_matches(r, p) then raise exception 'Заявка недоступна'; end if;
  if r.status not in ('new','offers') or (r.expires_at is not null and r.expires_at < now()) then raise exception 'Заявка уже закрыта'; end if;
  if coalesce(p_price,0) <= 0 then raise exception 'Укажите цену'; end if;
  insert into am_offers(request_id, provider_id, price, comment) values (p_id, p.id, p_price, left(coalesce(p_comment,''),500))
  on conflict (request_id, provider_id) do update set price = excluded.price, comment = excluded.comment, created_at = now();
  update am_requests set status = 'offers', updated_at = now() where id = p_id and status = 'new';
end $$;

create or replace function am_wash_quote(p_id bigint, p_provider int, p_price int, p_time timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider); r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.type <> 'wash' or not (am_matches(r, p) or r.accepted_by = p.id) then raise exception 'Заявка недоступна'; end if;
  if r.status not in ('new','price_offered') then raise exception 'Запись уже подтверждена'; end if;
  if r.accepted_by is not null and r.accepted_by <> p.id then raise exception 'Запись уже взяла другая мойка'; end if;
  if coalesce(p_price,0) <= 0 or p_time is null then raise exception 'Укажите цену и время'; end if;
  update am_requests set status = 'price_offered', accepted_by = p.id, price = p_price, assigned_time = p_time, updated_at = now() where id = p_id;
end $$;

create or replace function am_wash_status(p_id bigint, p_provider int, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare p am_providers := am_my_provider(p_provider); r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is distinct from p.id or r.type <> 'wash' then raise exception 'Заявка не ваша'; end if;
  if not ((r.status = 'client_approved' and p_status = 'in_progress') or (r.status = 'in_progress' and p_status = 'waiting_client')
       or (r.status in ('waiting_client','in_progress') and p_status = 'completed')) then raise exception 'Неверный переход статуса'; end if;
  update am_requests set status = p_status, updated_at = now() where id = p_id;
end $$;

-- контакт клиента — только исполнителю, который принял заявку
create or replace function am_client_contact(p_id bigint) returns table(full_name text, phone text, username text)
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id;
  if not found or not (am_owns(r.accepted_by) or am_is_admin(r.city)) then raise exception 'Контакт доступен после принятия заявки'; end if;
  if r.type = 'wash' and r.status in ('new','price_offered') and not am_is_admin(r.city) then raise exception 'Контакт доступен после подтверждения клиентом'; end if;
  return query select pr.full_name, pr.phone, pr.username from am_profiles pr where pr.id = r.user_id;
end $$;

-- ---------- регистрация бизнеса и админка ----------
create or replace function am_register_business(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare me am_profiles := am_ensure_profile(); nid bigint;
begin
  if coalesce(trim(p->>'name'),'') = '' or coalesce(trim(p->>'phone'),'') = '' or coalesce(p->>'city','') = '' then
    raise exception 'Заполните название, телефон и город'; end if;
  if (select count(*) from am_registrations where user_id = me.id and status = 'pending') >= 3 then raise exception 'У вас уже есть заявки на рассмотрении'; end if;
  insert into am_registrations(user_id, kind, name, phone, address, city, details)
  values (me.id, p->>'kind', left(p->>'name',120), left(p->>'phone',30), left(coalesce(p->>'address',''),200), p->>'city', coalesce(p->'details','{}'))
  returning id into nid;
  return nid;
end $$;

create or replace function am_review_registration(p_id bigint, p_approve boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g am_registrations; pid int;
begin
  select * into g from am_registrations where id = p_id for update;
  if not found or not am_is_admin(g.city) then raise exception 'Нет прав'; end if;
  if g.status <> 'pending' then raise exception 'Заявка уже рассмотрена'; end if;
  if p_approve then
    insert into am_providers(kind, owner_id, name, city, address, phone, working_hours, specs, supplier_type, service_type, boxes, slot_minutes, delivery)
    values (g.kind, g.user_id, g.name, g.city, g.address, g.phone, coalesce(g.details->>'working_hours',''),
      coalesce((select array_agg(x::int) from jsonb_array_elements_text(coalesce(g.details->'specs','[]')) x), '{}'),
      nullif(g.details->>'supplier_type',''), nullif(g.details->>'service_type',''),
      coalesce(nullif(g.details->>'boxes','')::int, 1), coalesce(nullif(g.details->>'slot_minutes','')::int, 60),
      coalesce((g.details->>'delivery')::boolean, false))
    returning id into pid;
  end if;
  update am_registrations set status = case when p_approve then 'approved' else 'rejected' end, reason = p_reason,
    provider_id = pid, reviewed_at = now() where id = p_id;
end $$;

create or replace function am_moderate_review(p_id bigint, p_publish boolean) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  select * into rv from am_reviews where id = p_id;
  if p_publish then update am_reviews set is_published = true where id = p_id;
  else delete from am_reviews where id = p_id; perform am_recalc_rating(rv.provider_id); end if;
end $$;

create or replace function am_admin_requests() returns setof am_requests
language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  return query select r.* from am_requests r where am_is_admin(r.city) order by r.created_at desc limit 500;
end $$;

create or replace function am_admin_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  return jsonb_build_object(
    'users', (select count(*) from am_profiles),
    'providers', (select count(*) from am_providers where am_is_admin(city)),
    'requests', (select count(*) from am_requests where am_is_admin(city)),
    'completed', (select count(*) from am_requests where am_is_admin(city) and status = 'completed'),
    'active', (select count(*) from am_requests where am_is_admin(city) and status in ('new','offers','active','price_offered','client_approved','in_progress','waiting_client','delivered')),
    'pending_regs', (select count(*) from am_registrations where am_is_admin(city) and status = 'pending'),
    'pending_reviews', (select count(*) from am_reviews where not is_published),
    'turnover', (select coalesce(sum(final_amount),0) from am_requests where am_is_admin(city) and status = 'completed'));
end $$;

-- назначить администратора (запускать вручную в SQL Editor): select am_make_admin('username_в_telegram');
create or replace function am_make_admin(p_username text, p_city text default null) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not am_is_admin() then raise exception 'Нет прав'; end if;
  update am_profiles set role = case when p_city is null then 'global_admin' else 'regional_admin' end, managed_city = p_city
  where lower(username) = lower(trim(leading '@' from p_username));
  get diagnostics n = row_count;
  return case when n = 0 then 'Пользователь не найден: сначала войдите на сайт через Telegram' else 'Готово' end;
end $$;
revoke execute on function am_make_admin(text, text) from anon;

grant select on am_cities, am_categories, am_subcategories, am_price_services, am_brands, am_models, am_providers, am_prices, am_reviews to anon, authenticated;
grant select, insert, update, delete on am_vehicles, am_prices, am_providers to authenticated;
grant select on am_profiles, am_requests, am_declines, am_offers, am_registrations to authenticated;
grant insert, update, delete on am_cities, am_categories, am_subcategories, am_price_services, am_brands, am_models to authenticated;
grant usage, select on all sequences in schema public to authenticated;
-- Справочники АвтоМастер24 (сгенерировано tools/build_seed.py, без личных данных). Повторный запуск безопасен.
insert into am_cities(id,name,region,active) values (1,'Алматы','Алматинская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (2,'Астана','Акмолинская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (3,'Шымкент','Туркестанская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (4,'Талдыкорган','Алматинская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (5,'Семей','Абайская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (6,'Актобе','Актюбинская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (7,'Тараз','Жамбылская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (8,'Павлодар','Павлодарская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (9,'Атырау','Атырауская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (10,'Усть-Каменогорск','Восточно-Казахстанская область',true) on conflict (id) do nothing;
insert into am_cities(id,name,region,active) values (285,'Караганда','',true) on conflict (id) do nothing;
insert into am_categories(id,name) values (1,'Ремонт двигателя') on conflict (id) do nothing;
insert into am_categories(id,name) values (2,'Ремонт ходовой') on conflict (id) do nothing;
insert into am_categories(id,name) values (3,'Электрика') on conflict (id) do nothing;
insert into am_categories(id,name) values (4,'Кузовной ремонт') on conflict (id) do nothing;
insert into am_categories(id,name) values (5,'Шиномонтаж') on conflict (id) do nothing;
insert into am_categories(id,name) values (6,'Ремонт кондиционеров') on conflict (id) do nothing;
insert into am_categories(id,name) values (7,'Диагностика') on conflict (id) do nothing;
insert into am_categories(id,name) values (8,'Техническое обслуживание (ТО)') on conflict (id) do nothing;
insert into am_categories(id,name) values (9,'Ремонт тормозной системы') on conflict (id) do nothing;
insert into am_categories(id,name) values (10,'Ремонт выхлопной системы') on conflict (id) do nothing;
insert into am_categories(id,name) values (11,'Ремонт рулевого управления') on conflict (id) do nothing;
insert into am_categories(id,name) values (12,'Ремонт трансмиссии') on conflict (id) do nothing;
insert into am_categories(id,name) values (13,'Ремонт топливной системы') on conflict (id) do nothing;
insert into am_categories(id,name) values (14,'Ремонт системы охлаждения') on conflict (id) do nothing;
insert into am_categories(id,name) values (15,'Автоэлектрик') on conflict (id) do nothing;
insert into am_categories(id,name) values (16,'Ремонт салона') on conflict (id) do nothing;
insert into am_categories(id,name) values (17,'Токарные работы') on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (23,'Диагностика двигателя',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (24,'Замена ГРМ',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (25,'Замена масла в двигателе',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (26,'Замена поршневой',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (27,'Замена прокладки ГБЦ',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (28,'Капитальный ремонт',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (29,'Ремонт головки блока',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (30,'Ремонт коленвала',1) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (74,'Замена амортизаторов',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (75,'Замена рычагов',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (76,'Замена сайлентблоков',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (77,'Замена ступичных подшипников',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (78,'Замена шаровых опор',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (79,'Развал-схождение',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (80,'Ремонт подвески',2) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (102,'Диагностика электрооборудования',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (103,'Замена аккумулятора',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (104,'Замена проводки',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (105,'Ремонт генератора',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (106,'Ремонт освещения',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (107,'Ремонт стартера',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (108,'Ремонт стеклоподъёмников',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (109,'Установка сигнализации',3) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (11,'Антикоррозийная обработка',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (12,'Замена стёкол',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (13,'Покраска',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (14,'Полировка',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (15,'Ремонт бамперов',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (16,'Рихтовка',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (17,'Удаление вмятин',4) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (96,'Балансировка колёс',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (97,'Замена шин',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (98,'Прокачка колёс азотом',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (99,'Ремонт дисков',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (100,'Ремонт проколов',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (101,'Сезонное хранение шин',5) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (31,'Диагностика кондиционера',6) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (32,'Замена радиатора кондиционера',6) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (33,'Заправка фреоном',6) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (34,'Ремонт компрессора',6) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (35,'Чистка системы',6) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (6,'Диагностика двигателя',7) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (7,'Диагностика тормозной системы',7) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (8,'Диагностика ходовой',7) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (9,'Диагностика электрооборудования',7) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (10,'Компьютерная диагностика',7) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (81,'Замена воздушного фильтра',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (82,'Замена масла АКПП',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (83,'Замена масла МехКПП',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (84,'Замена масла и фильтров',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (85,'Замена охлаждающей жидкости',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (86,'Замена ремня ГРМ',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (87,'Замена салонного фильтра',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (88,'Замена свечей зажигания',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (89,'Замена тормозной жидкости',8) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (62,'Замена тормозных дисков',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (63,'Замена тормозных колодок',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (64,'Замена тормозных суппортов',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (65,'Замена тормозных трубок',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (66,'Прокачка тормозов',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (67,'Ремонт главного тормозного цилиндра',9) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (18,'Замена глушителя',10) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (19,'Замена катализатора',10) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (20,'Замена лямбда-зонда',10) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (21,'Ремонт гофры',10) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (22,'Сварка выхлопной системы',10) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (36,'Замена наконечников рулевых тяг',11) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (37,'Замена рулевой колонки',11) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (38,'Замена рулевых тяг',11) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (39,'Ремонт ГУР',11) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (40,'Ремонт рулевой рейки',11) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (68,'Замена масла в КПП',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (69,'Замена приводов (полуосей)',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (70,'Замена сцепления',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (71,'Ремонт АКПП',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (72,'Ремонт МКПП',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (73,'Ремонт карданного вала',12) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (57,'Замена топливного насоса',13) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (58,'Замена топливного фильтра',13) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (59,'Регулировка давления топлива',13) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (60,'Ремонт топливной рампы',13) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (61,'Чистка форсунок',13) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (52,'Замена вентилятора охлаждения',14) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (53,'Замена помпы',14) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (54,'Замена радиатора',14) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (55,'Замена термостата',14) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (56,'Промывка системы охлаждения',14) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (1,'Замена предохранителей',15) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (2,'Ремонт блоков управления',15) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (3,'Ремонт электропроводки',15) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (4,'Установка доп. оборудования',15) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (5,'Установка дополнительного света',15) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (41,'Замена обивки дверей',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (42,'Изготовление EVA ковриков',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (43,'Изготовление чехлов',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (44,'Перетяжка ковриков',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (45,'Перетяжка панелей',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (46,'Перетяжка потолка',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (47,'Перетяжка салона кожей',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (48,'Ремонт сидений',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (49,'Установка подогрева сидений',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (50,'Химчистка салона',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (51,'Шумоизоляция',16) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (90,'Другие токарные работы',17) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (91,'Изготовление втулок',17) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (92,'Проточка ГБЦ',17) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (93,'Проточка блока цилиндров',17) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (94,'Проточка маховика',17) on conflict (id) do nothing;
insert into am_subcategories(id,name,category_id) values (95,'Проточка тормозных дисков',17) on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (1,'Замена масла','Двигатель') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (2,'Замена передних колодок','Тормозная система') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (3,'Замена задних колодок','Тормозная система') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (4,'Замена ремня ГРМ','Двигатель') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (5,'Диагностика двигателя','Диагностика') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (6,'Ремонт ходовой','Ходовая часть') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (7,'Развал-схождение','Ходовая часть') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (8,'Замена амортизаторов','Ходовая часть') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (9,'Ремонт кондиционера','Климат') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (10,'Замена свечей зажигания','Двигатель') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (11,'Замена тормозной жидкости','Тормозная система') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (12,'Замена антифриза','Охлаждение') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (13,'Замена ГРМ','Двигатель') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (14,'Ремонт генератора','Электрооборудование') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (15,'Ремонт стартера','Электрооборудование') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (16,'Регулировка фар','Освещение') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (17,'Замена топливного фильтра','Топливная система') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (18,'Замена воздушного фильтра','Двигатель') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (19,'Компьютерная диагностика','Диагностика') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (20,'Замена сцепления','Трансмиссия') on conflict (id) do nothing;
insert into am_price_services(id,name,category) values (21,'Диагностика ходовой части','Диагностика') on conflict (id) do nothing;
insert into am_brands(id,name) values (1,'Toyota') on conflict (id) do nothing;
insert into am_brands(id,name) values (2,'Hyundai') on conflict (id) do nothing;
insert into am_brands(id,name) values (3,'Kia') on conflict (id) do nothing;
insert into am_brands(id,name) values (4,'Chevrolet') on conflict (id) do nothing;
insert into am_brands(id,name) values (5,'Nissan') on conflict (id) do nothing;
insert into am_brands(id,name) values (6,'Honda') on conflict (id) do nothing;
insert into am_brands(id,name) values (7,'Volkswagen') on conflict (id) do nothing;
insert into am_brands(id,name) values (8,'BMW') on conflict (id) do nothing;
insert into am_brands(id,name) values (9,'Mercedes-Benz') on conflict (id) do nothing;
insert into am_brands(id,name) values (10,'Lexus') on conflict (id) do nothing;
insert into am_brands(id,name) values (11,'Mazda') on conflict (id) do nothing;
insert into am_brands(id,name) values (12,'Renault') on conflict (id) do nothing;
insert into am_brands(id,name) values (13,'Lada') on conflict (id) do nothing;
insert into am_brands(id,name) values (14,'УАЗ') on conflict (id) do nothing;
insert into am_brands(id,name) values (15,'ГАЗ') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (1,1,'Camry') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (2,1,'Corolla') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (3,1,'Land Cruiser') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (4,1,'RAV4') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (5,1,'Prius') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (6,2,'Solaris') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (7,2,'Elantra') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (8,2,'Tucson') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (9,2,'Santa Fe') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (10,2,'Creta') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (11,3,'Rio') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (12,3,'Cerato') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (13,3,'Sportage') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (14,3,'Sorento') on conflict (id) do nothing;
insert into am_models(id,brand_id,name) values (15,3,'K5') on conflict (id) do nothing;
do $$ begin if not exists (select 1 from am_prices where provider_id is null) then
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Геометрия задней оси','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Геометрия передней оси','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Диагностика ходовой части','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Полная диагностика автомобиля','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена втулки заднего стабилизатора','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена заднего амортизатора','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена заднего ступичного подшипника','Toyota','Camry',5500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена задней балки','Toyota','Camry',18000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена задней поперечной тяги','Toyota','Camry',3500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена задней пружины стойки амортизатора','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена задней стойки стабилизатора','Toyota','Camry',1500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена задней ступицы','Toyota','Camry',5500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена опорной чашки задней стойки амортизатора','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена передней поперечной тяги','Toyota','Camry',3500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена сайлентблока продольной тяги железного','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Зад.ХЧ Замена сайлентблока продольной тяги резинового','Toyota','Camry',1500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена боковой подушки двигателя','Toyota','Camry',4500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена верхней подушки двигателя (гантелька)','Toyota','Camry',1500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена внутренней гранаты левой','Toyota','Camry',4500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена втулки переднего стабилизатора','Toyota','Camry',1500,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена задней подушки двигателя 3 л','Toyota','Camry',8000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена задней подушки двигателя','Toyota','Camry',6000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена левого привода гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена левого флянца гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена наружной гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена нижней шаровой опоры','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена опорной чашки переднего амортизатора','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена переднего амортизатора','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена передней балки','Toyota','Camry',25000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена передней подушки двигателя','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена передней стойки стабилизатора','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена передней ступицы','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена подушки КПП','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена подшипника передней опорной чашки амортизатора','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена подшипника передней ступицы','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена подшипника привода гранаты (на 3L)','Toyota','Camry',8000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена подшипника привода гранаты','Toyota','Camry',8000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена правого привода гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена правого флянца гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пружины передней стойки амортизатора','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника левой внутренней гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника наружной гранаты (со снятием привода)','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника наружной гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника правой внутренней гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника рулевой тяги','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена пыльника-отбойника переднего амортизатора','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена рулевого наконечника','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена рулевой тяги','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена сайлентблока переднего рычага (без снятия подушки)','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена сайлентблока переднего рычага заднего (со снятием подушки)','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена сайлентблока переднего рычага переднего (со снятием подушки)','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена сальника левого привода гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена сальника правого привода гранаты','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Пер.ХЧ Замена шпильки колеса','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена выжимного подшипника','Toyota','Camry',30000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена диска сцепления (фередо)','Toyota','Camry',30000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена коренного сальника КПП (автомат)','Toyota','Camry',45000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена коренного сальника КПП (механика)','Toyota','Camry',25000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена корзины сцепления','Toyota','Camry',25000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена КПП (автомат)','Toyota','Camry',45000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена КПП (механика)','Toyota','Camry',25000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена маховика КПП (автомат)','Toyota','Camry',45000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена маховика КПП (механика)','Toyota','Camry',25000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена заднего тормозного суппорта','Toyota','Camry',3000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена задних тормозных колодок (барабан)','Toyota','Camry',5000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена переднего тормозного диска','Toyota','Camry',4000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена тормозных колодок (диск)','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Замена тормозных колодок с обслуживанием суппорта','Toyota','Camry',2000,'Справочная цена');
  insert into am_prices(provider_id,service,brand,model,price,notes) values (null,'Прокачка тормозной системы (одно колесо)','Toyota','Camry',2000,'Справочная цена');
end if; end $$;
do $$ begin
  perform setval(pg_get_serial_sequence('am_cities','id'), (select coalesce(max(id),1) from am_cities));
  perform setval(pg_get_serial_sequence('am_categories','id'), (select coalesce(max(id),1) from am_categories));
  perform setval(pg_get_serial_sequence('am_subcategories','id'), (select coalesce(max(id),1) from am_subcategories));
  perform setval(pg_get_serial_sequence('am_price_services','id'), (select coalesce(max(id),1) from am_price_services));
  perform setval(pg_get_serial_sequence('am_brands','id'), (select coalesce(max(id),1) from am_brands));
  perform setval(pg_get_serial_sequence('am_models','id'), (select coalesce(max(id),1) from am_models));
end $$;
-- =====================================================================
--  АвтоМастер24 — обновление 3: фото, чат, профиль исполнителя, ответы на отзывы.
--  ТОЛЬКО ДОБАВЛЯЕТ (новые колонки/таблицы/функции/бакеты). Данные не удаляются.
--  Повторный запуск безопасен. Таблицы VeloMarket не затрагиваются.
-- =====================================================================

-- ---------- новые колонки ----------
alter table am_providers add column if not exists about text not null default '';
alter table am_providers add column if not exists photos text[] not null default '{}';
alter table am_providers add column if not exists whatsapp text not null default '';
alter table am_providers add column if not exists verified boolean not null default false;
alter table am_requests  add column if not exists accepted_at timestamptz;
alter table am_reviews   add column if not exists reply text;
alter table am_reviews   add column if not exists reply_at timestamptz;

-- «Проверен» и рейтинг меняет только админ
create or replace function am_providers_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin(old.city) then
    new.owner_id := old.owner_id; new.kind := old.kind; new.rating := old.rating;
    new.reviews_count := old.reviews_count; new.is_active := old.is_active; new.city := old.city;
    new.verified := old.verified;
  end if;
  new.about := left(coalesce(new.about, ''), 2000);
  if cardinality(new.photos) > 12 then new.photos := new.photos[1:12]; end if;
  return new;
end $$;

-- время принятия заявки (для статистики «отвечает за N минут»)
create or replace function am_requests_accepted_at() returns trigger language plpgsql as $$
begin
  if new.accepted_by is not null and old.accepted_by is null and new.accepted_at is null then new.accepted_at := now(); end if;
  return new;
end $$;
drop trigger if exists am_requests_accepted_at on am_requests;
create trigger am_requests_accepted_at before update on am_requests for each row execute function am_requests_accepted_at();

-- ---------- публичная статистика исполнителя ----------
create or replace function am_provider_stats(p_id int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'completed', (select count(*) from am_requests where accepted_by = p_id and status = 'completed'),
    'response_min', (select round(percentile_cont(0.5) within group (order by extract(epoch from (accepted_at - created_at)) / 60))::int
                     from am_requests where accepted_by = p_id and accepted_at is not null and accepted_at > created_at),
    'price_from', (select min(price) from am_prices where provider_id = p_id));
$$;
grant execute on function am_provider_stats(int) to anon, authenticated;

-- ---------- ответ исполнителя на отзыв ----------
create or replace function am_reply_review(p_id bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or not (am_owns(rv.provider_id) or am_is_admin()) then raise exception 'Нет прав'; end if;
  update am_reviews set reply = nullif(left(trim(coalesce(p_text,'')), 1000), ''), reply_at = now() where id = p_id;
end $$;
revoke execute on function am_reply_review(bigint, text) from anon;

-- ---------- чат клиент ↔ исполнитель по заявке ----------
create table if not exists am_messages (
  id bigserial primary key,
  request_id bigint not null references am_requests(id) on delete cascade,
  sender_id uuid default auth.uid() references am_profiles(id) on delete set null,
  from_provider boolean not null default false,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists am_messages_req on am_messages(request_id, id);
alter table am_messages enable row level security;

-- писать могут: клиент — автор заявки, и исполнитель, который её взял (accepted_by); админ читает
create or replace function am_chat_role(p_id bigint) returns text
language sql stable security definer set search_path = public as $$
  select case
    when r.user_id = auth.uid() then 'client'
    when r.accepted_by is not null and exists (select 1 from am_providers p where p.id = r.accepted_by and p.owner_id = auth.uid()) then 'provider'
    when am_is_admin(r.city) then 'admin'
  end from am_requests r where r.id = p_id;
$$;

drop policy if exists "chat members" on am_messages;
create policy "chat members" on am_messages for select to authenticated using (am_chat_role(request_id) is not null);
revoke all on am_messages from anon;
revoke insert, update, delete on am_messages from authenticated;
grant select on am_messages to authenticated;

create or replace function am_send_message(p_id bigint, p_body text) returns am_messages
language plpgsql security definer set search_path = public as $$
declare role text := am_chat_role(p_id); r am_requests; m am_messages;
begin
  if role is null or role = 'admin' then raise exception 'Чат доступен клиенту и исполнителю, который взял заявку'; end if;
  select * into r from am_requests where id = p_id;
  if r.accepted_by is null then raise exception 'Чат откроется, когда исполнитель возьмёт заявку'; end if;
  if r.status in ('cancelled') or (r.status = 'completed' and r.updated_at < now() - interval '7 days') then raise exception 'Чат по этой заявке закрыт'; end if;
  if coalesce(trim(p_body),'') = '' then raise exception 'Пустое сообщение'; end if;
  if (select count(*) from am_messages where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Слишком много сообщений, подождите минуту'; end if;
  insert into am_messages(request_id, sender_id, from_provider, body) values (p_id, auth.uid(), role = 'provider', left(trim(p_body), 2000))
  returning * into m;
  return m;
end $$;
revoke execute on function am_send_message(bigint, text) from anon;

-- realtime для чата (если публикация есть — в Supabase она есть)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'am_messages') then
    execute 'alter publication supabase_realtime add table am_messages';
  end if;
end $$;

-- ---------- хранилище фото ----------
-- am-photos (закрытый): фото к заявкам, путь req/<uid>/<файл>. Видят автор и исполнители, которым видна заявка.
-- am-public (открытый): фото организаций, путь prov/<provider_id>/<файл>. Загружает владелец или админ.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('am-photos', 'am-photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('am-public', 'am-public', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create or replace function am_can_see_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select split_part(p_name, '/', 2) = auth.uid()::text
      or exists (select 1 from am_requests r where r.details->'photos' ? p_name and am_can_see_request(r.id));
$$;
create or replace function am_can_edit_prov_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when split_part(p_name, '/', 1) = 'prov' and split_part(p_name, '/', 2) ~ '^\d{1,9}$'
    then am_owns(split_part(p_name, '/', 2)::int) or am_is_admin() else false end;
$$;

drop policy if exists "am photos read" on storage.objects;
create policy "am photos read" on storage.objects for select to authenticated
  using (bucket_id = 'am-photos' and am_can_see_photo(name));
drop policy if exists "am photos upload" on storage.objects;
create policy "am photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'am-photos' and split_part(name, '/', 1) = 'req' and split_part(name, '/', 2) = auth.uid()::text);
drop policy if exists "am photos delete" on storage.objects;
create policy "am photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'am-photos' and split_part(name, '/', 2) = auth.uid()::text);
drop policy if exists "am public read" on storage.objects;
create policy "am public read" on storage.objects for select using (bucket_id = 'am-public');
drop policy if exists "am public upload" on storage.objects;
create policy "am public upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'am-public' and am_can_edit_prov_photo(name));
drop policy if exists "am public delete" on storage.objects;
create policy "am public delete" on storage.objects for delete to authenticated
  using (bucket_id = 'am-public' and am_can_edit_prov_photo(name));

grant usage, select on all sequences in schema public to authenticated;
-- =====================================================================
-- АвтоМастер24 · Обновление 4: правовое соответствие РК
--   журнал согласий (версия, время), обращения/жалобы с автоподтверждением
--   и сроком ответа 20 календарных дней, выгрузка «мои данные», удаление
--   аккаунта (обезличивание), счётчик пользователей и отчёт о прозрачности.
-- ТОЛЬКО ДОБАВЛЯЕТ объекты am_*. Чужие таблицы не трогает. Можно запускать повторно.
-- =====================================================================

-- ---------- профиль: версия принятых документов ----------
alter table am_profiles add column if not exists legal_version text;
alter table am_profiles add column if not exists age_confirmed boolean not null default false;
alter table am_profiles add column if not exists deleted_at timestamptz;

-- ---------- журнал согласий (доказательство получения/отзыва согласия) ----------
create table if not exists am_consents (
  id bigserial primary key,
  user_id uuid references am_profiles(id) on delete set null,
  kind text not null check (kind in ('pd','cross_border','terms','age18','provider_offer','marketing')),
  version text not null,
  accepted boolean not null,
  user_agent text default '',
  created_at timestamptz not null default now()
);
create index if not exists am_consents_user on am_consents(user_id, created_at desc);
alter table am_consents enable row level security;
drop policy if exists "own or admin" on am_consents;
create policy "own or admin" on am_consents for select to authenticated using (user_id = auth.uid() or am_is_admin());
revoke insert, update, delete on am_consents from anon, authenticated;

-- принять документы (все отмеченные виды пишутся в журнал)
create or replace function am_accept_legal(p_kinds text[], p_version text, p_ua text default '') returns am_profiles
language plpgsql security definer set search_path = public as $$
declare k text; me am_profiles;
begin
  if auth.uid() is null then raise exception 'Нужно войти'; end if;
  if p_version is null or length(p_version) > 40 then raise exception 'Неверная версия документов'; end if;
  foreach k in array coalesce(p_kinds, '{}') loop
    insert into am_consents(user_id, kind, version, accepted, user_agent)
    values (auth.uid(), k, p_version, true, left(coalesce(p_ua,''), 300));
  end loop;
  if p_kinds @> array['pd','cross_border','terms','age18'] then
    update am_profiles set consent = true, consent_at = now(), legal_version = p_version, age_confirmed = true
    where id = auth.uid();
  end if;
  select * into me from am_profiles where id = auth.uid();
  return me;
end $$;

-- отзыв согласия: прекращаем обработку необязательных данных (телефон), фиксируем в журнале
create or replace function am_withdraw_consent(p_ua text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти'; end if;
  insert into am_consents(user_id, kind, version, accepted, user_agent)
  select auth.uid(), k, coalesce((select legal_version from am_profiles where id = auth.uid()), '-'), false, left(coalesce(p_ua,''),300)
  from unnest(array['pd','cross_border']) k;
  update am_profiles set phone = null, consent = false, legal_version = null where id = auth.uid();
end $$;

-- старая функция «удалить мои данные» теперь тоже пишет журнал
create or replace function am_delete_my_data() returns void
language sql security definer set search_path = public as $$
  select am_withdraw_consent('am_delete_my_data');
$$;

-- ---------- обращения и жалобы (ст. 9, 11, 15 Закона «Об онлайн-платформах…») ----------
create table if not exists am_complaints (
  id bigserial primary key,
  user_id uuid references am_profiles(id) on delete set null,
  target_type text not null check (target_type in ('review','provider','request','message','platform','personal_data','false_info','appeal','other')),
  target_id text default '',
  reason text not null default '',
  body text not null check (char_length(body) between 5 and 3000),
  contact text default '',
  lang text not null default 'ru' check (lang in ('ru','kk')),
  status text not null default 'new' check (status in ('new','in_review','resolved','rejected')),
  answer text,
  answered_by uuid references am_profiles(id) on delete set null,
  due_at timestamptz not null default (now() + interval '20 days'),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
create index if not exists am_complaints_status on am_complaints(status, created_at desc);
alter table am_complaints enable row level security;
drop policy if exists "own or admin" on am_complaints;
create policy "own or admin" on am_complaints for select to authenticated using (user_id = auth.uid() or am_is_admin());
revoke insert, update, delete on am_complaints from anon, authenticated;

-- подать обращение (можно без входа — тогда нужен контакт для ответа). Возвращает автоподтверждение.
create or replace function am_submit_complaint(p_type text, p_target text, p_reason text, p_body text,
  p_contact text default '', p_lang text default 'ru') returns jsonb
language plpgsql security definer set search_path = public as $$
declare c am_complaints;
begin
  if auth.uid() is null and coalesce(trim(p_contact), '') = '' then
    raise exception 'Укажите телефон, e-mail или Telegram для ответа';
  end if;
  if auth.uid() is null and (select count(*) from am_complaints where user_id is null and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Слишком много обращений, попробуйте позже';
  end if;
  if auth.uid() is not null and (select count(*) from am_complaints where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Слишком много обращений, попробуйте позже';
  end if;
  insert into am_complaints(user_id, target_type, target_id, reason, body, contact, lang)
  values (auth.uid(), p_type, left(coalesce(p_target,''), 60), left(coalesce(p_reason,''), 120), trim(p_body),
          left(coalesce(p_contact,''), 120), case when p_lang = 'kk' then 'kk' else 'ru' end)
  returning * into c;
  return jsonb_build_object('id', c.id, 'created_at', c.created_at, 'due_at', c.due_at, 'status', c.status);
end $$;
grant execute on function am_submit_complaint(text, text, text, text, text, text) to anon, authenticated;

-- ответ администратора (мотивированный)
create or replace function am_answer_complaint(p_id bigint, p_status text, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  if p_status not in ('in_review','resolved','rejected') then raise exception 'Неверный статус'; end if;
  if p_status in ('resolved','rejected') and coalesce(trim(p_answer),'') = '' then raise exception 'Нужен мотивированный ответ'; end if;
  update am_complaints set status = p_status, answer = nullif(trim(p_answer),''), answered_by = auth.uid(),
    answered_at = case when p_status in ('resolved','rejected') then now() else answered_at end
  where id = p_id;
end $$;

-- ---------- выгрузка «мои данные» (право субъекта на доступ, ст. 24 Закона о ПД) ----------
create or replace function am_export_my_data() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Нужно войти'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from am_profiles p where id = u),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v)) from am_vehicles v where user_id = u), '[]'),
    'requests', coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from am_requests r where user_id = u), '[]'),
    'reviews', coalesce((select jsonb_agg(to_jsonb(r)) from am_reviews r where user_id = u), '[]'),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('request_id', m.request_id, 'body', m.body, 'created_at', m.created_at)) from am_messages m where sender_id = u), '[]'),
    'registrations', coalesce((select jsonb_agg(to_jsonb(g)) from am_registrations g where user_id = u), '[]'),
    'providers', coalesce((select jsonb_agg(to_jsonb(p)) from am_providers p where owner_id = u), '[]'),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'version', version, 'accepted', accepted, 'at', created_at) order by id) from am_consents where user_id = u), '[]'),
    'complaints', coalesce((select jsonb_agg(to_jsonb(c)) from am_complaints c where user_id = u), '[]')
  );
end $$;

-- ---------- удаление аккаунта: обезличивание (ст. 24, 25 Закона о ПД) ----------
-- Удаляет авто, телефон, имя, Telegram-данные; текст сообщений заменяется на «[удалено]».
-- Заявки и отзывы остаются обезличенными (нужны исполнителям для учёта; отзыв без автора).
-- Учётная запись auth.users удаляется, если у функции хватает прав; иначе создаётся
-- служебное обращение, и администратор удаляет её вручную в течение 1 рабочего дня.
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
  update am_providers set owner_id = null, is_active = false where owner_id = u;
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

-- ---------- счётчик пользователей в РК (ст. 9 п.3 пп.1, п.4 пп.7) — без персональных данных ----------
create table if not exists am_daily_visits (day date primary key, visitors int not null default 0);
alter table am_daily_visits enable row level security;
revoke insert, update, delete on am_daily_visits from anon, authenticated;
drop policy if exists "read" on am_daily_visits;
create policy "read" on am_daily_visits for select using (true);
-- браузер вызывает 1 раз в сутки (флаг в localStorage); IP и идентификаторы не сохраняются
create or replace function am_hit() returns void
language sql security definer set search_path = public as $$
  insert into am_daily_visits(day, visitors) values ((now() at time zone 'Asia/Almaty')::date, 1)
  on conflict (day) do update set visitors = am_daily_visits.visitors + 1;
$$;
grant execute on function am_hit() to anon, authenticated;

-- ---------- отчёт о прозрачности (ст. 9 п.4 пп.7, ст. 13 п.2) ----------
create or replace function am_transparency() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'generated_at', now(),
    'monthly', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'visitors', v, 'avg_daily', a) order by m desc)
      from (select to_char(date_trunc('month', day), 'YYYY-MM') m, sum(visitors) v, round(avg(visitors)) a
            from am_daily_visits where day >= (date_trunc('month', now()) - interval '5 months')::date group by 1) s), '[]'),
    'registered_users', (select count(*) from am_profiles where deleted_at is null),
    'providers_active', (select count(*) from am_providers where is_active),
    'complaints_total', (select count(*) from am_complaints where created_at > now() - interval '1 year'),
    'complaints_resolved', (select count(*) from am_complaints where status in ('resolved','rejected') and created_at > now() - interval '1 year'),
    'complaints_overdue', (select count(*) from am_complaints where status in ('new','in_review') and due_at < now()),
    'reviews_published', (select count(*) from am_reviews where is_published),
    'reviews_hidden', (select count(*) from am_reviews where not is_published)
  );
$$;
grant execute on function am_transparency() to anon, authenticated;

-- права на функции
revoke execute on function am_accept_legal(text[], text, text), am_withdraw_consent(text), am_answer_complaint(bigint, text, text),
  am_export_my_data(), am_delete_my_account(text) from anon;
grant execute on function am_accept_legal(text[], text, text), am_withdraw_consent(text), am_answer_complaint(bigint, text, text),
  am_export_my_data(), am_delete_my_account(text) to authenticated;
grant select on am_consents, am_complaints to authenticated;
grant select on am_daily_visits to anon, authenticated;

notify pgrst, 'reload schema';
