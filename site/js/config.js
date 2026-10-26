// ============================================================
//  НАСТРОЙКИ САЙТА АвтоМастер24 — меняйте только этот файл
// ============================================================
// Здесь только ПУБЛИЧНЫЕ данные. Токен бота и service_role ключ сюда НЕ вставлять никогда!
// Сайт сам проверяет базу: если таблицы am_* в Supabase ещё не созданы — работает ДЕМО-режим
// (всё кликается, данные хранятся только в этом браузере).
export const CONFIG = {
  SITE_NAME: 'АвтоМастер24',
  SITE_TAGLINE: 'СТО, эвакуатор, мойка, запчасти и выездные мастера — в одном месте',

  // Supabase (тот же проект, что у VeloMarket). anon-ключ публичный, защита — RLS в базе.
  SUPABASE_URL: 'https://wzhwnffdylhkmapijkrn.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6aHduZmZkeWxoa21hcGlqa3JuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzNDg3NjEsImV4cCI6MjA5MTkyNDc2MX0.G7Ieq0C-FECBFaC5y5ks5tv5KApUqY_S7pH-P8sHXCs',

  // Вход через Telegram: функция проверки подписи и бот, токеном которого она проверяет подпись.
  // Сейчас используется уже работающая функция VeloMarket (бот VeloMaster24bot, домен github.io уже привязан).
  // Чтобы входить через бота АвтоМастер24 — см. README, раздел «Свой бот для входа».
  TELEGRAM_AUTH_URL: 'https://wzhwnffdylhkmapijkrn.supabase.co/functions/v1/telegram-auth',
  TELEGRAM_LOGIN_BOT: 'VeloMaster24bot',

  // Основной Telegram-бот сервиса (кнопка «Открыть бота»)
  TELEGRAM_BOT: 'TochkaSborki_A24_bot',

  DEFAULT_CITY: 'Талдыкорган',
  FORCE_DEMO: false,          // true — всегда демо-режим
  REFRESH_SECONDS: 20,        // как часто обновлять ленту заявок у исполнителя

  // Правовое (Обновление 4). При изменении текстов документов увеличьте версию — пользователи примут их заново.
  LEGAL_VERSION: '2026-10-26',
  // Реквизиты оператора — ЗАПОЛНИТЬ после регистрации ИП/ТОО (также в tools/legal_ru.py и legal_kk.py)
  OPERATOR: '[ЗАПОЛНИТЬ: ИП/ТОО, БИН]',
};
