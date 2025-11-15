#!/usr/bin/env bash
# Selecciona perfil de red (testnet|mainnet) y exporta las variables
# que esperan los tests de KipuBank (V2_ROUTER, WETH, USDC, ETH_ORACLE, etc.).
#
# Uso:
#   source script/select-env.sh testnet
#   source script/select-env.sh mainnet
#
# Requiere un .env con las variables correspondientes:
#   - TESTNET (Sepolia): SEPOLIA_RPC_URL, V2_ROUTER, WETH, USDC, ETH_ORACLE, (opcional) ORACLE_MAX_DELAY, PAIR_TOKEN, NOT_PAIR_TOKEN
#   - MAINNET: MAINNET_RPC_URL, V2_ROUTER_MAINNET, WETH_MAINNET, USDC_MAINNET, ETH_ORACLE_MAINNET,
#              (opcional) PAIR_TOKEN_MAINNET, NOT_PAIR_TOKEN_MAINNET, FORK_BLOCK_MAINNET, MAINNET_CHAIN_ID


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "[select-env] Por favor ejecuta con: source script/select-env.sh <testnet|mainnet>" >&2
  exit 1
fi

PROFILE="${1:-}"
if [[ -z "${PROFILE}" ]]; then
  echo "[select-env] Falta parametro <testnet|mainnet>" >&2
  return 0
fi

# Cargar .env si existe
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  # asegurar que la API key de verificacion quede exportada si existe
  export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-}"
fi

case "${PROFILE}" in
  testnet)
    : "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL no definido en .env}"
    : "${V2_ROUTER:?V2_ROUTER no definido en .env}"
    : "${WETH:?WETH no definido en .env}"
    : "${USDC:?USDC no definido en .env}"
    : "${ETH_ORACLE:?ETH_ORACLE no definido en .env}"

    export FORK_RPC_URL="${SEPOLIA_RPC_URL}"
    export FORK_CHAIN_ID="${FORK_CHAIN_ID:-11155111}"
    export FORK_BLOCK="${FORK_BLOCK:-}"

    # Variables unificadas que esperan los tests
    export V2_ROUTER="${V2_ROUTER}"
    # Alias de compatibilidad para scripts que esperan ROUTER
    export ROUTER="${V2_ROUTER}"
    export WETH="${WETH}"
    export USDC="${USDC}"
    export ETH_ORACLE="${ETH_ORACLE}"
    export ORACLE_MAX_DELAY="${ORACLE_MAX_DELAY:-86400}"
    export ORACLE_DEV_BPS="${ORACLE_DEV_BPS:-0}"
    # Tokens para tests (si no estan definidos, quedan vacios)
    export PAIR_TOKEN="${PAIR_TOKEN:-}"
    export NOT_PAIR_TOKEN="${NOT_PAIR_TOKEN:-}"

    echo "[select-env] Perfil: testnet (Sepolia)"
    ;;

  mainnet)
    : "${MAINNET_RPC_URL:?MAINNET_RPC_URL no definido en .env}"
    : "${V2_ROUTER_MAINNET:?V2_ROUTER_MAINNET no definido en .env}"
    : "${WETH_MAINNET:?WETH_MAINNET no definido en .env}"
    : "${USDC_MAINNET:?USDC_MAINNET no definido en .env}"
    : "${ETH_ORACLE_MAINNET:?ETH_ORACLE_MAINNET no definido en .env}"

    export FORK_RPC_URL="${MAINNET_RPC_URL}"
    export FORK_CHAIN_ID="${MAINNET_CHAIN_ID:-1}"
    export FORK_BLOCK="${FORK_BLOCK_MAINNET:-}"

    # Variables unificadas que esperan los tests
    export V2_ROUTER="${V2_ROUTER_MAINNET}"
    # Alias de compatibilidad para scripts que esperan ROUTER
    export ROUTER="${V2_ROUTER}"
    export WETH="${WETH_MAINNET}"
    export USDC="${USDC_MAINNET}"
    export ETH_ORACLE="${ETH_ORACLE_MAINNET}"
    export ORACLE_MAX_DELAY="${ORACLE_MAX_DELAY:-86400}"
    export ORACLE_DEV_BPS="${ORACLE_DEV_BPS:-0}"
    # Tokens para tests: LINK por defecto como par directo; NOT_PAIR una dummy
    export PAIR_TOKEN="${PAIR_TOKEN_MAINNET:-0x514910771AF9Ca656af840dff83E8264EcF986CA}"
    export NOT_PAIR_TOKEN="${NOT_PAIR_TOKEN_MAINNET:-0x0000000000000000000000000000000000000001}"

    echo "[select-env] Perfil: mainnet"
    ;;

  *)
    echo "[select-env] Perfil invalido: ${PROFILE}. Usa 'testnet' o 'mainnet'" >&2
    return 0
    ;;
esac

# estado legible de la api key para no exponerla completa en logs
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  ETHERSCAN_API_KEY_STATUS="(definido)"
else
  ETHERSCAN_API_KEY_STATUS="(no definido)"
fi

echo "[select-env] Variables cargadas:" \
     "\n  FORK_RPC_URL=$FORK_RPC_URL" \
     "\n  FORK_CHAIN_ID=$FORK_CHAIN_ID" \
     "\n  FORK_BLOCK=${FORK_BLOCK:-(no fijado)}" \
     "\n  V2_ROUTER=$V2_ROUTER" \
     "\n  ROUTER=$ROUTER" \
     "\n  WETH=$WETH" \
     "\n  USDC=$USDC" \
     "\n  ETH_ORACLE=$ETH_ORACLE" \
     "\n  ORACLE_MAX_DELAY=$ORACLE_MAX_DELAY" \
     "\n  ORACLE_DEV_BPS=$ORACLE_DEV_BPS" \
     "\n  ETHERSCAN_API_KEY=$ETHERSCAN_API_KEY_STATUS" \
     "\n  PAIR_TOKEN=${PAIR_TOKEN:-(no definido)}" \
     "\n  NOT_PAIR_TOKEN=${NOT_PAIR_TOKEN:-(no definido)}"
