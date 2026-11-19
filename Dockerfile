# Универсальный образ pre-start инициализатора ролей/БД PostgreSQL.
# Один и тот же образ используется для любого сервиса (litellm, open-webui,
# kryton, ...): init.sh вшит в образ, а параметры задаются переменными среды
# на старте. Контейнер отрабатывает role/db и завершается (exit 0).
#
# Сборка:
#   docker build -t infra/pg-init:latest pgvector/
#
# Использование (Compose pre_start — нативный одноразовый контейнер перед
# основным сервисом; volume/entrypoint не нужны, достаточно image + environment):
#   services:
#     app:
#       image: <app>
#       pre_start:
#         - image: infra/pg-init:latest
#           environment:
#             PG_HOST: postgres
#             PG_ADMIN_USER: ${DB_ROOT_USERNAME}
#             PG_ADMIN_PASSWORD: ${DB_ROOT_PASSWORD}
#             PG_ADMIN_DB: ${DB_DEFAULT_DATABASE}
#             PG_ROLE: ${LITELLM_DB_USER}
#             PG_ROLE_PASSWORD: ${LITELLM_DB_PASSWORD}
#             PG_DB_NAME: ${LITELLM_DB_NAME}
FROM postgres:16-alpine

COPY init.sh /usr/local/bin/pg-init.sh
RUN chmod +x /usr/local/bin/pg-init.sh

# pre_start контейнер сам ждёт готовности postgres (wait_for_pg), поэтому
# depends_on на postgres из другого проекта не нужен. Как только init
# завершится (exit 0), Compose запускает основной сервис.
ENTRYPOINT ["/usr/local/bin/pg-init.sh"]