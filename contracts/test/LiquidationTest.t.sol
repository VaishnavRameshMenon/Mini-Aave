// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract LiquidationTest is Test {
    MockUSDC usdc;
    MockWETH weth;
    LendingPool pool;
    address borrower = address(0xB0B);
    address liquidator = address(0x1111);
    address supplier = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
        pool = new LendingPool();
        pool.addAsset(address(usdc));
        pool.addAsset(address(weth));
        pool.setAssetPrice(address(usdc), 1e8);
        pool.setAssetPrice(address(weth), 2_000e8);
        pool.setLTV(address(usdc), 7500);
        pool.setLTV(address(weth), 7500);

        usdc.mint(supplier, 20_000e6);
        weth.mint(borrower, 10 ether);
        usdc.mint(liquidator, 10_000e6);

        vm.prank(supplier);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(supplier);
        pool.supply(address(usdc), 20_000e6);

        vm.prank(borrower);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        pool.depositCollateral(address(weth), 5 ether);

        vm.prank(borrower);
        pool.borrow(address(usdc), 7_000e6);

        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _makeUnhealthy() internal {
        pool.setAssetPrice(address(weth), 1_500e8);
    }

    function testHealthFactorHealthyInitially() public view {
        assertGt(pool.getHealthFactor(borrower), 1e18);
    }

    function testHealthFactorDropsWhenCollateralPriceDrops() public {
        _makeUnhealthy();
        assertLt(pool.getHealthFactor(borrower), 1e18);
    }

    function testCannotLiquidateHealthyBorrower() public {
        vm.prank(liquidator);
        vm.expectRevert(bytes("Borrower is healthy"));
        pool.liquidate(borrower, address(usdc), address(weth), 1_000e6);
    }

    function testLiquidationRepaysDebtAndSeizesCollateral() public {
        _makeUnhealthy();
        uint256 debtBefore = pool.getUserBorrow(borrower, address(usdc));
        uint256 collateralBefore = pool.getUserCollateral(borrower, address(weth));
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = pool.liquidate(borrower, address(usdc), address(weth), 2_000e6);
        assertGt(repaid, 0);
        assertGt(seized, 0);
        assertEq(pool.getUserBorrow(borrower, address(usdc)), debtBefore - repaid);
        assertEq(pool.getUserCollateral(borrower, address(weth)), collateralBefore - seized);
        assertEq(weth.balanceOf(liquidator), seized);
    }

    function testLiquidatorGetsBonusCollateral() public {
        _makeUnhealthy();
        vm.prank(liquidator);
        (, uint256 seized) = pool.liquidate(borrower, address(usdc), address(weth), 1_000e6);
        // At $1,500/WETH, $1,000 debt repayment + 10% bonus = $1,100 collateral.
        uint256 expected = (uint256(1100) * 1 ether) / uint256(1500);
        require(seized >= expected - 1 && seized <= expected + 1, "Incorrect bonus collateral");
    }

    function testCloseFactorLimitsLiquidationToHalfDebt() public {
        _makeUnhealthy();
        uint256 debtBefore = pool.getUserBorrow(borrower, address(usdc));
        vm.prank(liquidator);
        (uint256 repaid,) = pool.liquidate(borrower, address(usdc), address(weth), type(uint256).max);
        uint256 expected = debtBefore / 2;
        require(repaid >= expected - 1 && repaid <= expected + 1, "Close factor not respected");
    }

    function testCannotSelfLiquidate() public {
        _makeUnhealthy();
        vm.prank(borrower);
        vm.expectRevert(bytes("Cannot self-liquidate"));
        pool.liquidate(borrower, address(usdc), address(weth), 1e6);
    }

    function testLiquidationUpdatesTotalCollateral() public {
        _makeUnhealthy();
        uint256 totalBefore = pool.getTotalCollateral(address(weth));
        vm.prank(liquidator);
        (, uint256 seized) = pool.liquidate(borrower, address(usdc), address(weth), 1_000e6);
        assertEq(pool.getTotalCollateral(address(weth)), totalBefore - seized);
    }

    function testLiquidationUpdatesPoolDebtAccounting() public {
        _makeUnhealthy();
        uint256 totalBefore = pool.getTotalBorrowed(address(usdc));
        vm.prank(liquidator);
        (uint256 repaid,) = pool.liquidate(borrower, address(usdc), address(weth), 1_000e6);
        assertEq(pool.getTotalBorrowed(address(usdc)), totalBefore - repaid);
    }
}
