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
