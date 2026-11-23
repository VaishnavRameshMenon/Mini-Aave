
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";

contract MockTokensTest is Test {
    MockUSDC public usdc;
    MockWETH public weth;

    address public user = address(0x1234);

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
    }

    function testUSDCTokenDetails() public view {
        assertEq(usdc.name(), "Mock USD Coin");
        assertEq(usdc.symbol(), "mUSDC");
        assertEq(usdc.decimals(), 6);
    }

    function testWETHTokenDetails() public view {
        assertEq(weth.name(), "Mock Wrapped Ether");
        assertEq(weth.symbol(), "mWETH");
        assertEq(weth.decimals(), 18);
    }

    function testMintUSDC() public {
        usdc.mint(user, 1000 * 10 ** 6);

        assertEq(usdc.balanceOf(user), 1000 * 10 ** 6);
    }

    function testMintWETH() public {
        weth.mint(user, 2 ether);

        assertEq(weth.balanceOf(user), 2 ether);
    }

    function testOnlyOwnerCanMintUSDC() public {
        vm.prank(user);

        vm.expectRevert();
        usdc.mint(user, 100 * 10 ** 6);
    }

    function testOnlyOwnerCanMintWETH() public {
        vm.prank(user);

        vm.expectRevert();
        weth.mint(user, 1 ether);
    }

    function testTokenTransfer() public {
        usdc.mint(address(this), 1000 * 10 ** 6);

        usdc.transfer(user, 250 * 10 ** 6);

        assertEq(usdc.balanceOf(user), 250 * 10 ** 6);
    }

    function testApprovalAndTransferFrom() public {
        usdc.mint(address(this), 1000 * 10 ** 6);

        usdc.approve(address(this), 500 * 10 ** 6);

        usdc.transferFrom(
            address(this),
            user,
            500 * 10 ** 6
        );

        assertEq(usdc.balanceOf(user), 500 * 10 ** 6);
    }
}
