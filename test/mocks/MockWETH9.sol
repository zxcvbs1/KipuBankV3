// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockWETH9 is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function deposit() external payable {
        mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf(msg.sender) >= wad, "BAL");
        burn(msg.sender, wad);
        (bool ok, ) = msg.sender.call{value: wad}("");
        require(ok, "ETH");
        emit Withdrawal(msg.sender, wad);
    }
}
