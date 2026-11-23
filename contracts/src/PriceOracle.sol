
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PriceOracle is Ownable {
    mapping(address => uint256) public prices;

    uint256 public constant PRICE_DECIMALS = 1e8;

    event PriceUpdated(address indexed asset, uint256 price);

    constructor() Ownable(msg.sender) {}

    function setPrice(address asset, uint256 price) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        require(price > 0, "Price must be positive");

        prices[asset] = price;

        emit PriceUpdated(asset, price);
    }

    function getPrice(address asset) external view returns (uint256) {
        require(prices[asset] > 0, "Price not set");
        return prices[asset];
    }
}
