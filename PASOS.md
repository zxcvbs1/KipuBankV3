# PASOS PARA DEPLOY DE KIPUBANKV3 

Este archivo describe los pasos para:

1. Configurar `.env`.
2. Deployar el contrato `KipuBankV3` usando un `ADMIN` directo (EOA o multisig).
3. Opcional: deployar el contrato `KipuTimelock` y usarlo como admin en una versión futura del banco.
4. Cargar las variables de entorno en la shell.

Los ejemplos toman Sepolia como red, pero la idea es la misma para mainnet.

---

## 1. Preparar `.env`

En la raiz del proyecto debe existir un archivo `.env` con al menos estas secciones rellenadas.

### 1.1. Datos de red y tokens (Sepolia)

```env
SEPOLIA_RPC_URL=...            # URL RPC de Sepolia

V2_ROUTER=0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3
FACTORY=0xF62c03E08ada871A0bEb309762E260a7a6a880E6
WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
USDC=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

PAIR_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789
NOT_PAIR_TOKEN=0xb21bED9b1BaC3FbE5708332cEf303deD4b006777

ETH_ORACLE=0x694AA1769357215DE4FAC081bf1f309aDC325306
ORACLE_MAX_DELAY=86400
ORACLE_DEV_BPS=1000
```

Estos valores son los que usan los tests y los scripts de deploy para Sepolia.

### 1.2. Parametros del banco

```env
BANK_CAP_USD6=1000000000000     # 1 000 000 USDC (6 decimales)
WITHDRAW_CAP_USD6=100000000000  # 100 000 USDC
SLIPPAGE_BPS=100                # 1 %
```

Se pueden ajustar a tus necesidades antes del deploy.

### 1.3. Datos de deploy y roles (sin timelock por defecto)

```env
PRIVATE_KEY=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

ADMIN=0x1111111111111111111111111111111111111111
PAUSER=0x1111111111111111111111111111111111111111
```

- `PRIVATE_KEY` debe ser la clave privada real del deployer (no commitear este valor).
- `ADMIN` es el admin de KipuBankV3 y, por defecto, se asume un EOA o multisig (sin timelock).
- `PAUSER` es quien puede pausar / despausar el banco (puede ser igual al admin o un rol separado).

Si más adelante querés gobernar el banco con timelock, podés desplegar `KipuTimelock` (sección opcional) y usarlo como admin de una nueva instancia de `KipuBankV3`.

### 1.4. Parametros del timelock

```env
TIMELOCK_MIN_DELAY=50
TIMELOCK_PROPOSER=0x2222222222222222222222222222222222222222
TIMELOCK_EXECUTOR=0x2222222222222222222222222222222222222222
TIMELOCK_ADMIN=0x2222222222222222222222222222222222222222
```

- `TIMELOCK_MIN_DELAY`: demora minima (en segundos) para cualquier operacion agendada.
- `TIMELOCK_PROPOSER`: address con permiso para agendar operaciones (`PROPOSER_ROLE` y `CANCELLER_ROLE`).
- `TIMELOCK_EXECUTOR`: address con permiso para ejecutarlas (`EXECUTOR_ROLE`).
- `TIMELOCK_ADMIN`: admin inicial del timelock para configurar roles (se recomienda renunciar luego).

Tambien conviene dejar lugar para guardar las direcciones desplegadas:

```env
KIPUTIMELOCK_SEPOLIA=0x0000000000000000000000000000000000000000
KIPUBANKV3_SEPOLIA=0x0000000000000000000000000000000000000000
```

Despues del deploy completaremos estos campos.

---

## 2. Cargar variables de `.env` en la shell

Para que `forge`, `cast` y los scripts bash vean las variables del `.env`, usaremos `script/load-env.sh`.

Desde la raiz del repo:

```bash
source script/load-env.sh
```

Este script hace `source .env` y exporta todas las variables. Cada nueva terminal que uses para deploy o operaciones deberia ejecutar este comando una vez.

Para los tests y algunos scripts, tambien se usa `select-env.sh` para crear variables unificadas:

```bash
source script/select-env.sh testnet   # para Sepolia
# o
source script/select-env.sh mainnet   # para mainnet
```

`select-env.sh` toma los valores base de `.env` y exporta `V2_ROUTER`, `ROUTER`, `WETH`, `USDC`, `ETH_ORACLE`, `ORACLE_MAX_DELAY`, `ORACLE_DEV_BPS`, etc. Esto es util para tests y scripts de deploy.

---

## 3. Deploy de KipuBankV3 (sin timelock)

