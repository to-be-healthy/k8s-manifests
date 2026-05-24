#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
NS=tobehealthy
set -a; source "$ROOT/.env"; set +a

kubectl -n $NS create secret generic db-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  --from-literal=MYSQL_DATABASE="$MYSQL_DATABASE" \
  --from-literal=MYSQL_USER="$MYSQL_USER" \
  --from-literal=MYSQL_PASSWORD="$MYSQL_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n $NS create secret generic redis-credentials \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n $NS create secret generic backend-env \
  --from-env-file="$ROOT/backend/.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n $NS create secret generic frontend-env \
  --from-literal=INTERNAL_API_URL="$INTERNAL_API_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
