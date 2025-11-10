#!/usr/bin/env bash
# Compara cotizacion AMM (Uniswap V2) vs oraculo (Chainlink) en MAINNET para ETH->USDC.
# Lee variables MAINNET_* desde .env: MAINNET_RPC_URL, V2_ROUTER_MAINNET, WETH_MAINNET, USDC_MAINNET, ETH_ORACLE_MAINNET
# Uso:
#   source script/load-env.sh
#   bash script/check-amm-vs-oraculo-mainnet.sh [amount_eth] [slippage_bps] [-v]

set -euo pipefail

AMOUNT_ETH="${1:-1}"
SLIPPAGE_BPS="${2:-100}"
VERBOSE="${3:-0}"
if [[ "$VERBOSE" == "-v" || "$VERBOSE" == "v" || "$VERBOSE" == "verbose" ]]; then VERBOSE=1; fi

die() { echo "[mainnet-check] $*" >&2; exit 1; }

for v in MAINNET_RPC_URL V2_ROUTER_MAINNET WETH_MAINNET USDC_MAINNET ETH_ORACLE_MAINNET; do
  [[ -n "${!v:-}" ]] || die "falta var: $v (usa: source script/load-env.sh)"
done

echo "RPC.............: $MAINNET_RPC_URL"
echo "Router..........: $V2_ROUTER_MAINNET"
echo "WETH............: $WETH_MAINNET"
echo "USDC............: $USDC_MAINNET"
echo "ETH_ORACLE......: $ETH_ORACLE_MAINNET"
echo "Amount ETH......: $AMOUNT_ETH"
echo "Slippage bps....: $SLIPPAGE_BPS"

BLOCK=$(cast block-number --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || true)
[[ -n "$BLOCK" ]] || die "RPC no responde (block-number)"
echo "Block...........: $BLOCK"

AMOUNT_WEI=$(cast --to-wei "$AMOUNT_ETH" ether)

echo "==== UNISWAP (Mainnet) ===="
# AMM getAmountsOut (Uniswap V2)
RAW_AMM=$(cast call "$V2_ROUTER_MAINNET" "getAmountsOut(uint256,address[])(uint256[])" "$AMOUNT_WEI" "[$WETH_MAINNET,$USDC_MAINNET]" --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || true)
[[ "$VERBOSE" == 1 ]] && { echo "[debug] AMM raw:"; echo "$RAW_AMM"; }
AMM_OUT_USDC=$(sed -n 's/.*,[[:space:]]*\([0-9]\+\)[[:space:]]*\[[^]]*\].*/\1/p' <<<"$RAW_AMM")
[[ -n "$AMM_OUT_USDC" ]] || die "no se pudo obtener amountOut del AMM"
echo "AMM amountOut...: $AMM_OUT_USDC (USDC 6 dec)"

MIN_OUT=$(
python3 - << PY
amount = int("$AMM_OUT_USDC")
bps = int("$SLIPPAGE_BPS")
print(amount * (10000 - bps) // 10000)
PY
)
echo "AMM minOut......: $MIN_OUT (con slippage)"

echo "==== ORACULO CHAINLINK (Mainnet) ===="
# Oraculo latestRoundData (ETH/USD)
RAW_DEC=$(cast call "$ETH_ORACLE_MAINNET" "decimals()(uint8)" --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || true)
RAW_ORC=$(cast call "$ETH_ORACLE_MAINNET" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || true)
[[ "$VERBOSE" == 1 ]] && { echo "[debug] ORC DEC raw:"; echo "$RAW_DEC"; echo "[debug] ORC raw:"; echo "$RAW_ORC"; }
ORC_DEC=$(awk '{print $NF}' <<<"$RAW_DEC")
ORC_ANSWER=$(awk 'NR==2{print $1; exit}' <<<"$RAW_ORC")
ORC_UPDATED=$(awk 'NR==4{print $1; exit}' <<<"$RAW_ORC")
[[ -n "$ORC_DEC" && -n "$ORC_ANSWER" && -n "$ORC_UPDATED" ]] || die "no se pudo leer latestRoundData del oraculo"
echo "Oracle price....: $ORC_ANSWER (decimals=$ORC_DEC)"
echo "Oracle updated..: $ORC_UPDATED"

ORACLE_OUT_USDC=$(
python3 - << PY
ans = int("$ORC_ANSWER")
dec = int("$ORC_DEC")
print(ans * 10**6 // 10**dec)
PY
)
echo "Oracle out......: $ORACLE_OUT_USDC (USDC 6 dec)"

echo "==== DIFERENCIA ===="
read -r DIFF BPS < <(
python3 - << PY
amm = int("$AMM_OUT_USDC")
orc = int("$ORACLE_OUT_USDC")
diff = abs(amm - orc)
bps = 0 if orc == 0 else diff * 10000 // orc
print(diff, bps)
PY
)
echo "Diff abs........: $DIFF (USDC 6 dec)"
echo "Diff bps........: $BPS"

echo "Resumen: AMM vs Oraculo (ETH->$USDC_MAINNET)"
echo "  amountIn (wei): $AMOUNT_WEI"
echo "  amountOut amm : $AMM_OUT_USDC"
echo "  minOut amm    : $MIN_OUT"
echo "  amountOut orc : $ORACLE_OUT_USDC"
