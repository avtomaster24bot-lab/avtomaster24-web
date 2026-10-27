#!/usr/bin/env bash
# Локальная проверка схемы и бизнес-логики на чистом PostgreSQL (без Supabase)
set -euo pipefail
cd "$(dirname "$0")/.."
DB=am24_test
sudo -u postgres dropdb --if-exists $DB; sudo -u postgres createdb $DB
for f in tests/local_shim.sql supabase/01_schema.sql supabase/02_seed.sql supabase/01_schema.sql supabase/03_features.sql tests/flow_test.sql supabase/03_features.sql tests/features_test.sql supabase/04_legal.sql tests/legal_test.sql supabase/04_legal.sql supabase/05_testing.sql supabase/07_fixes.sql tests/testing_test.sql supabase/05_testing.sql supabase/07_fixes.sql supabase/08_admin.sql tests/admin_test.sql supabase/08_admin.sql supabase/09_roles_fix.sql tests/roles_fix_test.sql supabase/09_roles_fix.sql supabase/10_reviews.sql tests/reviews_test.sql supabase/10_reviews.sql; do
  cp "$f" /tmp/am24_$(basename "$f"); sudo -u postgres env PGOPTIONS="-c client_min_messages=notice" psql -q -t -A -v ON_ERROR_STOP=1 -d $DB -f /tmp/am24_$(basename "$f") | grep -v '^$' || true
done
