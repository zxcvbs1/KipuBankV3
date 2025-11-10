#!/usr/bin/env bash
# Deploy helper for KipuBankV3 to Sepolia using Foundry
#
# Usage:
#   bash deploy-sepolia.sh [--verify]
#
# Reads unified variables from: script/select-env.sh testnet
# Requires in env (export or put in .env):
#   - PRIVATE_KEY (0x + 64 hex)
#   - ADMIN (deployer/admin address)
# Optional (defaults shown):
#   - PAUSER (defaults to ADMIN)
#   - BANK_CAP_USD6 (default 1000000000000 => 1,000,000 USDC)
#   - WITHDRAW_CAP_USD6 (default 100000000000 => 100,000 USDC)
#   - SLIPPAGE_BPS (default 100 => 1%)
#   - ORACLE_MAX_DELAY (default 86400)
#   - ORACLE_DEV_BPS (default 0 => disabled)
#   - ETHERSCAN_API_KEY (only needed if --verify)

set -euo pipefail

VERIFY=0
if [[ "${1:-}" == "--verify" ]]; then
  VERIFY=1
fi

# 1) Load unified env for testnet (Sepolia)
if [[ ! -f script/select-env.sh ]]; then
  echo "[deploy] ERROR: script/select-env.sh not found" >&2
  exit 1
fi

# shellcheck disable=SC1091
source script/select-env.sh testnet

# 2) Fill defaults if not set
export PAUSER="${PAUSER:-${ADMIN:-}}"
export BANK_CAP_USD6="${BANK_CAP_USD6:-1000000000000}"
export WITHDRAW_CAP_USD6="${WITHDRAW_CAP_USD6:-100000000000}"
export SLIPPAGE_BPS="${SLIPPAGE_BPS:-100}"
export ORACLE_MAX_DELAY="${ORACLE_MAX_DELAY:-86400}"
export ORACLE_DEV_BPS="${ORACLE_DEV_BPS:-0}"

die() { echo "[deploy] $*" >&2; exit 1; }

# 3) Basic validation
[[ -n "${SEPOLIA_RPC_URL:-}" || -n "${FORK_RPC_URL:-}" ]] || die "SEPOLIA_RPC_URL/FORK_RPC_URL not set"
RPC_URL="${SEPOLIA_RPC_URL:-${FORK_RPC_URL}}"

[[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY not set"
if [[ ! "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  die "PRIVATE_KEY must be 0x + 64 hex chars"
fi

[[ -n "${ADMIN:-}" ]] || die "ADMIN address not set"
[[ "$ADMIN" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "ADMIN must be an 0x + 40 hex address"
[[ "$PAUSER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "PAUSER must be an 0x + 40 hex address"

for v in V2_ROUTER WETH USDC ETH_ORACLE; do
  [[ -n "${!v:-}" ]] || die "missing var: $v"
done

echo "[deploy] RPC.............: $RPC_URL"
echo "[deploy] Admin...........: $ADMIN"
echo "[deploy] Pauser..........: $PAUSER"
echo "[deploy] V2_ROUTER.......: $V2_ROUTER"
echo "[deploy] WETH............: $WETH"
echo "[deploy] USDC............: $USDC"
echo "[deploy] ETH_ORACLE......: $ETH_ORACLE"
echo "[deploy] BankCapUSD6.....: $BANK_CAP_USD6"
echo "[deploy] WithdrawCapUSD6.: $WITHDRAW_CAP_USD6"
echo "[deploy] SlippageBps.....: $SLIPPAGE_BPS"
echo "[deploy] OracleMaxDelay..: $ORACLE_MAX_DELAY"
echo "[deploy] OracleDevBps....: $ORACLE_DEV_BPS"

# 4) Quick prechecks
which cast >/dev/null 2>&1 || die "cast not found (install foundry: foundryup)"
which forge >/dev/null 2>&1 || die "forge not found (install foundry: foundryup)"

BLOCK=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || true)
[[ -n "$BLOCK" ]] || die "RPC not responding (block-number)"
echo "[deploy] Block...........: $BLOCK"

code_router=$(cast code "$V2_ROUTER" --rpc-url "$RPC_URL")
[[ "$code_router" != "0x" ]] || die "Router has no code at $V2_ROUTER"
code_usdc=$(cast code "$USDC" --rpc-url "$RPC_URL")
[[ "$code_usdc" != "0x" ]] || die "USDC has no code at $USDC"

FACTORY=$(cast call "$V2_ROUTER" "factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)
[[ -n "$FACTORY" ]] || die "Cannot read router.factory()"
PAIR=$(cast call "$FACTORY" "getPair(address,address)(address)" "$WETH" "$USDC" --rpc-url "$RPC_URL" 2>/dev/null || true)
[[ "$PAIR" != "0x0000000000000000000000000000000000000000" ]] || die "No direct WETH/USDC pair on factory"
echo "[deploy] Factory.........: $FACTORY"
echo "[deploy] Pair WETH/USDC..: $PAIR"

# 5) Deploy
ARGS=(
  script/DeployKipuBankV3.s.sol:DeployKipuBankV3
  --rpc-url "$RPC_URL"
  --broadcast
  -vv
)

if [[ $VERIFY -eq 1 ]]; then
  [[ -n "${ETHERSCAN_API_KEY:-}" ]] || die "--verify set but ETHERSCAN_API_KEY not present"
  ARGS+=( --verify )
fi

echo "[deploy] Running forge script..."
forge script "${ARGS[@]}"

echo "[deploy] Done. Review broadcast folder for the deployed address and Etherscan status."

