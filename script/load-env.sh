#!/usr/bin/env bash
# Loader minimalista: exporta variables de .env al entorno actual.
# Uso:
#   source script/load-env.sh            # carga ./ .env
#   source script/load-env.sh path/.env  # carga el archivo indicado


ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[load-env] ERROR: no existe $ENV_FILE" >&2
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "[load-env] .env cargado desde: $ENV_FILE"
