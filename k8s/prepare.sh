#!/usr/bin/env bash
set -euo pipefail

K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$K8S_DIR/.." && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/.." && pwd)"
ENV_FILE="$INFRA_DIR/.env"
SECRETS_FILE="$K8S_DIR/secrets.env"
KEYS_DIR="$K8S_DIR/keys"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Не найден $ENV_FILE. Скопируйте infra/.env.example в infra/.env и заполните значения." >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${AUTH_POSTGRES_USER:?AUTH_POSTGRES_USER is not set}"
: "${AUTH_POSTGRES_PASSWORD:?AUTH_POSTGRES_PASSWORD is not set}"
: "${AUTH_POSTGRES_DB:?AUTH_POSTGRES_DB is not set}"
: "${USER_POSTGRES_USER:?USER_POSTGRES_USER is not set}"
: "${USER_POSTGRES_PASSWORD:?USER_POSTGRES_PASSWORD is not set}"
: "${USER_POSTGRES_DB:?USER_POSTGRES_DB is not set}"
: "${ORDER_POSTGRES_USER:?ORDER_POSTGRES_USER is not set}"
: "${ORDER_POSTGRES_PASSWORD:?ORDER_POSTGRES_PASSWORD is not set}"
: "${ORDER_POSTGRES_DB:?ORDER_POSTGRES_DB is not set}"
: "${PAYMENT_MONGO_USER:?PAYMENT_MONGO_USER is not set}"
: "${PAYMENT_MONGO_PASSWORD:?PAYMENT_MONGO_PASSWORD is not set}"
: "${PAYMENT_MONGO_DB:?PAYMENT_MONGO_DB is not set}"
: "${INTERNAL_SERVICE_TOKEN:?INTERNAL_SERVICE_TOKEN is not set}"
: "${JWT_KEY_ID:?JWT_KEY_ID is not set}"

sed -e 's/\r$//' "$ENV_FILE" > "$SECRETS_FILE"

{
  echo "AUTH_DB_URL=jdbc:postgresql://auth-postgres:5432/${AUTH_POSTGRES_DB}"
  echo "USER_DB_URL=jdbc:postgresql://user-postgres:5432/${USER_POSTGRES_DB}"
  echo "ORDER_DB_URL=jdbc:postgresql://order-postgres:5432/${ORDER_POSTGRES_DB}"
  echo "PAYMENT_MONGO_URI=mongodb://${PAYMENT_MONGO_USER}:${PAYMENT_MONGO_PASSWORD}@payment-mongo:27017/${PAYMENT_MONGO_DB}?authSource=admin"
} >> "$SECRETS_FILE"

echo "Создан $SECRETS_FILE"

mkdir -p "$KEYS_DIR"
for name in jwt-private.pem jwt-public.pem; do
  source_file="$REPO_ROOT/auth-service/keys/$name"
  if [[ ! -f "$source_file" ]]; then
    echo "Не найден $source_file. Сгенерируйте ключи по инструкции из auth-service/README.md." >&2
    exit 1
  fi
  cp "$source_file" "$KEYS_DIR/$name"
done

echo "Скопированы JWT-ключи в $KEYS_DIR"
