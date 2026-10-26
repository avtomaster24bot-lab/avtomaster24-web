-- АвтоМастер24 — Обновление 6: роли и настройки.
--   * главный админ: админы и права, настройки платформы, все города, пользователи (блокировка), журнал;
--   * региональный админ: всё то же в пределах своего города (без назначения админов и общих лимитов);
--   * исполнитель: «Настройки организации» — пауза приёма, выходные, сотрудники (менеджер / мастер), кто принял заявку;
--   * заблокированный пользователь не создаёт заявки, отзывы, сообщения и заявки на бизнес (обращения — может).
-- Только объекты am_*, повторный запуск безопасен. Применять после 01–05 и 07.

-- ---------------------------------------------------------------- колонки
alter table am_profiles  add column if not exists blocked_at timestamptz;
alter table am_profiles  add column if not exists blocked_reason text;
alter table am_providers add column if not exists paused boolean not null default false;
alter table am_providers add column if not exists days_off int[] not null default '{}';     -- 0=вс … 6=сб
alter table am_requests  add column if not exists handled_by uuid references am_profiles(id) on delete set null;   -- кто принял
alter table am_requests  add column if not exists assigned_to uuid references am_profiles(id) on delete set null;  -- кому поручено

-- ---------------------------------------------------------------- журнал действий администраторов и владельцев
create table if not exists am_admin_log (
  id bigserial primary key,
  actor_id uuid references am_profiles(id) on delete set null,
  action text not null,
  target_user uuid references am_profiles(id) on delete set null,
  city text,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists am_admin_log_created_idx on am_admin_log(created_at desc);
alter table am_admin_log enable row level security;
drop policy if exists "admins" on am_admin_log;
create policy "admins" on am_admin_log for select to authenticated using (am_is_global_admin() or (city is not null and am_is_admin(city)));
revoke insert, update, delete on am_admin_log from anon, authenticated;
grant select on am_admin_log to authenticated;

create or replace function am_log(p_action text, p_target uuid, p_city text, p_details jsonb default '{}') returns void
language sql security definer set search_path = public as $$
  insert into am_admin_log(actor_id, action, target_user, city, details) values (auth.uid(), p_action, p_target, p_city, coalesce(p_details, '{}'));
$$;
revoke execute on function am_log(text, uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- настройки (общие и по городу)
create table if not exists am_settings (
  key text not null, city text not null default '', value jsonb not null,
  updated_by uuid references am_profiles(id) on delete set null, updated_at timestamptz not null default now(),
  primary key (key, city)
);
alter table am_settings enable row level security;
drop policy if exists "read" on am_settings;
create policy "read" on am_settings for select using (true);
revoke insert, update, delete on am_settings from anon, authenticated;
grant select on am_settings to anon, authenticated;

-- допустимые ключи: [тип, мин, макс, можно ли для города]
create or replace function am_setting_spec(p_key text) returns jsonb language sql immutable as $$
  select case p_key
    when 'ttl_sto' then '{"min":10,"max":1440,"city":true}'
    when 'ttl_tow' then '{"min":10,"max":1440,"city":true}'
    when 'ttl_urgent' then '{"min":10,"max":1440,"city":true}'
    when 'ttl_parts' then '{"min":30,"max":4320,"city":true}'
    when 'max_open_requests' then '{"min":1,"max":100,"city":false}'
    when 'max_requests_hour' then '{"min":1,"max":200,"city":false}'
    when 'city_notice' then '{"text":true,"city":true}'
  end::jsonb $$;

create or replace function am_setting(p_key text, p_city text default '') returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value from am_settings where key = p_key and city = coalesce(p_city, '') and coalesce(p_city, '') <> ''),
                  (select value from am_settings where key = p_key and city = ''));
$$;
grant execute on function am_setting(text, text) to anon, authenticated;