Esta sección cubre el flujo básico donde `ADMIN` es un EOA o multisig sin timelock.

### 3.1. Deploy manual de KipuBankV3 (forge create)

Pre requisitos:
- Haber cargado `.env`: `source script/load-env.sh`
- Variables definidas: `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, `ADMIN`, `PAUSER`, `V2_ROUTER`, `USDC`, `BANK_CAP_USD6`, `WITHDRAW_CAP_USD6`, `SLIPPAGE_BPS`, `ETH_ORACLE`, `ORACLE_MAX_DELAY`, `ORACLE_DEV_BPS`.

Comando de deploy (Sepolia) usando `ADMIN` directo (contract-first recomendado):

```bash
forge create src/KipuBankV3.sol:KipuBankV3 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vv \
  --constructor-args \
  "$ADMIN" "$PAUSER" "$V2_ROUTER" "$USDC" \
  "$BANK_CAP_USD6" "$WITHDRAW_CAP_USD6" "$SLIPPAGE_BPS" \
  "$ETH_ORACLE" "$ORACLE_MAX_DELAY" "$ORACLE_DEV_BPS"
```

Si preferís una vía más scripteada (típico en Linux), podés usar el script de ayuda `script/deploy-bank-admin-sepolia.sh`. Este script:
- lee las mismas variables de `.env` (después de `source script/load-env.sh`),
- ejecuta internamente el script de Foundry `DeployKipuBankV3.s.sol` con `ADMIN` directo,
- fuerza `ORACLE_DEV_BPS=0` solo para ese deploy (útil en Sepolia, donde suele haber mucha diferencia entre el precio de ETH en Uniswap y el oráculo Chainlink), y
- si `ETHERSCAN_API_KEY` está definida, intenta verificar automáticamente el contrato.

```bash
source script/load-env.sh
bash script/deploy-bank-admin-sepolia.sh
```

### 3.2. Guardar la direccion de KipuBankV3

La salida mostrara algo como:

```text
Deployed to: 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
```

Copiar esa direccion y actualizar en `.env` para referencia:

```env
KIPUBANKV3_SEPOLIA=0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
```

### 3.3. Verificar KipuBankV3 en Etherscan (Sepolia)

Pre requisitos:
- `ETHERSCAN_API_KEY` en `.env`.
- `KIPUBANKV3_SEPOLIA` seteada con la direccion desplegada.

Opcion A: constructor args codificados con `cast`:

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode \
  'constructor(address,address,address,address,uint256,uint256,uint256,address,uint256,uint256)' \
  "$ADMIN" "$PAUSER" "$V2_ROUTER" "$USDC" \
  "$BANK_CAP_USD6" "$WITHDRAW_CAP_USD6" "$SLIPPAGE_BPS" \
  "$ETH_ORACLE" "$ORACLE_MAX_DELAY" "$ORACLE_DEV_BPS")

forge verify-contract \
  --chain sepolia \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  --watch \
  "$KIPUBANKV3_SEPOLIA" \
  src/KipuBankV3.sol:KipuBankV3
```

Notas:
- Si desplegaste el banco usando un timelock como `ADMIN`, reemplazá `$ADMIN` por `$TIMELOCK_ADDRESS` en el encoding de constructor.

---

## 4. (Opcional) Deploy de timelock y banco gobernado por timelock

Esta sección es opcional y muestra cómo desplegar `KipuTimelock` y usarlo como admin del banco (por ejemplo para una segunda instancia más “seria”).

### 4.1. Deploy del timelock (KipuTimelock)

Primero deployeamos el timelock que va a ser admin del banco.

### 3.1. Comando de deploy con forge create

Con las variables cargadas (`source script/load-env.sh`), ejecutar:

```bash

forge create src/KipuTimelock.sol:KipuTimelock --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY"  --broadcast -vv --constructor-args "$TIMELOCK_MIN_DELAY" "[$TIMELOCK_PROPOSER]" "[$TIMELOCK_EXECUTOR]" "$TIMELOCK_ADMIN" 

```

Notas:
- El primer argumento es `minDelay` en segundos (50 seg segun `.env`).
- `proposers` y `executors` se pasan como arrays de addresses en formato string.
- `admin` es quien tendra `DEFAULT_ADMIN_ROLE` del timelock al inicio.

### 3.2. Guardar la direccion del timelock

El comando anterior imprimira algo como:

```text
Deployed to: 0xTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
```

Copiar esa direccion y actualizar en `.env`:

```env
KIPUTIMELOCK_SEPOLIA=0xTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
```

Tambien podes guardar una variable generica para reutilizar en scripts:

