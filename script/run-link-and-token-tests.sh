#!/usr/bin/env bash
# Genera transacciones de prueba solo para:
#  - LINK (PAIR_TOKEN): ERC20 con par directo a USDC
#  - TOKEN (NOT_PAIR_TOKEN): ERC20 sin par directo (se espera revert)
#
# Uso:
#   bash script/run-link-and-token-tests.sh [BANK_ADDRESS]

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -f "$ROOT_DIR/script/load-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/script/load-env.sh" .env
fi

RPC_URL=${SEPOLIA_RPC_URL:-${FORK_RPC_URL:-}}
BANK=${1:-${KIPUBANKV3_SEPOLIA:-}}

USDC=${USDC:-}
LINK=${LINK:-${PAIR_TOKEN:-}}
TOKEN_NOPAIR=${TOKEN:-${NOT_PAIR_TOKEN:-}}

[[ -n "$RPC_URL" ]] || { echo "[link-tests] RPC no definido" >&2; exit 1; }
[[ -n "$BANK" ]] || { echo "[link-tests] BANK no definido (KIPUBANKV3_SEPOLIA o arg)" >&2; exit 1; }
[[ -n "$USDC" ]] || { echo "[link-tests] USDC no definido" >&2; exit 1; }

if ! command -v cast >/dev/null 2>&1; then
  echo "[link-tests] 'cast' no encontrado" >&2
  exit 1
fi

DEFAULT_KEYS=(
  0x9ab2e425e2636b85630c155f1290439329f1f105206e7a6613d8b0d74756c805
  0xd8220c9ac08212cb015ff2fe7220da1e781ae7c2d5f21d3883b0189fc59326f1
  0x0785cf5d9cd5ccb5f92ebcb56567768c70106e30cb8069341564cbb612006426
)

IFS=' ' read -r -a KEYS <<< "${KEYS:-${DEFAULT_KEYS[*]}}"

# Monto muy chico por defecto: 0.1% de 10^dec
ERC20_PCT=${ERC20_PCT:-10}

echo "[link-tests] RPC:   $RPC_URL"
echo "[link-tests] BANK:  $BANK"
echo "[link-tests] USDC:  $USDC"
echo "[link-tests] LINK:  ${LINK:-"(no definido)"}"
echo "[link-tests] NOPAIR:${TOKEN_NOPAIR:-"(no definido)"}"

erc20_balance() {
  local token=$1 addr=$2
  cast call "$token" "balanceOf(address)(uint256)" "$addr" --rpc-url "$RPC_URL"
}

erc20_decimals() {
  local token=$1
  cast call "$token" "decimals()(uint8)" --rpc-url "$RPC_URL"
}

erc20_symbol() {
  local token=$1
  cast call "$token" "symbol()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "TOKEN"
}

compute_pct_amount() {
  local token=$1 pct=$2
  local dec
  dec=$(erc20_decimals "$token")
  python3 - <<PY
dec=$dec
pct=$pct
base=10**dec
amt=max(1, base//(10000//pct))
print(amt)
PY
}

approve() {
  local token=$1 spender=$2 amount=$3 key=$4
  local sym
  sym=$(erc20_symbol "$token")
  echo "[approve] $sym -> $spender amount=$amount"
  cast send "$token" "approve(address,uint256)(bool)" "$spender" "$amount" \
    --rpc-url "$RPC_URL" --private-key "$key" >/dev/null
}

deposit_link() {
  local key=$1
  if [[ -z "$LINK" ]]; then
    echo "[LINK] LINK/PAIR_TOKEN no definido; saltando"
    return 0
  fi
  local addr raw bal amt sym
  addr=$(cast wallet address --private-key "$key")
  sym=$(erc20_symbol "$LINK")
  amt=$(compute_pct_amount "$LINK" "$ERC20_PCT")
  raw=$(erc20_balance "$LINK" "$addr")
  bal=$(echo "$raw" | awk '{print $1}')
  echo "[LINK] $sym holder=$addr balance=$raw want=$amt"
  if (( bal < amt )); then
    echo "[LINK] saldo insuficiente; saltando"
    return 0
  fi
  approve "$LINK" "$BANK" "$amt" "$key"
  echo "[LINK] depositar $sym (par con USDC)..."
  cast send "$BANK" "depositar(address,uint256)" "$LINK" "$amt" \
    --rpc-url "$RPC_URL" --private-key "$key"
}

attempt_token_without_pair() {
  local key=$1
  if [[ -z "$TOKEN_NOPAIR" ]]; then
    echo "[NO-PAIR] TOKEN/NOT_PAIR_TOKEN no definido; saltando"
    return 0
  fi
  local addr raw bal amt sym
  addr=$(cast wallet address --private-key "$key")
  sym=$(erc20_symbol "$TOKEN_NOPAIR")
  # Para testear PairInexistente no necesitamos saldo real:
  # _depositErc20Swap revierte antes de hacer transferFrom si no hay par USDC.
  amt=$(compute_pct_amount "$TOKEN_NOPAIR" 50) # 0.5% muy chico
  raw=$(erc20_balance "$TOKEN_NOPAIR" "$addr")
  bal=$(echo "$raw" | awk '{print $1}')
  echo "[NO-PAIR] $sym holder=$addr balance=$raw try=$amt (se espera revert)"
  # No chequeamos saldo; queremos forzar el camino PairInexistente aunque balance sea 0.
  echo "[NO-PAIR] intentando depositar $sym (debería revertir PairInexistente)..."
  if cast send "$BANK" "depositar(address,uint256)" "$TOKEN_NOPAIR" "$amt" \
      --rpc-url "$RPC_URL" --private-key "$key"; then
    echo "[NO-PAIR] ATENCIÓN: no revirtió, revisa configuración"
  else
    echo "[NO-PAIR] revert detectada como se esperaba"
  fi
}

echo "[link-tests] Enviando transacciones solo para LINK y TOKEN sin par..."
for pk in "${KEYS[@]}"; do
  echo "===================="
  echo "[acct] $(cast wallet address --private-key "$pk")"
  echo "--------------------"
  deposit_link "$pk" || true
  attempt_token_without_pair "$pk" || true
done

echo "[link-tests] Listo. Revisa Etherscan para $BANK y eventos emitidos."
