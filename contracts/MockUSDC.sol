// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        // Mint 1,000,000 USDC to whoever deploys this (for testing only)
        _mint(msg.sender, 1_000_000 * 10**6);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // matches real USDC
    }

    // Lets tests give USDC to any test account easily
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}