```env
TIMELOCK_ADDRESS=0xTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
```

Si vas a usar el timelock como admin del banco (recomendado), tambien actualiza:

```env
ADMIN=0xTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
```

Volver a cargar `.env` en la shell si ya estaba cargado:

```bash
source script/load-env.sh
```

### 4.3. Verificar el timelock en Etherscan (Sepolia)

Pre requisitos:
- Tener `ETHERSCAN_API_KEY` en `.env`.
- Haber cargado `.env` en la shell: `source script/load-env.sh`.

Opcion A: pasando los argumentos de constructor ya codificados (con cast):

```bash
# 1) Codificar los argumentos del constructor
CONSTRUCTOR_ARGS=$(cast abi-encode \
  'constructor(uint256,address[],address[],address)' \
  "$TIMELOCK_MIN_DELAY" \
  "[$TIMELOCK_PROPOSER]" \
  "[$TIMELOCK_EXECUTOR]" \
  "$TIMELOCK_ADMIN")

# 2) Verificar contrato de TIMELOCK
forge verify-contract \
  --chain sepolia \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  --watch \
  "$TIMELOCK_ADDRESS" \
  src/KipuTimelock.sol:KipuTimelock
```



## 5. Resumen rapido

1. Editar `.env` y completar:
   - Credenciales: `PRIVATE_KEY`, `ADMIN`, `PAUSER`.
   - Parametros de timelock: `TIMELOCK_MIN_DELAY`, `TIMELOCK_PROPOSER`, `TIMELOCK_EXECUTOR`, `TIMELOCK_ADMIN`.
   - Parametros de red y banco (ya hay valores por defecto).

2. Cargar `.env` en la shell:
   - `source script/load-env.sh`

3. Deploy de KipuBankV3 (sin timelock por defecto):
   - `forge create src/KipuBankV3.sol:KipuBankV3 ...` (ver comando en la sección 3.1).
   - Guardar la direccion en `KIPUBANKV3_SEPOLIA` y verificar en Etherscan (sección 3.3).

4. (Opcional) Deploy de `KipuTimelock` y banco gobernado por timelock (segunda instancia o versión futura):
   - `forge create src/KipuTimelock.sol:KipuTimelock ...` (ver comando en la sección 4.1).
   - Guardar direccion en `KIPUTIMELOCK_SEPOLIA` / `TIMELOCK_ADDRESS`.
   - Usar esa dirección como `ADMIN` al desplegar una instancia de banco gobernada por timelock.

Con esos pasos tenes:
- Un flujo simple con `ADMIN` directo para pruebas o despliegues iniciales.
- Opcionalmente, una instancia gobernada por timelock para producción, donde los setters sensibles (`setSlippageBps`, `setOracle`, `setOracleDevBps`) pasan por demoras y colas on-chain.

---

## 6. Scripts auxiliares

Además de los comandos manuales de esta guía, hay algunos scripts bash útiles que usan las mismas variables de `.env` (recuerda correr antes `source script/load-env.sh`):

- `bash script/anvil-fork.sh mainnet`: levanta un nodo local Anvil forkeado de mainnet usando `MAINNET_RPC_URL`, `MAINNET_CHAIN_ID` y `FORK_BLOCK_MAINNET`. Una vez levantado el fork (`http://127.0.0.1:8545`), podés correr:
  - `forge test --gas-report --rpc-url http://127.0.0.1:8545 | tee reportes/gas-report.txt`
  - `forge snapshot --rpc-url http://127.0.0.1:8545 | tee reportes/gas-snapshot.txt`
  - `forge coverage --rpc-url http://127.0.0.1:8545 --ir-minimum | tee reportes/coverage-resumen.txt`
- `bash deploy-bank-admin-sepolia.sh`: deploya KipuBankV3 en Sepolia usando `ADMIN` directo y fuerza `ORACLE_DEV_BPS=0` solo para ese deploy, leyendo todas las variables desde `.env`.
- `bash script/fund-link-and-token.sh`: swappea pequeños montos de ETH por LINK (`PAIR_TOKEN`) y `TOKEN`/`NOT_PAIR_TOKEN` (si existe par WETH/token) para fondear wallets de prueba.
- `bash script/run-link-and-token-tests.sh`: genera depósitos de prueba sobre el banco usando LINK (par directo a USDC) y el token sin par (para validar el revert `PairInexistente`).

Estos scripts son útiles para levantar entornos locales, hacer deploys reproducibles y generar tráfico de prueba sobre el banco sin tener que recordar todos los comandos de `forge` y `cast` a mano.
