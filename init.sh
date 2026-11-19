#!/bin/sh
set -eu

# Универсальный инициализатор ролей/БД PostgreSQL.
# Одна роль + одна БД. Параметры задаются переменными среды, поэтому
# один и тот же скрипт используется для любого сервиса (litellm,
# open-webui, kryton, ...) — достаточно запустить образ infra/pg-init
# с нужными переменными.
#
#   Админ-подключение (к серверу postgres):
#     PG_HOST, PG_PORT, PG_ADMIN_USER, PG_ADMIN_PASSWORD, PG_ADMIN_DB
#   Что создать:
#     PG_ROLE, PG_ROLE_PASSWORD, PG_DB_NAME

: "${PG_HOST:=postgres}"
: "${PG_PORT:=5432}"
: "${PG_ADMIN_USER:?PG_ADMIN_USER (админ) обязателен}"
: "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD (админ) обязателен}"
: "${PG_ADMIN_DB:=postgres}"

: "${PG_ROLE:?PG_ROLE (роль для создания) обязателен}"
: "${PG_ROLE_PASSWORD:?PG_ROLE_PASSWORD (пароль роли) обязателен}"
: "${PG_DB_NAME:?PG_DB_NAME (БД для создания) обязателен}"

# Расширения для включения в создаваемой БД (список через пробел):
#   PG_EXTENSIONS="vector hstore"
: "${PG_EXTENSIONS:=}"

# Сколько ждать готовности postgres и с каким интервалом. pg-init работает как
# pre-start и сам ждёт базу (без depends_on на postgres из другого проекта).
: "${PG_WAIT_RETRIES:=60}"
: "${PG_WAIT_INTERVAL:=2}"

wait_for_pg() {
  n=0
  until pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_ADMIN_USER" -d "$PG_ADMIN_DB" >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -ge "$PG_WAIT_RETRIES" ]; then
      echo "ERROR: postgres не готов после $((n * PG_WAIT_INTERVAL))c" >&2
      exit 1
    fi
    sleep "$PG_WAIT_INTERVAL"
  done
}

wait_for_pg

psql_admin() {
  PGHOST="$PG_HOST" PGPORT="$PG_PORT" \
  PGUSER="$PG_ADMIN_USER" PGPASSWORD="$PG_ADMIN_PASSWORD" \
  psql -v ON_ERROR_STOP=1 --no-psqlrc --dbname "$PG_ADMIN_DB" "$@"
}

# Создаёт роль (если нет) и БД (если нет), назначает владельца роли и
# выдаёт права на уже существующие схемы/объекты + дефолтные привилегии.
provision() {
  role="$1"; pass="$2"; db="$3"

  [ -n "$pass" ] || { echo "ERROR: пустой пароль для роли '$role'" >&2; exit 1; }

  psql_admin -v role="$role" -v pass="$pass" -v db="$db" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pass')
  FROM (SELECT 1) AS x
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
  FROM (SELECT 1) AS x
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db', :'role')
\gexec
SQL

  PGHOST="$PG_HOST" PGPORT="$PG_PORT" \
  PGUSER="$PG_ADMIN_USER" PGPASSWORD="$PG_ADMIN_PASSWORD" \
  psql -v ON_ERROR_STOP=1 --no-psqlrc --dbname "$db" -v role="$role" <<'SQL'
-- Владелец схемы public и существующих объектов + дефолтные права для новых
ALTER SCHEMA public OWNER TO :"role";
GRANT ALL PRIVILEGES ON ALL TABLES   IN SCHEMA public TO :"role";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO :"role";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO :"role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES   TO :"role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO :"role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO :"role";
SQL

  echo "pg-init: provisioned role=$role db=$db"
}

provision "$PG_ROLE" "$PG_ROLE_PASSWORD" "$PG_DB_NAME"

# Включает дополнительные расширения (PG_EXTENSIONS) в БД после её создания.
# Подключение — админом к самой БД, т.к. CREATE EXTENSION обычно требует
# суперпользователя или права на создание расширений.
if [ -n "$PG_EXTENSIONS" ]; then
  for ext in $PG_EXTENSIONS; do
    PGHOST="$PG_HOST" PGPORT="$PG_PORT" \
    PGUSER="$PG_ADMIN_USER" PGPASSWORD="$PG_ADMIN_PASSWORD" \
    psql -v ON_ERROR_STOP=1 --no-psqlrc --dbname "$PG_DB_NAME" -v ext="$ext" \
      >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS :"ext";
SQL
    echo "pg-init: extension '$ext' enabled on $PG_DB_NAME"
  done
fi

echo "pg-init: done"