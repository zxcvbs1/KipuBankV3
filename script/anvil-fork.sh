#!/usr/bin/env bash
# Wrapper para lanzar Anvil forkeando testnet/mainnet con variables unificadas
# Uso:
#   bash script/anvil-fork.sh [testnet|mainnet] [-- anvil_flags_opcionales]
# Ejemplos:
#   bash script/anvil-fork.sh mainnet
#   bash script/anvil-fork.sh testnet -- --port 8546 --steps-tracing

set -euo pipefail

PROFILE="${1:-mainnet}"
shift || true

# Acepta flags extra para anvil despues de "--"
EXTRA_ARGS=( )
if [[ "${1:-}" == "--" ]]; then
  shift
  EXTRA_ARGS=("$@")
fi

# Carga variables de entorno unificadas
if [[ ! -f "script/select-env.sh" ]]; then
  echo "[anvil-fork] ERROR: script/select-env.sh no encontrado" >&2
  exit 1
fi

# shellcheck disable=SC1091
source script/select-env.sh "$PROFILE"

[[ -n "${FORK_RPC_URL:-}" ]] || { echo "[anvil-fork] ERROR: FORK_RPC_URL vacio" >&2; exit 1; }
[[ -n "${FORK_CHAIN_ID:-}" ]] || { echo "[anvil-fork] ERROR: FORK_CHAIN_ID vacio" >&2; exit 1; }

ARGS=(
  --fork-url "$FORK_RPC_URL"
  --fork-chain-id "$FORK_CHAIN_ID"
)

# Solo pasar bloque si está definido
if [[ -n "${FORK_BLOCK:-}" ]]; then
  ARGS+=( --fork-block-number "$FORK_BLOCK" )
fi

echo "[anvil-fork] Lanzando Anvil:" >&2
echo "  RPC:    $FORK_RPC_URL" >&2
echo "  CHAIN:  $FORK_CHAIN_ID" >&2
echo "  BLOCK:  ${FORK_BLOCK:-(no fijado)}" >&2

exec anvil "${ARGS[@]}" "${EXTRA_ARGS[@]}"

