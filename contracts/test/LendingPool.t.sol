
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract LendingPoolTest is Test {
    MockUSDC usdc;
    MockWETH weth;
    LendingPool pool;

    address alice = address(0x1234);
    address bob = address(0x5678);

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
        pool = new LendingPool();

        // Register supported assets
        pool.addAsset(address(usdc));
        pool.addAsset(address(weth));

        // Configure mock prices ($1 USDC, $2,000 WETH) and 75% LTV.
        pool.setAssetPrice(address(usdc), 1e8);
        pool.setAssetPrice(address(weth), 2_000e8);
        pool.setLTV(address(usdc), 7500);
        pool.setLTV(address(weth), 7500);

        // Give test users tokens, including WETH collateral.
        usdc.mint(alice, 10_000 * 10 ** 6);
        weth.mint(alice, 10 ether);

        usdc.mint(bob, 5_000 * 10 ** 6);
        weth.mint(bob, 10 ether);

        // Approve the pool to transfer user tokens.
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(pool), type(uint256).max);

        // Provide WETH collateral to both users so existing borrow tests
        // satisfy M6 collateral requirements without changing their scenarios.
        vm.prank(alice);
        pool.depositCollateral(address(weth), 5 ether);

        vm.prank(bob);
        pool.depositCollateral(address(weth), 5 ether);
    }

    function testSupplyUSDC() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        assertEq(
            pool.getUserSupply(alice, address(usdc)),
            1000 * 10 ** 6
        );

        assertEq(
            pool.getTotalSupplied(address(usdc)),
            1000 * 10 ** 6
        );
    }

    function testSupplyWETH() public {
        vm.prank(alice);
        pool.supply(address(weth), 2 ether);

        assertEq(
            pool.getUserSupply(alice, address(weth)),
            2 ether
        );
    }

    function testMultipleUsersCanSupply() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        vm.prank(bob);
        pool.supply(address(usdc), 500 * 10 ** 6);

        assertEq(
            pool.getTotalSupplied(address(usdc)),
            1500 * 10 ** 6
        );
    }

    function testWithdrawUSDC() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        vm.prank(alice);
        pool.withdraw(address(usdc), 400 * 10 ** 6);

        assertEq(
            pool.getUserSupply(alice, address(usdc)),
            600 * 10 ** 6
        );
    }

    function testWithdrawReturnsTokens() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        pool.withdraw(address(usdc), 1000 * 10 ** 6);

        assertEq(
            usdc.balanceOf(alice),
            balanceBefore + 1000 * 10 ** 6
        );
    }

    function testCannotWithdrawMoreThanSupplied() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient supplied balance"));

        pool.withdraw(address(usdc), 1500 * 10 ** 6);
    }

    function testCannotSupplyUnsupportedAsset() public {
        MockUSDC anotherToken = new MockUSDC();

        vm.prank(alice);
        vm.expectRevert(bytes("Unsupported asset"));

        pool.supply(address(anotherToken), 100 * 10 ** 6);
    }

    function testCannotSupplyZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Amount must be greater than zero"));

        pool.supply(address(usdc), 0);
    }

    function testOnlyOwnerCanListAsset() public {
        vm.prank(alice);
        vm.expectRevert();

        pool.addAsset(address(0x9999));
    }

    // ─────────────────────────────────────────────
    // Milestone 4 — Borrowing & Repayment
    // ─────────────────────────────────────────────

    // Helper: alice supplies 1 000 USDC so the pool has liquidity
    function _aliceSupplies1000USDC() internal {
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);
    }

    // ── Borrow happy-path ──────────────────────────

    function testBorrowReducesPoolLiquidity() public {
        _aliceSupplies1000USDC();

        uint256 liquidityBefore = pool.getAvailableLiquidity(address(usdc));

        vm.prank(bob);
        pool.borrow(address(usdc), 300 * 10 ** 6);

        assertEq(
            pool.getAvailableLiquidity(address(usdc)),
            liquidityBefore - 300 * 10 ** 6
        );
    }

    function testBorrowDeliversTokensToBorrower() public {
        _aliceSupplies1000USDC();

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        pool.borrow(address(usdc), 300 * 10 ** 6);

        assertEq(usdc.balanceOf(bob), bobBefore + 300 * 10 ** 6);
    }

    function testBorrowUpdatesUserDebt() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 300 * 10 ** 6);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 300 * 10 ** 6);
    }

    function testBorrowUpdatesTotalBorrowed() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 300 * 10 ** 6);

        assertEq(pool.getTotalBorrowed(address(usdc)), 300 * 10 ** 6);
    }

    function testMultipleUsersBorrowAccumulateCorrectly() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 200 * 10 ** 6);

        // alice also borrows (she already approved)
        vm.prank(alice);
        pool.borrow(address(usdc), 100 * 10 ** 6);

        assertEq(pool.getTotalBorrowed(address(usdc)), 300 * 10 ** 6);
        assertEq(pool.getUserBorrow(bob, address(usdc)), 200 * 10 ** 6);
        assertEq(pool.getUserBorrow(alice, address(usdc)), 100 * 10 ** 6);
    }

    function testBorrowWETH() public {
        vm.prank(alice);
        pool.supply(address(weth), 5 ether);

        vm.prank(bob);
        pool.borrow(address(weth), 1 ether);

        assertEq(pool.getUserBorrow(bob, address(weth)), 1 ether);
        assertEq(pool.getAvailableLiquidity(address(weth)), 4 ether);
    }

    // ── Borrow failure cases ───────────────────────

    function testCannotBorrowZero() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        vm.expectRevert(bytes("Amount must be greater than zero"));
        pool.borrow(address(usdc), 0);
    }

    function testCannotBorrowUnsupportedAsset() public {
        MockUSDC unknown = new MockUSDC();

        vm.prank(bob);
        vm.expectRevert(bytes("Unsupported asset"));
        pool.borrow(address(unknown), 100 * 10 ** 6);
    }

    function testCannotBorrowMoreThanAvailableLiquidity() public {
        _aliceSupplies1000USDC(); // pool has 1 000 USDC

        vm.prank(bob);
        vm.expectRevert(bytes("Insufficient pool liquidity"));
        pool.borrow(address(usdc), 1500 * 10 ** 6);
    }

    function testCannotBorrowWhenPoolIsEmpty() public {
        // No one has supplied — pool balance is 0
        vm.prank(bob);
        vm.expectRevert(bytes("Insufficient pool liquidity"));
        pool.borrow(address(usdc), 1 * 10 ** 6);
    }

    // ── Repay happy-path ──────────────────────────

    function testRepayReducesUserDebt() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 500 * 10 ** 6);

        // bob approves pool to pull the repayment
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), 200 * 10 ** 6);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 300 * 10 ** 6);
    }

    function testRepayReducesTotalBorrowed() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 500 * 10 ** 6);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), 200 * 10 ** 6);

        assertEq(pool.getTotalBorrowed(address(usdc)), 300 * 10 ** 6);
    }

    function testRepayRestoresPoolLiquidity() public {
        _aliceSupplies1000USDC();

        uint256 liquidityAfterBorrow;
        {
            vm.prank(bob);
            pool.borrow(address(usdc), 400 * 10 ** 6);
            liquidityAfterBorrow = pool.getAvailableLiquidity(address(usdc));
        }

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), 400 * 10 ** 6);

        assertEq(
            pool.getAvailableLiquidity(address(usdc)),
            liquidityAfterBorrow + 400 * 10 ** 6
        );
    }

    function testFullRepayZerosDebt() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 300 * 10 ** 6);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), 300 * 10 ** 6);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
    }

    function testRepayExcessCapsAtDebt() public {
        // Repaying more than the debt should only deduct the actual debt
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 100 * 10 ** 6);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // bob tries to repay 999 but only owes 100
        vm.prank(bob);
        pool.repay(address(usdc), 999 * 10 ** 6);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
        // bob's wallet should only have been debited 100, not 999
        // initial mint: 5 000; borrowed +100; repaid -100 → back to 5 000
        assertEq(usdc.balanceOf(bob), 5_000 * 10 ** 6);
    }

    // ── Repay failure cases ────────────────────────

    function testCannotRepayZero() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 100 * 10 ** 6);

        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(bytes("Amount must be greater than zero"));
        pool.repay(address(usdc), 0);
    }

    function testCannotRepayWithNoDebt() public {
        // bob never borrowed anything
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(bytes("No outstanding debt"));
        pool.repay(address(usdc), 100 * 10 ** 6);
    }

    function testCannotRepayUnsupportedAsset() public {
        MockUSDC unknown = new MockUSDC();

        vm.prank(bob);
        vm.expectRevert(bytes("Unsupported asset"));
        pool.repay(address(unknown), 100 * 10 ** 6);
    }

    // ── Interaction: supply/borrow/withdraw guard ──

    function testWithdrawRespectsBorrowedLiquidity() public {
        // alice supplies 1 000; bob borrows 800; alice tries to withdraw 500
        // pool only has 200 liquid — withdrawal should revert
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 800 * 10 ** 6);

        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient pool liquidity"));
        pool.withdraw(address(usdc), 500 * 10 ** 6);
    }

    // ─────────────────────────────────────────────
    // Milestone 5 — Basic Interest Mechanics
    // ─────────────────────────────────────────────
    //
    // Interest model:
    //   Simple (non-compounding) fixed annual rate = 500 BPS (5 %)
    //   interest = principal × 500 × elapsed_seconds
    //              ────────────────────────────────────
    //              10 000 × 365 days
    //
    // All tests use vm.warp() to advance block.timestamp.
    // ─────────────────────────────────────────────

    // ── Helper constants ───────────────────────────

    uint256 constant ANNUAL_RATE_BPS  = 500;
    uint256 constant BPS_DENOM        = 10_000;
    uint256 constant SECS_PER_YEAR    = 365 days;

    /// @dev Replicate the contract's interest formula for test assertions.
    function _expectedInterest(
        uint256 principal,
        uint256 elapsed
    ) internal pure returns (uint256) {
        return (principal * ANNUAL_RATE_BPS * elapsed) /
               (BPS_DENOM * SECS_PER_YEAR);
    }

    // ── No interest when no time passes ───────────

    function testNoInterestAccruedInSameBlock() public {
        _aliceSupplies1000USDC();

        vm.prank(bob);
        pool.borrow(address(usdc), 1000 * 10 ** 6);

        // No warp — same block
        assertEq(
            pool.getUserBorrow(bob, address(usdc)),
            1000 * 10 ** 6
        );
    }

    // ── Interest accrues after time passes ────────

    function testInterestAccruedAfterOneYear() public {
        _aliceSupplies1000USDC();

        uint256 principal = 1000 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        // Advance exactly one year
        vm.warp(block.timestamp + 365 days);

        // 5 % of 1 000 USDC = 50 USDC
        uint256 expectedInterest = _expectedInterest(principal, 365 days);
        assertEq(expectedInterest, 50 * 10 ** 6); // sanity check

        assertEq(
            pool.getUserBorrow(bob, address(usdc)),
            principal + expectedInterest
        );
    }

    function testInterestAccruedAfterSixMonths() public {
        _aliceSupplies1000USDC();

        uint256 principal = 1000 * 10 ** 6;
        uint256 elapsed   = 365 days / 2;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + elapsed);

        uint256 expectedDebt = principal + _expectedInterest(principal, elapsed);
        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedDebt);
    }

    function testInterestAccruedAfterOneDay() public {
        _aliceSupplies1000USDC();

        uint256 principal = 1000 * 10 ** 6;
        uint256 elapsed   = 1 days;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + elapsed);

        uint256 expectedDebt = principal + _expectedInterest(principal, elapsed);
        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedDebt);
    }

    function testInterestOnWETHBorrow() public {
        // alice supplies 5 WETH; bob borrows 2 WETH; warp 1 year
        vm.prank(alice);
        pool.supply(address(weth), 5 ether);

        uint256 principal = 2 ether;

        vm.prank(bob);
        pool.borrow(address(weth), principal);

        vm.warp(block.timestamp + 365 days);

        uint256 expectedDebt = principal + _expectedInterest(principal, 365 days);
        assertEq(pool.getUserBorrow(bob, address(weth)), expectedDebt);
    }

    // ── Interest is materialised on borrow / repay ─

    function testSecondBorrowMaterialisesAccruedInterest() public {
        // alice supplies 2 000 USDC so there is enough liquidity for two borrows
        vm.prank(alice);
        pool.supply(address(usdc), 2000 * 10 ** 6);

        uint256 firstBorrow = 500 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), firstBorrow);

        // Advance half a year
        uint256 elapsed = 365 days / 2;
        vm.warp(block.timestamp + elapsed);

        uint256 interestOnFirst = _expectedInterest(firstBorrow, elapsed);

        // Bob borrows again — this should materialise the accrued interest first
        uint256 secondBorrow = 200 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), secondBorrow);

        // After the second borrow the stored balance should be:
        //   firstBorrow + interestOnFirst + secondBorrow
        uint256 expectedDebt = firstBorrow + interestOnFirst + secondBorrow;

        // getUserBorrow is now called in the same block as the second borrow,
        // so no additional interest has accrued yet
        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedDebt);
    }

    // ── Repayment after interest has accrued ──────

    function testRepayAfterInterestAccrues() public {
        _aliceSupplies1000USDC();

        uint256 principal = 500 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + 365 days);

        // Full debt = principal + 1-year interest
        uint256 interest      = _expectedInterest(principal, 365 days);
        uint256 totalDebt     = principal + interest;

        // Mint extra USDC to bob so he can cover the interest too
        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // Repay the entire debt
        vm.prank(bob);
        pool.repay(address(usdc), totalDebt);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
    }

    function testPartialRepayAfterInterest() public {
        _aliceSupplies1000USDC();

        uint256 principal = 1000 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + 365 days);

        // After 1 year debt = 1 050 USDC
        uint256 interest  = _expectedInterest(principal, 365 days);
        uint256 totalDebt = principal + interest; // 1 050 * 10**6

        // Mint extra for the interest portion
        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // Repay only half of the total debt
        uint256 partialRepay = totalDebt / 2;
        vm.prank(bob);
        pool.repay(address(usdc), partialRepay);

        // Remaining debt: totalDebt - partialRepay
        // getUserBorrow is called in the same block as repay → no new interest
        assertEq(
            pool.getUserBorrow(bob, address(usdc)),
            totalDebt - partialRepay
        );
    }

    // ── Excess repayment still caps at actual debt ─

    function testRepayExcessAfterInterestCapsAtDebt() public {
        _aliceSupplies1000USDC();

        uint256 principal = 100 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + 365 days);

        uint256 interest  = _expectedInterest(principal, 365 days);
        uint256 totalDebt = principal + interest;

        // Mint enough for the interest
        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        // Attempt to repay far more than owed — should cap at totalDebt
        vm.prank(bob);
        pool.repay(address(usdc), type(uint256).max / 2);

        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
        // Bob's wallet was debited exactly totalDebt, not the huge amount
        assertEq(usdc.balanceOf(bob), bobBalanceBefore - totalDebt);
    }

    // ── Multiple users accrue interest independently ─

    function testMultipleUsersBorrowAndAccrueIndependently() public {
        // Supply enough for both
        vm.prank(alice);
        pool.supply(address(usdc), 2000 * 10 ** 6);

        uint256 bobPrincipal   = 600 * 10 ** 6;
        uint256 alicePrincipal = 400 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), bobPrincipal);

        vm.prank(alice);
        pool.borrow(address(usdc), alicePrincipal);

        // Advance one year — both borrowed at the same timestamp
        vm.warp(block.timestamp + 365 days);

        uint256 bobExpected   = bobPrincipal   + _expectedInterest(bobPrincipal,   365 days);
        uint256 aliceExpected = alicePrincipal + _expectedInterest(alicePrincipal, 365 days);

        assertEq(pool.getUserBorrow(bob,   address(usdc)), bobExpected);
        assertEq(pool.getUserBorrow(alice, address(usdc)), aliceExpected);
    }

    // ── Multiple assets accrue interest independently ─

    function testInterestOnMultipleAssetsIndependently() public {
        // alice supplies both USDC and WETH
        vm.prank(alice);
        pool.supply(address(usdc), 1000 * 10 ** 6);

        vm.prank(alice);
        pool.supply(address(weth), 5 ether);

        uint256 usdcBorrow = 400 * 10 ** 6;
        uint256 wethBorrow = 2 ether;

        vm.prank(bob);
        pool.borrow(address(usdc), usdcBorrow);

        vm.prank(bob);
        pool.borrow(address(weth), wethBorrow);

        vm.warp(block.timestamp + 365 days);

        uint256 expectedUSDC = usdcBorrow + _expectedInterest(usdcBorrow, 365 days);
        uint256 expectedWETH = wethBorrow + _expectedInterest(wethBorrow, 365 days);

        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedUSDC);
        assertEq(pool.getUserBorrow(bob, address(weth)), expectedWETH);
    }

    // ── totalBorrowed is updated when interest is materialised ──

    function testTotalBorrowedIncreasesWhenInterestMaterialised() public {
        _aliceSupplies1000USDC();

        uint256 principal = 1000 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        uint256 totalAfterBorrow = pool.getTotalBorrowed(address(usdc));
        assertEq(totalAfterBorrow, principal);

        // Advance 1 year, then trigger materialisation via a second borrow
        vm.warp(block.timestamp + 365 days);

        // alice supplies more so there is liquidity for another borrow
        vm.prank(alice);
        pool.supply(address(usdc), 100 * 10 ** 6);

        // A tiny second borrow by bob materialises the interest
        vm.prank(bob);
        pool.borrow(address(usdc), 1 * 10 ** 6);

        uint256 interest = _expectedInterest(principal, 365 days);

        // totalBorrowed should now include the materialised interest + new borrow
        assertEq(
            pool.getTotalBorrowed(address(usdc)),
            principal + interest + 1 * 10 ** 6
        );
    }

    // ── Timestamp is reset to zero on full repayment ──

    function testTimestampResetAfterFullRepay() public {
        _aliceSupplies1000USDC();

        uint256 principal = 200 * 10 ** 6;

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + 365 days);

        uint256 interest  = _expectedInterest(principal, 365 days);
        uint256 totalDebt = principal + interest;

        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), totalDebt);

        // Fully repaid: lastAccrualTimestamp should be cleared (== 0)
        assertEq(pool.lastAccrualTimestamp(address(usdc), bob), 0);
        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
    }

    // ── Edge: short elapsed time (sub-second precision) ───────────

    function testVerySmallElapsedProducesZeroInterest() public {
        // With a 100-token borrow and 1 second elapsed the interest
        // is likely 0 due to integer truncation — the formula should
        // not revert and principal must be unchanged.
        _aliceSupplies1000USDC();

        uint256 principal = 100 * 10 ** 6; // 100 USDC

        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        vm.warp(block.timestamp + 1); // 1 second

        uint256 computedInterest = _expectedInterest(principal, 1);
        // This should round to 0 for a 100-token loan over 1 second
        // (100e6 * 500 * 1) / (10000 * 31536000) = 50_000_000_000 / 315_360_000_000 = 0
        assertEq(computedInterest, 0);

        // getUserBorrow should equal exactly principal (no interest yet)
        assertEq(pool.getUserBorrow(bob, address(usdc)), principal);
    }

    // ── Edge: getUserBorrow returns 0 for user with no debt ──────

    function testGetUserBorrowZeroForNonBorrower() public {
        assertEq(pool.getUserBorrow(alice, address(usdc)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Milestone 5 (revised) — Non-compounding correctness proofs
    // ─────────────────────────────────────────────────────────────

    // ── Proof: interest never compounds across multiple interactions ──

    /**
     * This test is the definitive proof that the fix for audit Finding #1
     * works. With the old model (interest added to borrowedBalance),
     * two materialisation events over 1 year would produce slightly more
     * than 5 % total interest (compound drift). With the new model
     * (interest stored separately, always computed on `principal`),
     * the total after any number of interactions must equal exactly
     * principal × rate × total_elapsed — i.e., pure simple interest.
     *
     * Scenario: borrow 1 000 USDC; interact at 6 months; check at 1 year.
     * Simple interest:   1 000 × 5 % × 1 yr  = 50 USDC exactly.
     * Compound (old):    ~50.625 USDC (interest accrues on interest).
     */
    function testNoCompoundingAcrossMultipleInteractions() public {
        // alice supplies 2 000 USDC so liquidity is available throughout
        vm.prank(alice);
        pool.supply(address(usdc), 2000 * 10 ** 6);

        uint256 principal = 1000 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), principal);

        uint256 t0 = block.timestamp;

        // ── 6-month mark: trigger a materialisation via a tiny second borrow ──
        vm.warp(t0 + 365 days / 2);
        vm.prank(bob);
        pool.borrow(address(usdc), 1); // 1 wei borrow forces _accrueInterest

        // ── 1-year mark: check total debt ──
        vm.warp(t0 + 365 days);

        // With TRUE simple interest over 1 year on 1 000 USDC at 5 %:
        //   interest on first 500 USDC borrow = 1 000 × 5 % × 1 yr = 50 USDC
        //   (the 1-wei borrow adds negligible interest; we ignore it here)
        //
        // Expected debt = 1 000 USDC (principal)
        //               + 1 wei (second borrow principal)
        //               + interest on (1 000 USDC × 0.5 yr)   [materialised at 6-mo mark]
        //               + interest on (1 000 USDC + 1 wei × 0.5 yr) [unmaterialised, view only]
        //
        // For compactness we use the helper and add the 1-wei borrow.
        uint256 interestFirst  = _expectedInterest(principal, 365 days / 2);
        uint256 newPrincipal   = principal + 1; // after second borrow
        uint256 interestSecond = _expectedInterest(newPrincipal, 365 days / 2);

        uint256 expectedDebt = newPrincipal + interestFirst + interestSecond;
        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedDebt);

        // Sanity: total interest (ignoring the 1-wei rounding) is ~50 USDC,
        // NOT ~50.625 USDC that the old compounding model would produce.
        // interestFirst + interestSecond ≈ 25 + 25 = 50 USDC.
        uint256 totalInterest = interestFirst + interestSecond;
        uint256 simpleInterest = _expectedInterest(principal, 365 days);
        // Allow a 1-wei rounding difference from the extra 1-wei principal.
        assertApproxEqAbs(totalInterest, simpleInterest, 1);
    }

    // ── Repayment order: interest first, then principal ───────────

    function testRepayCoversInterestBeforePrincipal() public {
        _aliceSupplies1000USDC();

        uint256 p = 1000 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), p);

        // Warp so 50 USDC of interest accrues
        vm.warp(block.timestamp + 365 days);
        uint256 interest = _expectedInterest(p, 365 days); // 50 USDC

        // Bob mints just enough to cover the interest portion
        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // Repay exactly the interest amount — principal should be untouched
        vm.prank(bob);
        pool.repay(address(usdc), interest);

        // Remaining debt should be exactly `p` (principal) with no additional
        // interest (repay and getUserBorrow are in the same block)
        assertEq(pool.getUserBorrow(bob, address(usdc)), p);

        // Verify by decomposing storage directly
        assertEq(pool.principal(address(usdc), bob), p);
        assertEq(pool.accruedInterest(address(usdc), bob), 0);
    }

    function testRepayPartialInterestOnly() public {
        _aliceSupplies1000USDC();

        uint256 p = 1000 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), p);

        vm.warp(block.timestamp + 365 days);
        uint256 interest = _expectedInterest(p, 365 days); // 50 USDC

        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // Pay half the interest — principal must remain intact
        vm.prank(bob);
        pool.repay(address(usdc), interest / 2);

        assertEq(pool.principal(address(usdc), bob), p);
        assertEq(pool.accruedInterest(address(usdc), bob), interest - interest / 2);
    }

    // ── Borrow → full repay → borrow again (timestamp-reset path) ──

    function testBorrowAfterFullRepayStartsFreshClock() public {
        _aliceSupplies1000USDC();

        uint256 p1 = 400 * 10 ** 6;

        // ── First borrow ──
        vm.prank(bob);
        pool.borrow(address(usdc), p1);
        uint256 t0 = block.timestamp;

        // Warp 1 year
        vm.warp(t0 + 365 days);
        uint256 interest1 = _expectedInterest(p1, 365 days);

        // Fully repay (principal + interest)
        usdc.mint(bob, interest1);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), p1 + interest1);

        // Confirm clean slate
        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
        assertEq(pool.principal(address(usdc), bob), 0);
        assertEq(pool.accruedInterest(address(usdc), bob), 0);
        assertEq(pool.lastAccrualTimestamp(address(usdc), bob), 0);

        // ── Second borrow (fresh start) ──
        uint256 p2 = 200 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), p2);
        uint256 t1 = block.timestamp;

        // Immediately after borrow — no interest yet
        assertEq(pool.getUserBorrow(bob, address(usdc)), p2);

        // Warp another 6 months from t1
        vm.warp(t1 + 365 days / 2);
        uint256 interest2 = _expectedInterest(p2, 365 days / 2);

        // Debt should be only the new principal + its own interest.
        // No phantom interest from the previous position.
        assertEq(pool.getUserBorrow(bob, address(usdc)), p2 + interest2);
    }

    // ── Accrued interest is never the base for further interest ───

    function testAccruedInterestDoesNotGenerateFurtherInterest() public {
        // Demonstrate that the accruedInterest bucket is frozen: even after
        // it accumulates, waiting longer only adds interest on the original
        // principal — not on accruedInterest.
        vm.prank(alice);
        pool.supply(address(usdc), 2000 * 10 ** 6);

        uint256 p = 1000 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), p);

        uint256 t0 = block.timestamp;

        // ── Trigger materialisation at 6 months (via a 1-wei borrow) ──
        vm.warp(t0 + 365 days / 2);
        vm.prank(bob);
        pool.borrow(address(usdc), 1);
        // Now accruedInterest[usdc][bob] = ~25 USDC (interest on 1000 USDC × 0.5yr)

        uint256 accrued6mo = pool.accruedInterest(address(usdc), bob);
        assertEq(accrued6mo, _expectedInterest(p, 365 days / 2));

        // ── Wait another 6 months without any interaction ──
        vm.warp(t0 + 365 days);

        // The view function must show:
        //   principal (1000 USDC + 1 wei)  +  accrued (frozen ~25 USDC)
        //   + unmaterialised interest on principal for the second half-year
        //   = NOT on (principal + accrued).
        uint256 newPrincipal      = p + 1;
        uint256 unmaterialised    = _expectedInterest(newPrincipal, 365 days / 2);
        uint256 expectedTotalDebt = newPrincipal + accrued6mo + unmaterialised;

        assertEq(pool.getUserBorrow(bob, address(usdc)), expectedTotalDebt);

        // Cross-check: the TOTAL interest paid over the year (both halves)
        // must be approximately equal to simple interest on the original principal,
        // NOT simple interest on (principal + mid-year accrued).
        uint256 totalInterestPaid = accrued6mo + unmaterialised;
        uint256 trueSimple        = _expectedInterest(p, 365 days);
        // Allow 2-wei rounding from the extra 1-wei borrow
        assertApproxEqAbs(totalInterestPaid, trueSimple, 2);
    }

    // ── Finding #2 — totalBorrowed gap documented and tested ──────

    /**
     * Verifies the documented limitation: totalBorrowed understates the
     * real outstanding debt between materialisation events.
     * This is NOT a solvency bug — the pool receives MORE tokens on
     * repayment than it lent out (principal + interest), so it never
     * runs out of tokens due to interest accrual.
     */
    function testTotalBorrowedUnderstatementIsAccountingOnly() public {
        _aliceSupplies1000USDC();

        uint256 p = 500 * 10 ** 6;
        vm.prank(bob);
        pool.borrow(address(usdc), p);

        // totalBorrowed reflects principal only right after borrow
        assertEq(pool.getTotalBorrowed(address(usdc)), p);

        // Advance 1 year — interest of 25 USDC has accrued but NOT materialised
        vm.warp(block.timestamp + 365 days);
        uint256 interest = _expectedInterest(p, 365 days);

        // getUserBorrow (live view) includes the unmaterialised interest
        assertEq(pool.getUserBorrow(bob, address(usdc)), p + interest);

        // getTotalBorrowed does NOT yet include it — documented limitation
        assertEq(pool.getTotalBorrowed(address(usdc)), p);
        // The gap = real debt - totalBorrowed = interest
        assertEq(pool.getUserBorrow(bob, address(usdc)) - pool.getTotalBorrowed(address(usdc)), interest);

        // After repayment, the pool receives MORE tokens than it held lent out,
        // confirming there is no solvency hole.
        uint256 poolBalanceBefore = pool.getAvailableLiquidity(address(usdc));

        usdc.mint(bob, interest);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(address(usdc), p + interest);

        uint256 poolBalanceAfter = pool.getAvailableLiquidity(address(usdc));

        // Pool received exactly p + interest back — balance grew by that amount
        assertEq(poolBalanceAfter, poolBalanceBefore + p + interest);

        // Debt is now zero; totalBorrowed is consistent again
        assertEq(pool.getTotalBorrowed(address(usdc)), 0);
        assertEq(pool.getUserBorrow(bob, address(usdc)), 0);
    }
}
