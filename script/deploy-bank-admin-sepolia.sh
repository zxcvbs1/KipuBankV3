#!/usr/bin/env bash
# Deploy KipuBankV3 to Sepolia using ADMIN directo (sin timelock)
# con oracleDevBps=0 y verificación opcional en Etherscan.
#
# Uso:
#   bash deploy-bank-admin-sepolia.sh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 1) Cargar .env
if [[ -f "$ROOT_DIR/script/load-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/script/load-env.sh" .env
else
  echo "[deploy-admin] ERROR: script/load-env.sh no encontrado" >&2
  exit 1
fi

RPC_URL=${SEPOLIA_RPC_URL:-${FORK_RPC_URL:-}}

[[ -n "$RPC_URL" ]] || { echo "[deploy-admin] SEPOLIA_RPC_URL/FORK_RPC_URL no definido" >&2; exit 1; }
[[ -n "${PRIVATE_KEY:-}" ]] || { echo "[deploy-admin] PRIVATE_KEY no definido" >&2; exit 1; }
[[ -n "${ADMIN:-}" ]] || { echo "[deploy-admin] ADMIN no definido" >&2; exit 1; }
[[ -n "${PAUSER:-}" ]] || { echo "[deploy-admin] PAUSER no definido" >&2; exit 1; }
[[ -n "${V2_ROUTER:-}" ]] || { echo "[deploy-admin] V2_ROUTER no definido" >&2; exit 1; }
[[ -n "${USDC:-}" ]] || { echo "[deploy-admin] USDC no definido" >&2; exit 1; }
[[ -n "${BANK_CAP_USD6:-}" ]] || { echo "[deploy-admin] BANK_CAP_USD6 no definido" >&2; exit 1; }
[[ -n "${WITHDRAW_CAP_USD6:-}" ]] || { echo "[deploy-admin] WITHDRAW_CAP_USD6 no definido" >&2; exit 1; }
[[ -n "${SLIPPAGE_BPS:-}" ]] || { echo "[deploy-admin] SLIPPAGE_BPS no definido" >&2; exit 1; }
[[ -n "${ETH_ORACLE:-}" ]] || { echo "[deploy-admin] ETH_ORACLE no definido" >&2; exit 1; }
[[ -n "${ORACLE_MAX_DELAY:-}" ]] || { echo "[deploy-admin] ORACLE_MAX_DELAY no definido" >&2; exit 1; }

echo "[deploy-admin] RPC.............: $RPC_URL"
echo "[deploy-admin] Admin...........: $ADMIN"
echo "[deploy-admin] Pauser..........: $PAUSER"
echo "[deploy-admin] V2_ROUTER.......: $V2_ROUTER"
echo "[deploy-admin] USDC............: $USDC"
echo "[deploy-admin] ETH_ORACLE......: $ETH_ORACLE"
echo "[deploy-admin] BankCapUSD6.....: $BANK_CAP_USD6"
echo "[deploy-admin] WithdrawCapUSD6.: $WITHDRAW_CAP_USD6"
echo "[deploy-admin] SlippageBps.....: $SLIPPAGE_BPS"
echo "[deploy-admin] OracleMaxDelay..: $ORACLE_MAX_DELAY"
echo "[deploy-admin] OracleDevBps....: OVERRIDE A 0 (solo para este deploy)"

which forge >/dev/null 2>&1 || { echo "[deploy-admin] forge no encontrado" >&2; exit 1; }

ARGS=(
  script/DeployKipuBankV3.s.sol:DeployKipuBankV3
  --rpc-url "$RPC_URL"
  --broadcast
  -vv
)

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  ARGS+=( --verify )
  echo "[deploy-admin] Verificación Etherscan activada"
else
  echo "[deploy-admin] ETHERSCAN_API_KEY no definido; se omite verificación automática"
fi

echo "[deploy-admin] Ejecutando forge script con ORACLE_DEV_BPS=0..."
(
  cd "$ROOT_DIR"
  ORACLE_DEV_BPS=0 forge script "${ARGS[@]}"
)

echo "[deploy-admin] Listo. Revisa la carpeta broadcast para la dirección desplegada."

