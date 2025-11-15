// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {KipuTimelock} from "src/KipuTimelock.sol";

contract KipuTimelockTest is Test {
    address internal router;
    address internal usdc;
    address internal oracle;

    KipuTimelock internal timelock;
    KipuBankV3 internal bank;

    function setUp() public {
        // Fork segun entorno
        string memory rpc;
        try vm.envString("FORK_RPC_URL") returns (string memory frpc) { rpc = frpc; } catch { rpc = vm.envString("SEPOLIA_RPC_URL"); }
        try vm.envUint("FORK_BLOCK") returns (uint256 fb) {
            if (fb > 0) vm.createSelectFork(rpc, fb); else vm.createSelectFork(rpc);
        } catch {
            vm.createSelectFork(rpc);
        }

        router = vm.envAddress("V2_ROUTER");
        usdc = vm.envAddress("USDC");
        oracle = vm.envAddress("ETH_ORACLE");

        // Deploy timelock con minDelay=50s y este contrato como proposer/executor/admin
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelock = new KipuTimelock(50, proposers, executors, address(this));

        // Bank con admin = timelock (DEFAULT_ADMIN_ROLE)
        bank = new KipuBankV3(
            address(timelock), // admin
            address(this),     // pauser
            router,
            usdc,
            1_000_000e6,
            100_000e6,
            100,               // 1%
            oracle,
            vm.envUint("ORACLE_MAX_DELAY"),
            1000               // 10%
        );
    }

    function test_timelock_puede_actualizar_configs() public {
        // Preparar llamada: setSlippageBps(321)
        bytes memory data1 = abi.encodeWithSelector(bank.setSlippageBps.selector, 321);
        bytes32 salt1 = keccak256("op1");
        timelock.schedule(address(bank), 0, data1, bytes32(0), salt1, 50);
        vm.warp(block.timestamp + 51);
        timelock.execute(address(bank), 0, data1, bytes32(0), salt1);
        assertEq(bank.slippageBps(), 321, "slippage via timelock");

        // setOracleDevBps(555)
        bytes memory data2 = abi.encodeWithSelector(bank.setOracleDevBps.selector, 555);
        bytes32 salt2 = keccak256("op2");
        timelock.schedule(address(bank), 0, data2, bytes32(0), salt2, 50);
        vm.warp(block.timestamp + 51);
        timelock.execute(address(bank), 0, data2, bytes32(0), salt2);
        assertEq(bank.oracleDevBps(), 555, "oracleDevBps via timelock");

        // setOracle(oracle, 7200)
        bytes memory data3 = abi.encodeWithSelector(bank.setOracle.selector, oracle, 7200);
        bytes32 salt3 = keccak256("op3");
        timelock.schedule(address(bank), 0, data3, bytes32(0), salt3, 50);
        vm.warp(block.timestamp + 51);
        timelock.execute(address(bank), 0, data3, bytes32(0), salt3);
        assertEq(bank.oracleMaxDelay(), 7200, "oracleMaxDelay via timelock");
    }
}
