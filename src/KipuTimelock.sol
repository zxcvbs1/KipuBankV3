// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title KipuTimelock
/// @author Kipu
/// @notice Wrapper liviano sobre TimelockController de OpenZeppelin para administrar acciones de KipuBankV3 con demora.
contract KipuTimelock is TimelockController {
    /// @notice Despliega el timelock controller.
    /// @param minDelay demora minima para operaciones agendadas en segundos
    /// @param proposers direcciones con roles PROPOSER y CANCELLER
    /// @param executors direcciones con rol EXECUTOR
    /// @param admin admin opcional para configuracion inicial de roles (se recomienda renunciar luego)
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
