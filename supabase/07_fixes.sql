-- АвтоМастер24 — Обновление 5.1: исправления по итогам боевых автотестов. Только объекты am_*, повторный запуск безопасен.
-- 1) Гость видел цены и отзывы тестовых организаций: проверка «организация тестовая?» внутри политики
--    выполнялась с правами гостя, а он тестовую организацию не видит → условие «нет такой тестовой» было истинным.
--    Теперь проверка — через функцию с правами владельца.
-- 2) Рейтинг и число отзывов организации никогда не пересчитывались: защитный триггер организаций
--    отменял изменение rating/reviews_count, сделанное от имени клиента. Теперь пересчёт — служебное изменение.

create or replace function am_provider_is_test(p_id int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_test from am_providers where id = p_id), false);
$$;
grant execute on function am_provider_is_test(int) to anon, authenticated;

drop policy if exists "read" on am_prices;
create policy "read" on am_prices for select using (
  provider_id is null or not am_provider_is_test(provider_id) or am_viewer_is_test() or am_is_admin());

drop policy if exists "published or own" on am_reviews;
create policy "published or own" on am_reviews for select using (
  (is_published and (not am_provider_is_test(provider_id) or am_viewer_is_test()))
  or user_id = auth.uid() or am_is_admin(am_provider_city(provider_id)));

create or replace function am_recalc_rating(p_provider int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('am.sys', 'on', true);
  update am_providers set rating = coalesce((select round(avg(rating)::numeric, 2) from am_reviews where provider_id = p_provider), 0),
    reviews_count = (select count(*) from am_reviews where provider_id = p_provider) where id = p_provider;
  perform set_config('am.sys', '', true);
end $$;

-- пересчитать рейтинги, которые не обновились раньше
do $$ declare x int; begin
  for x in select id from am_providers loop perform am_recalc_rating(x); end loop;
end $$;

notify pgrst, 'reload schema';
