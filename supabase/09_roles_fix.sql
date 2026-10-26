-- =====================================================================
--  АвтоМастер24 — Обновление 6.1: исправление проверок прав (NULL-безопасность).
--  В 08_admin.sql часть проверок вида «not (роль in (...) or ...)» при роли NULL
--  (посторонний пользователь) давала NULL, и исключение не срабатывало.
--  Применять после 08_admin.sql. Только am_*, повторный запуск безопасен.
-- =====================================================================

create or replace function am_staff_remove(p_provider int, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(am_staff_role(p_provider) = 'owner' or (p_user = auth.uid() and am_staff_role(p_provider) in ('manager','master')), false) then raise exception 'Нет прав'; end if;
  delete from am_provider_staff where provider_id = p_provider and user_id = p_user;
  update am_requests set assigned_to = null where accepted_by = p_provider and assigned_to = p_user and status not in ('completed','cancelled');
  perform am_log('staff_remove', p_user, am_provider_city(p_provider), jsonb_build_object('provider', p_provider));
end $$;

create or replace function am_staff_list(p_provider int) returns table(user_id uuid, username text, full_name text, role text, created_at timestamptz, handled bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(am_staff_role(p_provider) in ('owner','manager'), false) and not coalesce(am_is_admin(am_provider_city(p_provider)), false) then raise exception 'Нет прав'; end if;
  return query
    select o.owner_id, pr.username, pr.full_name, 'owner'::text, o.created_at, (select count(*) from am_requests r where r.accepted_by = o.id and r.handled_by = o.owner_id)
      from am_providers o join am_profiles pr on pr.id = o.owner_id where o.id = p_provider
    union all
    select s.user_id, pr.username, pr.full_name, s.role, s.created_at, (select count(*) from am_requests r where r.accepted_by = s.provider_id and (r.handled_by = s.user_id or r.assigned_to = s.user_id))
      from am_provider_staff s join am_profiles pr on pr.id = s.user_id where s.provider_id = p_provider;
end $$;
revoke execute on function am_staff_add(int, text, text), am_staff_remove(int, uuid), am_staff_list(int) from anon;

create or replace function am_request_staff(p_id bigint) returns table(handled_by_name text, assigned_to_name text, assigned_to uuid)
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id;
  if not found or not coalesce(am_staff_role(r.accepted_by) in ('owner','manager','master') or am_is_admin(r.city), false) then raise exception 'Нет прав'; end if;
  return query select (select coalesce(nullif(full_name, ''), username) from am_profiles where id = r.handled_by),
                      (select coalesce(nullif(full_name, ''), username) from am_profiles where id = r.assigned_to), r.assigned_to;
end $$;
revoke execute on function am_request_staff(bigint) from anon;

create or replace function am_assign_request(p_id bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id for update;
  if not found or r.accepted_by is null or not coalesce(am_staff_role(r.accepted_by) in ('owner','manager'), false) then raise exception 'Нет прав'; end if;
  if r.status in ('completed','cancelled') then raise exception 'Заявка закрыта'; end if;
  if p_user is not null and not exists (select 1 from am_provider_staff where provider_id = r.accepted_by and user_id = p_user)
     and p_user <> (select owner_id from am_providers where id = r.accepted_by) then raise exception 'Это не сотрудник организации'; end if;
  update am_requests set assigned_to = p_user, updated_at = now() where id = p_id;
end $$;
revoke execute on function am_assign_request(bigint, uuid) from anon;

create or replace function am_client_contact(p_id bigint) returns table(full_name text, phone text, username text)
language plpgsql security definer set search_path = public as $$
declare r am_requests;
begin
  select * into r from am_requests where id = p_id;
  if not found or not coalesce(am_staff_role(r.accepted_by) in ('owner','manager') or (r.assigned_to = auth.uid() and am_staff_role(r.accepted_by) = 'master')
                       or am_is_admin(r.city), false) then raise exception 'Контакт доступен после принятия заявки'; end if;
  if r.type = 'wash' and r.status in ('new','price_offered') and not am_is_admin(r.city) then raise exception 'Контакт доступен после подтверждения клиентом'; end if;
  return query select pr.full_name, pr.phone, pr.username from am_profiles pr where pr.id = r.user_id;
end $$;

create or replace function am_reply_review(p_id bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare rv am_reviews;
begin
  select * into rv from am_reviews where id = p_id;
  if not found or not coalesce(am_staff_role(rv.provider_id) in ('owner','manager') or am_is_admin(am_provider_city(rv.provider_id)), false) then raise exception 'Нет прав'; end if;
  update am_reviews set reply = nullif(left(trim(coalesce(p_text,'')), 1000), ''), reply_at = now() where id = p_id;
end $$;
revoke execute on function am_reply_review(bigint, text) from anon;
