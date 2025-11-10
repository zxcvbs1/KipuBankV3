#!/usr/bin/env bash
# Verifica si existe par directo en Uniswap V2 contra USDC para una lista de tokens.
# Usa las variables del archivo .env si existen.
#
# Uso:
#   # cargar variables (opcional si ya las tienes exportadas)
#   # source script/load-env.sh
#   # ejecutar con tokens por CLI o toma los de .env (WETH, LINK, CHEX, DAI, TOKEN)
#   bash script/check-pairs.sh [0xToken1 0xToken2 ...]
#
# Requiere:
#   - SEPOLIA_RPC_URL (o el RPC que uses)
#   - V2_ROUTER (router Uniswap V2)
#   - USDC (token base, 6 decimales)

set -euo pipefail

# Cargar .env si existe
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SEPOLIA_RPC_URL=${SEPOLIA_RPC_URL:-}
V2_ROUTER=${V2_ROUTER:-}
USDC=${USDC:-}

if [[ -z "$SEPOLIA_RPC_URL" || -z "$V2_ROUTER" || -z "$USDC" ]]; then
  echo "[check-pairs] Faltan variables. Asegura tener SEPOLIA_RPC_URL, V2_ROUTER y USDC." >&2
  echo "  Sugerencia: source script/load-env.sh" >&2
  exit 1
fi

# Obtener factory del router
FACTORY=$(cast call "$V2_ROUTER" "factory()(address)" --rpc-url "$SEPOLIA_RPC_URL")
echo "Factory: $FACTORY"

# Tokens a verificar: desde CLI o desde .env
TOKENS=("${@}")

# Mapa address->nombreVariable para imprimir etiquetas legibles
declare -A NAME_MAP

# Registrar USDC y tokens predefinidos si existen en .env
for var in USDC WETH LINK CHEX DAI TOKEN; do
  val=${!var-}
  if [[ -n "${val}" ]]; then
    NAME_MAP["${val,,}"]="$var"
  fi
done

if [[ ${#TOKENS[@]} -eq 0 ]]; then
  # toma tokens conocidos del .env si existen
  for var in WETH LINK CHEX DAI TOKEN; do
    val=${!var-}
    if [[ -n "${val}" ]]; then
      TOKENS+=("${val}")
    fi
  done
fi

if [[ ${#TOKENS[@]} -eq 0 ]]; then
  echo "[check-pairs] No hay tokens a verificar. Pasa direcciones por CLI o define WETH/LINK/CHEX/DAI/TOKEN en .env" >&2
  exit 1
fi

USDC_NAME=${NAME_MAP["${USDC,,}"]-USDC}
echo "Verificando par directo contra ${USDC_NAME} ($USDC) en router $V2_ROUTER"
for T in "${TOKENS[@]}"; do
  # saltar si es el mismo USDC
  if [[ "${T,,}" == "${USDC,,}" ]]; then
    echo "(omitir) token es ${USDC_NAME}: $T"
    continue
  fi
  P=$(cast call "$FACTORY" "getPair(address,address)(address)" "$T" "$USDC" --rpc-url "$SEPOLIA_RPC_URL") || P=0x0
  if [[ "$P" == 0x0000000000000000000000000000000000000000 ]]; then
    T_NAME=${NAME_MAP["${T,,}"]-TOKEN}
    echo "NO par: ${T_NAME} ($T) / ${USDC_NAME} ($USDC)"
  else
    T_NAME=${NAME_MAP["${T,,}"]-TOKEN}
    echo "SI par: ${T_NAME} ($T) / ${USDC_NAME} ($USDC) -> $P"
  fi
done
