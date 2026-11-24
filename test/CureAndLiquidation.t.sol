// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MudarabahPool.sol";
import "../src/MurabahaFinancing.sol";
import "../src/MockOracle.sol";
import "./mocks/ERC20Mock.sol";

contract CureAndLiquidationTest is Test {
    MudarabahPool pool;
    MurabahaFinancing murabaha;
    MockOracle oracle;
    ERC20Mock usdc;
    ERC20Mock weth;

    address lender = address(0xA11CE);
    address borrower = address(0xB0B);
    address liquidator = address(0x11F);
    address treasury = address(0x7BE5);
    address charity = address(0xC4A);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC");
        weth = new ERC20Mock("WETH", "WETH");
        oracle = new MockOracle();
        oracle.setPrice(2000e18);

        pool = new MudarabahPool(address(usdc), treasury);
        murabaha = new MurabahaFinancing(address(usdc), address(weth), address(oracle), address(pool), charity);
        pool.setFinancingContract(address(murabaha));

        // Lender deposits 10,000
        usdc.mint(lender, 10_000e18);
        vm.prank(lender);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(10_000e18);

        // Borrower setup
        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(murabaha), type(uint256).max);
        usdc.approve(address(murabaha), type(uint256).max);
        vm.stopPrank();

        // Liquidator setup
        usdc.mint(liquidator, 100_000e18);
        vm.prank(liquidator);
        usdc.approve(address(murabaha), type(uint256).max);
    }

    function _openLoan() internal {
        // cost 1000, sale 1100, 4 installments of 275
        // collateral = 1100 * 1.5 / 2000 = 0.825 ETH
        vm.prank(borrower);
        murabaha.requestFinancing(1000e18, 4);
    }

    // ─────────────────────────────────────────────────────────────────
    // 1. Flag requires unhealthy ratio
    // ─────────────────────────────────────────────────────────────────
    function testFlag_RevertsWhenHealthy() public {
        _openLoan();
        vm.expectRevert("Position healthy");
        murabaha.flagUnhealthy(borrower);
    }

    function testFlag_SucceedsWhenBelowThreshold() public {
        _openLoan();
        oracle.setPrice(1600e18); // collateral 1320, debt 1100 → ratio 120%

        vm.prank(address(0x999)); // arbitrary caller
        murabaha.flagUnhealthy(borrower);

        assertTrue(murabaha.isFlagged(borrower));
        uint256 deadline = murabaha.cureDeadline(borrower);
        assertEq(deadline, block.timestamp + 60 hours);
    }

    // ─────────────────────────────────────────────────────────────────
    // 2. Cure via topUp resets the flag
    // ─────────────────────────────────────────────────────────────────
    function testTopUp_CuresDuringCureWindow() public {
        _openLoan();
        oracle.setPrice(1600e18); // ratio 120%
        murabaha.flagUnhealthy(borrower);

        // Need to reach 150%: required collateral = 1100 * 1.5 / 1600 = 1.03125 ETH
        // Current = 0.825 ETH → topUp 0.20625 ETH
        uint256 need = 1_031_250_000_000_000_000 - 825_000_000_000_000_000; // 0.20625 ETH
        vm.prank(borrower);
        murabaha.topUp(need);

        assertFalse(murabaha.isFlagged(borrower), "Flag not cleared");
        assertGe(murabaha.healthRatio(borrower), 150e16);
    }

    // ─────────────────────────────────────────────────────────────────
    // 3. Cannot liquidate during cure window (non-critical)
    // ─────────────────────────────────────────────────────────────────
    function testCannotLiquidateDuringCureWindow() public {
        _openLoan();
        oracle.setPrice(1600e18); // 120%
        murabaha.flagUnhealthy(borrower);

        // 30h later — still inside 60h cure window
        vm.warp(block.timestamp + 30 hours);

        vm.prank(liquidator);
        vm.expectRevert("Not liquidatable");
        murabaha.liquidate(borrower, 0);
    }

    // ─────────────────────────────────────────────────────────────────
    // 4. Can liquidate after cure window — dynamic discount ramps up
    // ─────────────────────────────────────────────────────────────────
    function testDiscountRampsAfterCure() public {
        _openLoan();
        oracle.setPrice(1600e18);
        uint256 flaggedAt = block.timestamp;
        murabaha.flagUnhealthy(borrower);

        // At end of cure window: discount = MIN (1%)
        vm.warp(flaggedAt + 60 hours);
        assertEq(murabaha.currentDiscount(borrower), 1e16);

        // 24h into ramp: discount ≈ 5.5%
        vm.warp(flaggedAt + 60 hours + 24 hours);
        assertApproxEqAbs(murabaha.currentDiscount(borrower), 55_000_000_000_000_000, 1e15);

        // 48h after cure: discount = MAX (10%)
        vm.warp(flaggedAt + 60 hours + 48 hours);
        assertEq(murabaha.currentDiscount(borrower), 10e16);
    }

    // ─────────────────────────────────────────────────────────────────
    // 5. Partial liquidation restores target ratio, borrower keeps most collateral
    // ─────────────────────────────────────────────────────────────────
    function testPartialLiquidation_RestoresTarget() public {
        _openLoan();
        oracle.setPrice(1600e18);
        murabaha.flagUnhealthy(borrower);

        // Wait past cure window
        vm.warp(block.timestamp + 61 hours);

        uint256 borrowerCollBefore = weth.balanceOf(borrower);

        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0); // auto partial

        // Position should still be active — partial, not full
        (,,,, uint256 remainingCollateral,,,,,, bool active) = murabaha.financings(borrower);
        assertTrue(active, "Should be partial (still active)");

        // Ratio restored to at least TARGET_RATIO
        assertGe(murabaha.healthRatio(borrower), 155e16, "Ratio not restored");
        // Flag cleared
        assertFalse(murabaha.isFlagged(borrower));

        // Borrower still holds significant collateral (only part seized)
        uint256 seized = 825_000_000_000_000_000 - remainingCollateral;
        assertLt(seized, 825_000_000_000_000_000, "All collateral was taken");
        assertGt(remainingCollateral, 0);

        // Borrower's wallet unchanged (they never sent more collateral out)
        assertEq(weth.balanceOf(borrower), borrowerCollBefore);
    }

    // ─────────────────────────────────────────────────────────────────
    // 6. Partial liquidation at low discount is cheap for borrower
    // ─────────────────────────────────────────────────────────────────
    function testPartialLiquidation_LowDiscountEarlyIsFair() public {
        _openLoan();
        oracle.setPrice(1600e18);
        murabaha.flagUnhealthy(borrower);
        vm.warp(block.timestamp + 60 hours); // just past cure, discount = 1%

        uint256 poolUsdcBefore = usdc.balanceOf(address(pool));

        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        // Liquidator paid pool for seized collateral value at 1% discount
        // Auto-sized x = (1.55 * 1100 - 1320) / 0.55 = 385 / 0.55 ≈ 700 USDC
        uint256 poolGain = usdc.balanceOf(address(pool)) - poolUsdcBefore;
        uint256 costBasisReduced = 636e18;
        uint256 expectedProfit = poolGain - costBasisReduced;
        assertGt(poolGain, 0, "Pool received nothing");
        assertGt(expectedProfit, 0, "Pool should earn small profit from liquidation");
    }

    // ─────────────────────────────────────────────────────────────────
    // 7. Critical drop → immediate liquidation, no cure wait
    // ─────────────────────────────────────────────────────────────────
    function testCriticalDrop_ImmediateLiquidation() public {
        _openLoan();

        // Actually we can't flag at 150%, so drop first
        oracle.setPrice(1600e18);
        murabaha.flagUnhealthy(borrower);

        // Immediate crash to 1000 → collateral 825, debt 1100 → ratio 75%
        oracle.setPrice(1000e18);

        // Liquidate immediately, no warp
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        // Critical forces full liquidation
        (,,,,,,,,,, bool active) = murabaha.financings(borrower);
        assertFalse(active, "Should be fully liquidated");
        assertEq(pool.totalReceivables(), 0);
        assertGt(pool.totalLossRecorded(), 0, "Pool should record loss");
    }

    // ─────────────────────────────────────────────────────────────────
    // 8. Partial liquidation too small → revert
    // ─────────────────────────────────────────────────────────────────
    function testPartialLiquidation_RevertsBelowMinimum() public {
        _openLoan();
        oracle.setPrice(1600e18);
        murabaha.flagUnhealthy(borrower);
        vm.warp(block.timestamp + 61 hours);

        vm.prank(liquidator);
        vm.expectRevert("Partial must restore TARGET_RATIO");
        murabaha.liquidate(borrower, 100e18); // way under minimum
    }

    // ─────────────────────────────────────────────────────────────────
    // 9. Multiple sequential partial liquidations converge to healthy
    // ─────────────────────────────────────────────────────────────────
    function testSequentialPartialsEndWithHealthyPosition() public {
        _openLoan();
        oracle.setPrice(1600e18);
        murabaha.flagUnhealthy(borrower);
        vm.warp(block.timestamp + 61 hours);

        // First partial — restores to 155%
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);
        assertFalse(murabaha.isFlagged(borrower));

        // Price drops again → flag & liquidate
        oracle.setPrice(1400e18);
        murabaha.flagUnhealthy(borrower);
        vm.warp(block.timestamp + 61 hours);
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        // Still active, ratio restored
        (,,,,,,,,,, bool active) = murabaha.financings(borrower);
        assertTrue(active);
        assertGe(murabaha.healthRatio(borrower), 155e16);
    }

    // ─────────────────────────────────────────────────────────────────
    // 10. Liquidator never receives more collateral than debt being discharged
    // ─────────────────────────────────────────────────────────────────
    function testLiquidatorOnlyGetsFairShare() public {
        _openLoan();
        oracle.setPrice(1600e18); // collateral value 1320, debt 1100

        murabaha.flagUnhealthy(borrower);
        vm.warp(block.timestamp + 61 hours);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        uint256 seized = weth.balanceOf(liquidator) - liquidatorWethBefore;

        // Seized value should be <= debt discharged (auto-sized partial)
        // Auto-sized x ≈ 700 → seized value ≈ 700, in ETH at 1600: 0.4375 ETH
        // Should NOT be all 0.825 ETH (old behavior gave everything)
        assertLt(seized, 825_000_000_000_000_000, "Liquidator took everything");
        assertApproxEqRel(seized, 437_500_000_000_000_000, 1e16); // ~0.4375 ETH ±1%
    }
}
