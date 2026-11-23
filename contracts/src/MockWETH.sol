
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockWETH is ERC20, Ownable {

    constructor()
        ERC20("Mock Wrapped Ether", "mWETH")
        Ownable(msg.sender)
    {}

    // WETH uses 18 decimal places
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // Only the owner can create test tokens
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