create or replace function am_set_setting(p_key text, p_city text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare sp jsonb := am_setting_spec(p_key); c text := coalesce(p_city, ''); n numeric;
begin
  if sp is null then raise exception 'Неизвестная настройка'; end if;
  if c = '' and not am_is_global_admin() then raise exception 'Общие настройки меняет только главный администратор'; end if;
  if c <> '' and (not (sp->>'city')::boolean) then raise exception 'Эта настройка общая для всех городов'; end if;
  if c <> '' and not am_is_admin(c) then raise exception 'Нет прав на этот город'; end if;
  if p_value is null or p_value = 'null'::jsonb then
    delete from am_settings where key = p_key and city = c;
  elsif sp ? 'text' then
    if jsonb_typeof(p_value) <> 'string' or char_length(p_value #>> '{}') > 500 then raise exception 'Текст до 500 символов'; end if;
    insert into am_settings(key, city, value, updated_by) values (p_key, c, p_value, auth.uid())
    on conflict (key, city) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  else
    n := (p_value #>> '{}')::numeric;
    if n is null or n <> trunc(n) or n < (sp->>'min')::int or n > (sp->>'max')::int then
      raise exception 'Значение от % до %', sp->>'min', sp->>'max'; end if;
    insert into am_settings(key, city, value, updated_by) values (p_key, c, to_jsonb(n::int), auth.uid())
    on conflict (key, city) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  end if;
  perform am_log('setting', null, nullif(c, ''), jsonb_build_object('key', p_key, 'value', p_value));
end $$;
revoke execute on function am_set_setting(text, text, jsonb) from anon;

-- ---------------------------------------------------------------- блокировка
create or replace function am_is_blocked(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select blocked_at is not null from am_profiles where id = p_user), false);
$$;

create or replace function am_block_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare u uuid := coalesce(to_jsonb(new)->>'sender_id', to_jsonb(new)->>'user_id')::uuid;
begin
  if am_is_blocked(u) then raise exception 'Аккаунт заблокирован администратором. Обжаловать: раздел «Жалоба / обращение»'; end if;
  return new;
end $$;
drop trigger if exists am_block_guard on am_reviews;
create trigger am_block_guard before insert on am_reviews for each row execute function am_block_guard();
drop trigger if exists am_block_guard on am_messages;
create trigger am_block_guard before insert on am_messages for each row execute function am_block_guard();
drop trigger if exists am_block_guard on am_registrations;
create trigger am_block_guard before insert on am_registrations for each row execute function am_block_guard();

create or replace function am_admin_block(p_user uuid, p_block boolean, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u am_profiles;
begin
  select * into u from am_profiles where id = p_user;
  if not found then raise exception 'Пользователь не найден'; end if;
  if not (am_is_global_admin() or (u.city is not null and am_is_admin(u.city))) then raise exception 'Нет прав'; end if;
  if p_user = auth.uid() then raise exception 'Нельзя заблокировать себя'; end if;
  if u.role <> 'client' then raise exception 'Сначала снимите с пользователя права администратора'; end if;
  if p_block and coalesce(trim(p_reason), '') = '' then raise exception 'Укажите причину блокировки'; end if;
  update am_profiles set blocked_at = case when p_block then now() end, blocked_reason = case when p_block then left(trim(p_reason), 300) end where id = p_user;
  perform am_log(case when p_block then 'block' else 'unblock' end, p_user, u.city, jsonb_build_object('reason', p_reason));
end $$;
revoke execute on function am_admin_block(uuid, boolean, text) from anon;

-- ---------------------------------------------------------------- админы и права
create or replace function am_admin_set_role(p_user uuid, p_role text, p_city text default null) returns text
language plpgsql security definer set search_path = public as $$
declare u am_profiles;
begin
  if not am_is_global_admin() then raise exception 'Назначать администраторов может только главный администратор'; end if;
  if p_role not in ('client','regional_admin','global_admin') then raise exception 'Неизвестная роль'; end if;
  select * into u from am_profiles where id = p_user;
  if not found or u.deleted_at is not null then raise exception 'Пользователь не найден'; end if;
  if u.blocked_at is not null and p_role <> 'client' then raise exception 'Пользователь заблокирован'; end if;
  if p_role = 'regional_admin' and not exists (select 1 from am_cities where name = p_city) then raise exception 'Выберите город'; end if;
  if u.role = 'global_admin' and p_role <> 'global_admin'
     and (select count(*) from am_profiles where role = 'global_admin' and deleted_at is null) <= 1 then
    raise exception 'Нельзя снять последнего главного администратора';
  end if;
  update am_profiles set role = p_role, managed_city = case when p_role = 'regional_admin' then p_city end where id = p_user;
  perform am_log('role', p_user, case when p_role = 'regional_admin' then p_city end,
    jsonb_build_object('from', u.role, 'to', p_role, 'city', p_city, 'username', u.username));
  return 'Готово';
end $$;
revoke execute on function am_admin_set_role(uuid, text, text) from anon;

create or replace function am_admin_list() returns table(id uuid, username text, full_name text, role text, managed_city text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  return query select p.id, p.username, p.full_name, p.role, p.managed_city, p.created_at from am_profiles p
    where p.role in ('global_admin','regional_admin') and p.deleted_at is null order by p.role, p.managed_city, p.username;
end $$;
revoke execute on function am_admin_list() from anon;

-- пользователи: главный — все, региональный — своего города
create or replace function am_admin_users(p_q text default '', p_limit int default 50)
returns table(id uuid, username text, full_name text, phone text, city text, role text, managed_city text, is_test boolean,
              blocked_at timestamptz, blocked_reason text, created_at timestamptz, requests bigint, orgs bigint)
language plpgsql security definer set search_path = public as $$
declare q text := '%' || lower(trim(coalesce(p_q, ''))) || '%'; qd text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not am_is_admin() then raise exception 'Нет прав'; end if;
  return query select p.id, p.username, p.full_name, p.phone, p.city, p.role, p.managed_city, p.is_test, p.blocked_at, p.blocked_reason, p.created_at,
      (select count(*) from am_requests r where r.user_id = p.id), (select count(*) from am_providers o where o.owner_id = p.id)
    from am_profiles p
    where p.deleted_at is null and (am_is_global_admin() or am_is_admin(p.city))
      and (coalesce(trim(p_q), '') = '' or lower(coalesce(p.username, '')) like q or lower(coalesce(p.full_name, '')) like q
           or (length(qd) >= 4 and regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') like '%' || qd || '%'))
    order by p.created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;
revoke execute on function am_admin_users(text, int) from anon;

-- ---------------------------------------------------------------- сотрудники организации
create table if not exists am_provider_staff (
  provider_id int not null references am_providers(id) on delete cascade,
  user_id uuid not null references am_profiles(id) on delete cascade,
  role text not null check (role in ('manager','master')),
  added_by uuid references am_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (provider_id, user_id)
);
create index if not exists am_provider_staff_user_idx on am_provider_staff(user_id);
alter table am_provider_staff enable row level security;
revoke insert, update, delete on am_provider_staff from anon, authenticated;

-- роль текущего пользователя в организации: owner / manager / master / null (заблокированный — null)
create or replace function am_staff_role(p_provider int) returns text
language sql stable security definer set search_path = public as $$
  select case when am_is_blocked(auth.uid()) then null
    when exists (select 1 from am_providers where id = p_provider and owner_id = auth.uid()) then 'owner'
    else (select role from am_provider_staff where provider_id = p_provider and user_id = auth.uid()) end;
$$;
grant execute on function am_staff_role(int) to authenticated;

drop policy if exists "org members" on am_provider_staff;
create policy "org members" on am_provider_staff for select to authenticated
  using (user_id = auth.uid() or am_staff_role(provider_id) in ('owner','manager') or am_is_admin(am_provider_city(provider_id)));
grant select on am_provider_staff to authenticated;

create or replace function am_staff_add(p_provider int, p_username text, p_role text) returns text
language plpgsql security definer set search_path = public as $$
declare u am_profiles; p am_providers;
begin
  select * into p from am_providers where id = p_provider;
  if not found or am_staff_role(p_provider) is distinct from 'owner' then raise exception 'Сотрудников добавляет только владелец'; end if;
  if p_role not in ('manager','master') then raise exception 'Роль: менеджер или мастер'; end if;
  select * into u from am_profiles where lower(username) = lower(trim(leading '@' from trim(coalesce(p_username, '')))) and deleted_at is null;
  if not found then raise exception 'Пользователь не найден: пусть сначала войдёт на сайт через Telegram'; end if;
  if u.id = auth.uid() then raise exception 'Вы уже владелец'; end if;
  if u.blocked_at is not null then raise exception 'Пользователь заблокирован'; end if;
  if u.is_test <> p.is_test then raise exception 'Пользователь недоступен'; end if;
  if (select count(*) from am_provider_staff where provider_id = p_provider) >= 30 then raise exception 'Не больше 30 сотрудников'; end if;
  insert into am_provider_staff(provider_id, user_id, role, added_by) values (p_provider, u.id, p_role, auth.uid())
  on conflict (provider_id, user_id) do update set role = excluded.role;
  perform am_log('staff_add', u.id, p.city, jsonb_build_object('provider', p_provider, 'role', p_role));
  return 'Готово';
end $$;
create or replace function am_staff_remove(p_provider int, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (am_staff_role(p_provider) = 'owner' or (p_user = auth.uid() and am_staff_role(p_provider) in ('manager','master'))) then raise exception 'Нет прав'; end if;
  delete from am_provider_staff where provider_id = p_provider and user_id = p_user;
  update am_requests set assigned_to = null where accepted_by = p_provider and assigned_to = p_user and status not in ('completed','cancelled');
  perform am_log('staff_remove', p_user, am_provider_city(p_provider), jsonb_build_object('provider', p_provider));
end $$;
create or replace function am_staff_list(p_provider int) returns table(user_id uuid, username text, full_name text, role text, created_at timestamptz, handled bigint)
language plpgsql security definer set search_path = public as $$
begin
  if am_staff_role(p_provider) not in ('owner','manager') and not am_is_admin(am_provider_city(p_provider)) then raise exception 'Нет прав'; end if;
  return query
    select o.owner_id, pr.username, pr.full_name, 'owner'::text, o.created_at, (select count(*) from am_requests r where r.accepted_by = o.id and r.handled_by = o.owner_id)
      from am_providers o join am_profiles pr on pr.id = o.owner_id where o.id = p_provider
    union all
    select s.user_id, pr.username, pr.full_name, s.role, s.created_at, (select count(*) from am_requests r where r.accepted_by = s.provider_id and (r.handled_by = s.user_id or r.assigned_to = s.user_id))
      from am_provider_staff s join am_profiles pr on pr.id = s.user_id where s.provider_id = p_provider;
end $$;
revoke execute on function am_staff_add(int, text, text), am_staff_remove(int, uuid), am_staff_list(int) from anon;

-- мои организации (владелец и сотрудник) с ролью
create or replace function am_my_orgs() returns table(org jsonb, my_role text)
language sql stable security definer set search_path = public as $$
  select to_jsonb(p), am_staff_role(p.id) from am_providers p
  where p.owner_id = auth.uid() or exists (select 1 from am_provider_staff s where s.provider_id = p.id and s.user_id = auth.uid())
  order by p.id;
$$;
revoke execute on function am_my_orgs() from anon;
grant execute on function am_my_orgs() to authenticated;

-- кто принял заявку и кому поручено (имена для владельца/менеджера)
create or replace function am_request_staff(p_id bigint) returns table(handled_by_name text, assigned_to_name text, assigned_to uuid)
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id;
  if not found or not (am_staff_role(r.accepted_by) in ('owner','manager','master') or am_is_admin(r.city)) then raise exception 'Нет прав'; end if;
  return query select (select coalesce(nullif(full_name, ''), username) from am_profiles where id = r.handled_by),
                      (select coalesce(nullif(full_name, ''), username) from am_profiles where id = r.assigned_to), r.assigned_to;
end $$;
revoke execute on function am_request_staff(bigint) from anon;

create or replace function am_assign_request(p_id bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is null or am_staff_role(r.accepted_by) not in ('owner','manager') then raise exception 'Нет прав'; end if;
  if r.status in ('completed','cancelled') then raise exception 'Заявка закрыта'; end if;
  if p_user is not null and not exists (select 1 from am_provider_staff where provider_id = r.accepted_by and user_id = p_user)
     and p_user <> (select owner_id from am_providers where id = r.accepted_by) then raise exception 'Это не сотрудник организации'; end if;
  update am_requests set assigned_to = p_user, updated_at = now() where id = p_id;
end $$;
revoke execute on function am_assign_request(bigint, uuid) from anon;

-- кто принял: запоминаем при первом назначении исполнителя
create or replace function am_requests_handled_by() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.accepted_by is not null and old.accepted_by is null and new.handled_by is null and auth.uid() <> new.user_id then new.handled_by := auth.uid(); end if;
  if new.accepted_by is distinct from old.accepted_by and new.accepted_by is not null and new.handled_by is null then
    new.handled_by := (select owner_id from am_providers where id = new.accepted_by);   -- выбор предложения клиентом
  end if;
  return new;
end $$;
drop trigger if exists am_requests_handled_by on am_requests;
create trigger am_requests_handled_by before update on am_requests for each row execute function am_requests_handled_by();

-- ---------------------------------------------------------------- права исполнителя с учётом сотрудников
-- владелец и менеджер работают с заявками от имени организации
create or replace function am_my_provider(p_provider int) returns am_providers
language plpgsql security definer set search_path = public as $$
declare p am_providers;
begin
  select * into p from am_providers where id = p_provider and am_staff_role(p_provider) in ('owner','manager');
  if not found then raise exception 'Это не ваша организация'; end if;
  if not p.is_active then raise exception 'Организация отключена администратором'; end if;
  return p;
end $$;

-- подбор: организация на паузе новые заявки не получает
create or replace function am_matches(r am_requests, p am_providers) returns boolean
language sql stable security definer set search_path = public as $$
  select p.is_active and not p.paused and p.kind = r.type and p.city = r.city
    and p.is_test = coalesce((select pr.is_test from am_profiles pr where pr.id = r.user_id), false)
    and (r.target_provider_id is null or r.target_provider_id = p.id)
    and (r.type <> 'urgent' or r.service_type is null or r.service_type = p.service_type)
    and (r.type <> 'parts' or r.supplier_type is null or r.supplier_type = p.supplier_type)
    and (r.type <> 'sto' or r.category_id is null or cardinality(p.specs) = 0 or r.category_id = any(p.specs) or r.target_provider_id = p.id);
$$;

create or replace function am_can_see_request(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from am_requests r where r.id = p_id and (
    r.user_id = auth.uid() or am_is_admin(r.city) or r.assigned_to = auth.uid()
    or am_staff_role(r.accepted_by) in ('owner','manager') or am_staff_role(r.target_provider_id) in ('owner','manager')
    or (r.status in ('new','offers') and (r.expires_at is null or r.expires_at > now())
        and exists (select 1 from am_providers p where am_staff_role(p.id) in ('owner','manager') and am_matches(r, p)
                    and not exists (select 1 from am_declines d where d.request_id = r.id and d.provider_id = p.id)))));
$$;

-- лента: владелец/менеджер — вся; мастер — только порученные ему
create or replace function am_provider_feed(p_provider int) returns setof am_requests
language plpgsql security definer set search_path = public as $$
declare role text := am_staff_role(p_provider); p am_providers;
begin
  if role = 'master' then
    return query select r.* from am_requests r where r.accepted_by = p_provider and r.assigned_to = auth.uid() order by r.created_at desc limit 200;
    return;
  end if;
  p := am_my_provider(p_provider);
  return query select r.* from am_requests r
  where r.accepted_by = p.id or r.target_provider_id = p.id
     or (r.status in ('new','offers') and (r.expires_at is null or r.expires_at > now()) and am_matches(r, p)
         and not exists (select 1 from am_declines d where d.request_id = r.id and d.provider_id = p.id))
  order by r.created_at desc limit 200;
end $$;

-- завершить может владелец, менеджер или мастер, которому поручено
create or replace function am_complete_request(p_id bigint, p_provider int, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests; role text := am_staff_role(p_provider);
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is distinct from p_provider or role is null
     or (role = 'master' and r.assigned_to is distinct from auth.uid()) then raise exception 'Заявка не ваша'; end if;
  if not (select is_active from am_providers where id = p_provider) then raise exception 'Организация отключена администратором'; end if;
  if r.type = 'parts' then
    if r.status <> 'active' then raise exception 'Неверный статус'; end if;
    update am_requests set status = 'delivered', updated_at = now() where id = p_id;
  else
    if r.status not in ('active','in_progress','waiting_client','client_approved') then raise exception 'Неверный статус'; end if;
    update am_requests set status = 'completed', final_amount = coalesce(p_amount, final_amount), updated_at = now() where id = p_id;
  end if;
end $$;

create or replace function am_wash_status(p_id bigint, p_provider int, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests; role text := am_staff_role(p_provider);
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is distinct from p_provider or r.type <> 'wash' or role is null
     or (role = 'master' and r.assigned_to is distinct from auth.uid()) then raise exception 'Заявка не ваша'; end if;
  if not ((r.status = 'client_approved' and p_status = 'in_progress') or (r.status = 'in_progress' and p_status = 'waiting_client')
       or (r.status in ('waiting_client','in_progress') and p_status = 'completed')) then raise exception 'Неверный переход статуса'; end if;
  update am_requests set status = p_status, updated_at = now() where id = p_id;
end $$;

-- чат: владелец, менеджер и мастер, которому поручено
create or replace function am_chat_role(p_id bigint) returns text
language sql stable security definer set search_path = public as $$
  select case
    when r.user_id = auth.uid() then 'client'
    when r.accepted_by is not null and (am_staff_role(r.accepted_by) in ('owner','manager') or (r.assigned_to = auth.uid() and am_staff_role(r.accepted_by) = 'master')) then 'provider'
    when am_is_admin(r.city) then 'admin'
  end from am_requests r where r.id = p_id;
$$;

create or replace function am_client_contact(p_id bigint) returns table(full_name text, phone text, username text)
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id;
  if not found or not (am_staff_role(r.accepted_by) in ('owner','manager') or (r.assigned_to = auth.uid() and am_staff_role(r.accepted_by) = 'master')
                       or am_is_admin(r.city)) then raise exception 'Контакт доступен после принятия заявки'; end if;
  if r.type = 'wash' and r.status in ('new','price_offered') and not am_is_admin(r.city) then raise exception 'Контакт доступен после подтверждения клиентом'; end if;
  return query select pr.full_name, pr.phone, pr.username from am_profiles pr where pr.id = r.user_id;
end $$;

create or replace function am_reply_review(p_id bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or not (am_staff_role(rv.provider_id) in ('owner','manager') or am_is_admin(am_provider_city(rv.provider_id))) then raise exception 'Нет прав'; end if;
  update am_reviews set reply = nullif(left(trim(coalesce(p_text,'')), 1000), ''), reply_at = now() where id = p_id;
end $$;
revoke execute on function am_reply_review(bigint, text) from anon;

drop policy if exists "provider or admin" on am_offers;
create policy "provider or admin" on am_offers for select to authenticated using (am_staff_role(provider_id) in ('owner','manager') or am_is_admin(am_provider_city(provider_id)));
drop policy if exists "own provider" on am_declines;
create policy "own provider" on am_declines for select to authenticated using (am_staff_role(provider_id) in ('owner','manager'));

-- ---------------------------------------------------------------- антиспам и срок заявки из настроек; блокировка
create or replace function am_requests_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare mo int := coalesce((am_setting('max_open_requests') #>> '{}')::int, 10);
        mh int := coalesce((am_setting('max_requests_hour') #>> '{}')::int, 20);
        ttl int;
begin
  if am_is_blocked(new.user_id) then raise exception 'Аккаунт заблокирован администратором. Обжаловать: раздел «Жалоба / обращение»'; end if;
  if (select count(*) from am_requests where user_id = new.user_id and status in ('new','offers')
        and (expires_at is null or expires_at > now())) >= mo then
    raise exception 'Слишком много открытых заявок — дождитесь ответа или отмените лишние';
  end if;
  if (select count(*) from am_requests where user_id = new.user_id and created_at > now() - interval '1 hour') >= mh then
    raise exception 'Слишком много заявок за час — попробуйте позже';
  end if;
  if new.type <> 'wash' then
    ttl := (am_setting('ttl_' || new.type, new.city) #>> '{}')::int;
    if ttl is not null then new.expires_at := now() + make_interval(mins => ttl); end if;
  end if;
  return new;
end $$;

-- журнал: действия админов над организациями и регистрациями
create or replace function am_providers_admin_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and am_is_admin(new.city) and (new.is_active is distinct from old.is_active or new.verified is distinct from old.verified) then
    perform am_log('provider', new.owner_id, new.city, jsonb_build_object('provider', new.id, 'name', new.name, 'is_active', new.is_active, 'verified', new.verified));
  end if;
  return null;
end $$;
drop trigger if exists am_providers_admin_log on am_providers;
create trigger am_providers_admin_log after update on am_providers for each row execute function am_providers_admin_log();

create or replace function am_registrations_admin_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status and auth.uid() is not null then
    perform am_log('registration', new.user_id, new.city, jsonb_build_object('name', new.name, 'status', new.status, 'reason', new.reason));
  end if;
  return null;
end $$;
drop trigger if exists am_registrations_admin_log on am_registrations;
create trigger am_registrations_admin_log after update on am_registrations for each row execute function am_registrations_admin_log();

-- удалённый пользователь перестаёт быть сотрудником
create or replace function am_profiles_staff_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then delete from am_provider_staff where user_id = new.id; end if;
  return null;
end $$;
drop trigger if exists am_profiles_staff_cleanup on am_profiles;
create trigger am_profiles_staff_cleanup after update on am_profiles for each row execute function am_profiles_staff_cleanup();

notify pgrst, 'reload schema';
