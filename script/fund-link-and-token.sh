#!/usr/bin/env bash
# Fondea las wallets de prueba con pequeños montos de LINK (PAIR_TOKEN)
# y TOKEN sin par USDC (NOT_PAIR_TOKEN) usando swaps WETH->token en el router V2.
#
# Uso:
#   bash script/fund-link-and-token.sh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -f "$ROOT_DIR/script/load-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/script/load-env.sh" .env
fi

RPC_URL=${SEPOLIA_RPC_URL:-${FORK_RPC_URL:-}}
ROUTER=${V2_ROUTER:-${ROUTER:-}}
FACTORY=${FACTORY:-}
WETH=${WETH:-}
LINK=${LINK:-${PAIR_TOKEN:-}}
TOKEN_NOPAIR=${TOKEN:-${NOT_PAIR_TOKEN:-}}

[[ -n "$RPC_URL" ]] || { echo "[fund] RPC no definido" >&2; exit 1; }
[[ -n "$ROUTER" ]] || { echo "[fund] V2_ROUTER/ROUTER no definido" >&2; exit 1; }
[[ -n "$FACTORY" ]] || { echo "[fund] FACTORY no definido" >&2; exit 1; }
[[ -n "$WETH" ]] || { echo "[fund] WETH no definido" >&2; exit 1; }

if ! command -v cast >/dev/null 2>&1; then
  echo "[fund] 'cast' no encontrado" >&2
  exit 1
fi

DEFAULT_KEYS=(
  0x9ab2e425e2636b85630c155f1290439329f1f105206e7a6613d8b0d74756c805
  0xd8220c9ac08212cb015ff2fe7220da1e781ae7c2d5f21d3883b0189fc59326f1
  0x0785cf5d9cd5ccb5f92ebcb56567768c70106e30cb8069341564cbb612006426
)

IFS=' ' read -r -a KEYS <<< "${KEYS:-${DEFAULT_KEYS[*]}}"

# ETH muy pequeño por swap (0.0001 ETH por defecto)
ETH_PER_SWAP_WEI=${ETH_PER_SWAP_WEI:-100000000000000}

echo "[fund] RPC:        $RPC_URL"
echo "[fund] ROUTER:     $ROUTER"
echo "[fund] FACTORY:    $FACTORY"
echo "[fund] WETH:       $WETH"
echo "[fund] LINK:       ${LINK:-"(no definido)"}"
echo "[fund] TOKEN_NOPAIR:${TOKEN_NOPAIR:-"(no definido)"}"

has_weth_pair() {
  local token=$1
  local pair
  pair=$(cast call "$FACTORY" "getPair(address,address)(address)" "$WETH" "$token" --rpc-url "$RPC_URL")
  [[ "$pair" != 0x0000000000000000000000000000000000000000 ]]
}

swap_eth_for_token() {
  local token=$1 key=$2 label=$3
  if [[ -z "$token" ]]; then
    echo "[$label] token no definido; saltando"
    return 0
  fi
  if ! has_weth_pair "$token"; then
    echo "[$label] no hay par WETH/token en FACTORY; saltando"
    return 0
  fi
  local addr bal
  addr=$(cast wallet address --private-key "$key")
  bal=$(cast balance "$addr" --rpc-url "$RPC_URL" | awk '{print $1}')
  echo "[$label] holder=$addr ETHbalanceWei=$bal"
  if (( bal < ETH_PER_SWAP_WEI )); then
    echo "[$label] ETH insuficiente para swap; saltando"
    return 0
  fi
  local path deadline
  path="[$WETH,$token]"
  deadline=$(( $(date +%s) + 900 ))
  echo "[$label] swappeando $(printf '%.6f' "$(python3 - <<PY
print($ETH_PER_SWAP_WEI/1e18)
PY
)") ETH por token (minOut=0)..."
  cast send "$ROUTER" \
    "swapExactETHForTokens(uint256,address[],address,uint256)" \
    0 "$path" "$addr" "$deadline" \
    --value "$ETH_PER_SWAP_WEI" \
    --rpc-url "$RPC_URL" \
    --private-key "$key"
}

echo "[fund] Swaps WETH->LINK y WETH->TOKEN_NOPAIR (si hay par WETH)
" 
for pk in "${KEYS[@]}"; do
  echo "===================="
  echo "[acct] $(cast wallet address --private-key "$pk")"
  echo "--------------------"
  swap_eth_for_token "$LINK" "$pk" "LINK" || true
  swap_eth_for_token "$TOKEN_NOPAIR" "$pk" "NOPAIR" || true
done

echo "[fund] Listo. Revisá balances de LINK/TOKEN_NOPAIR de las wallets."

