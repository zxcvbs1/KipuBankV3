KipuBankV2 / KipuBankV3
=======================

Descripción general
-------------------
- `src/KipuBankV3.sol` acepta depósitos en ETH, USDC y cualquier ERC‑20 con par directo a USDC (Uniswap V2).
- Si el token no es USDC, el contrato hace el swap a USDC y acredita el resultado (contabilidad en USDC, 6 decimales).
- Respeta el bank cap antes y después del swap (pre‑check con `getAmountsOut` + check con el `out` real).
- Mantiene roles (admin/pauser), pausas y protección de reentrada.
- Incluye una función especial de depósito con oráculo para ETH que compara AMM vs Chainlink y revierte si el desvío es alto.

Decisiones de diseño y trade‑offs
---------------------------------
- V3 hace contabilidad en USDC: todo lo no‑USDC entra por swap (solo par directo) y se acredita en 6 decimales.
- Se exige par directo `token/USDC` y se precalcula `minOut` con slippage para no pasarnos del cap y proteger la ejecucion.
- La ruta con oráculo esta separada de la default para no encarecer gas; cuando se necesita chequeo fuerte se llama `depositarEthConOraculo`.
- No se soportan tokens fee‑on‑transfer/rebase; la logica asume transferencias estandar.

Entorno y variables
-------------------
- Se usan variables unificadas via `script/select-env.sh` (perfiles `testnet` y `mainnet`).
- Claves: `FORK_RPC_URL`, `FORK_CHAIN_ID`, `FORK_BLOCK`, `V2_ROUTER`, `WETH`, `USDC`, `ETH_ORACLE`, `ORACLE_MAX_DELAY` (default 86400), `ORACLE_DEV_BPS` (0 desactiva oraculo), `PAIR_TOKEN`, `NOT_PAIR_TOKEN` y `ETHERSCAN_API_KEY` (opcional).
- Hay un `.env.example` listo para copiar y completar segun red.

Como correr en local
--------------------
1) Levantar el fork con un comando:
   - `bash script/anvil-fork.sh mainnet` (o `testnet`)
2) En la shell de pruebas, seleccionar el mismo perfil:
   - `source script/select-env.sh mainnet`
3) Ejecutar:
   - `forge test --rpc-url http://127.0.0.1:8545`

Importante: las direcciones de `V2_ROUTER/WETH/USDC/ETH_ORACLE` deben coincidir con la red del fork. Si mezclas Sepolia con un fork mainnet (o viceversa) los tests que interactuan con on‑chain van a revertir.

Seguridad
---------
- `checks-effects-interactions` en depósitos y retiros.
- `ReentrancyGuard` en entradas públicas mutantes.
- `Pausable` con rol dedicado para emergencias.
- `SafeERC20` y limpieza de approvals antes de aprobar un nuevo monto.
- Validación de par directo `factory.getPair(token, USDC) != address(0)`.
- Slippage configurable por constructor (`maxSlippageBps`).

Despliegue y verificacion
-------------------------
- Script: `script/DeployKipuBankV3.s.sol` (lee `V2_ROUTER` con fallback a `ROUTER`).
- Variables: `PRIVATE_KEY`, `ADMIN`, `PAUSER`, `V2_ROUTER`, `USDC`, `BANK_CAP_USD6`, `WITHDRAW_CAP_USD6`, `SLIPPAGE_BPS`, `ETH_ORACLE`, `ORACLE_MAX_DELAY`, `ORACLE_DEV_BPS`.
- Comandos:
  - `forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 --rpc-url $FORK_RPC_URL --broadcast`
  - Verificar: `--verify` (necesita `ETHERSCAN_API_KEY` exportado; `select-env.sh` lo expone si esta en `.env`).

Interaccion
-----------
- Depositos (default sin oraculo):
  - ETH: `depositar(address(0), 0)` con `msg.value > 0` o enviar ETH al `receive()`.
  - USDC: `depositar(USDC, amount)` con `approve` previo.
  - ERC‑20 con par directo: `depositar(token, amount)` con `approve` previo; hace swap y acredita.
- Deposito con oraculo (ETH):
  - `depositarEthConOraculo()` compara AMM vs Chainlink y revierte si la diferencia supera `ORACLE_DEV_BPS` o si el precio esta viejo/invalid.
- Retiros:
  - `retirar(USDC, amount)` respetando `withdrawCap`.

Pruebas con Foundry
-------------------
- Seleccionar entorno: `source script/select-env.sh mainnet` (o `testnet`).
- Fork de 1 comando: `bash script/anvil-fork.sh mainnet`.
- Ejecutar tests: `forge test --rpc-url http://127.0.0.1:8545`.
- Suites incluidas:
  - `test/KipuBankV3.t.sol`: depositos, retiros, slippage, caps, pausa y roles.
  - `test/KipuBankV3Oracle.t.sol`: ruta con oraculo y comparativa de gas. Si `ORACLE_DEV_BPS=0`, los tests de oraculo se auto‑saltan.
  - `test/CheckAmmVsOracle.t.sol`: imprime brecha AMM vs oraculo (tambien se auto‑salta si `ORACLE_DEV_BPS=0`).

