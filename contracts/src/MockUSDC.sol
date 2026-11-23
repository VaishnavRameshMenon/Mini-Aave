
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {

    constructor()
        ERC20("Mock USD Coin", "mUSDC")
        Ownable(msg.sender)
    {}

    // USDC uses 6 decimal places
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Only the owner can create test tokens
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