Cobertura y gas
---------------
- Cobertura (resumen): `forge coverage --rpc-url http://127.0.0.1:8545 | tee reportes/coverage-resumen.txt`
  - Si aparece "stack too deep", usar `--ir-minimum`.
- Gas report: `forge test --gas-report --rpc-url http://127.0.0.1:8545 | tee reportes/gas-report.txt`
- Snapshot de gas: `forge snapshot && cp .gas-snapshot reportes/gas-snapshot.txt`

Reportes incluidos
------------------
- `reportes/gas-report.txt`: consumo de gas por funcion (incluye comparativa de la ruta con oraculo).
- `reportes/coverage-resumen.txt`: cobertura por archivo; `src/KipuBankV3.sol` supera 50% (objetivo de la consigna).
- `reportes/gas-snapshot.txt`: baseline para comparar cambios de gas entre commits.

Resumen minimo de reportes (ejemplo)
------------------------------------
Gas (extracto de `reportes/gas-report.txt`):

```
Deployment Cost: 2,190,838 gas

Function                         Avg Gas   Calls
-------------------------------- --------  -----
depositar                        117,521   19
depositarEthConOraculo           143,934   4
receive                          226,885   1
retirar                           36,448   6
```

Cobertura (extracto de `reportes/coverage-resumen.txt`):

```
src/KipuBankV3.sol   Lines 88.34% (144/163)  Funcs 85.00% (17/20)  Branches 45.65% (21/46)
Total                Lines 68.52% (148/216)
```

Notas Sepolia
-------------
- Direcciones de Uniswap en testnets pueden variar; usa `.env.example` como referencia y ajustar segun proveedor.
- Verificar que exista par directo `WETH/USDC`; sin ese par, los depositos de ETH fallan.


Cumplimiento de consignas
-------------------------
- Manejar tokens soportados (ETH/USDC/ERC20 con par directo) → OK.
- Swaps a USDC dentro del contrato → OK.
- Depositos/retiros/roles → OK.
- Respetar bank cap (pre y post swap) → OK.
- Cobertura >= 50% → OK (ver `reportes/coverage-resumen.txt`).

Apuntes de seguridad
--------------------
- Slippage protege al usuario ajustando `amountOutMin`; si no se cumple, revierte.
- La credencial final siempre usa el monto real del swap, no la cotizacion.
- La ruta con oraculo compara AMM vs Chainlink y revierte por precio viejo o desvio alto.
- Protecciones de reentrada, pausas y validaciones de parametros en todas las rutas.

Amenazas y trade‑offs
---------------------
- Manipulacion de precio en AMM: en pools poco liquidos el precio puede ser movido. La ruta default solo usa slippage; la ruta con oraculo (`depositarEthConOraculo`) compara contra Chainlink y revierte si hay desvio mayor a `ORACLE_DEV_BPS`.
- Alcance del oraculo (POC): la verificacion con oraculo esta implementada solo para ETH como prueba de concepto. Extenderla a todos los pares contra USDC requeriria feeds de oraculo por cada token, y muchos pares poco liquidos ya son vulnerables por si mismos; por eso se prioriza slippage en la ruta default y oraculo opcional en ETH.
- Liquidez en testnets: gaps grandes entre AMM y oraculo son comunes; para pruebas se sugiere `ORACLE_DEV_BPS=0` o tolerancias altas, y/o usar mainnet fork para escenarios realistas.
- Solo par directo a USDC: se evita complejidad de rutas multi‑hop, pero limita tokens aceptados. Simplifica validaciones y reduce superficie de ataque.
- Tokens no estandar: fee‑on‑transfer/rebase no estan soportados; la logica asume `transferFrom` estandar y cotizacion directa.
- Front‑running / sandwich: mitigado por slippage. El oraculo ayuda en ETH, pero no elimina MEV; la app/UX puede aumentar `slippageBps` prudencialmente o forzar la ruta con oraculo en operaciones sensibles.
- Dependencia del oraculo: si el precio esta viejo (`ORACLE_MAX_DELAY`) o el feed falla, las operaciones por la ruta con oraculo revierten (disponibilidad vs seguridad).
- DOS por cap: si el bank cap se alcanza, nuevos depositos revierten hasta que se retiren fondos.
- Roles y pausas: mal uso del pauser/admin puede frenar el sistema; se recomienda gobernanza/procesos para cambios de rol.
- Sin upgradeability: ante bugs se requiere redeploy. Menos riesgo de proxy, pero menos flexibilidad.
- Allowances: se limpia el allowance post swap por higiene; reduce riesgo de approvals colgados.
