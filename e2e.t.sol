// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MudarabahPool.sol";
import "../src/MurabahaFinancing.sol";
import "../src/MockOracle.sol";
import "./mocks/ERC20Mock.sol";

contract E2ETest is Test {
    MudarabahPool pool;
    MurabahaFinancing murabaha;
    MockOracle oracle;
    ERC20Mock usdc;
    ERC20Mock collateral;

    address lender = address(0x1111);
    address lenderB = address(0x2222);
    address borrower = address(0x3333);
    address borrowerB = address(0x4444);
    address liquidator = address(0x5555);
    address treasury = address(0x7BE5);
    address charity = address(0xC4A);

    uint256 constant COLLATERAL_PRICE = 2000e18;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC");
        collateral = new ERC20Mock("WETH", "WETH");
        oracle = new MockOracle();
        oracle.setPrice(COLLATERAL_PRICE);

        pool = new MudarabahPool(address(usdc), treasury);

        murabaha = new MurabahaFinancing(
            address(usdc),
            address(collateral),
            address(oracle),
            address(pool),
            charity
        );

        pool.setFinancingContract(address(murabaha));
    }

    // ─── Helpers ─────────────────────────────────────────────

    function _setupLender(address who, uint256 amount) internal {
        usdc.mint(who, amount);

        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _setupBorrower(address who, uint256 collateralAmount) internal {
        collateral.mint(who, collateralAmount);

        vm.startPrank(who);
        collateral.approve(address(murabaha), type(uint256).max);
        usdc.approve(address(murabaha), type(uint256).max);
        vm.stopPrank();
    }

    function _setupLiquidator(address who, uint256 amount) internal {
        usdc.mint(who, amount);

        vm.prank(who);
        usdc.approve(address(murabaha), type(uint256).max);
    }

    function _isActive(address who) internal view returns (bool active) {
        (, , , , , , , , , active) = murabaha.financings(who);
    }

    function _assertInvariants() internal view {
        assertEq(
            usdc.balanceOf(address(murabaha)),
            0,
            "USDC stuck in murabaha"
        );

        if (pool.totalShares() > 0) {
            uint256 totalAssets =
                usdc.balanceOf(address(pool)) + pool.totalReceivables();

            uint256 expected =
                (totalAssets * 1e18) / pool.totalShares();

            assertEq(pool.shareValue(), expected, "Share value drift");
        }
    }

    function _seedPool() internal returns (uint256 depositAmount) {
        depositAmount = 10_000e18;

        _setupLender(lender, depositAmount);

        vm.prank(lender);
        pool.deposit(depositAmount);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 1 — Golden Path
    // ═══════════════════════════════════════════════════════════

    function test_E2E_GoldenPath_FullLifecycle() public {
        _seedPool();

        assertEq(pool.shares(lender), 10_000e18);
        assertEq(pool.totalShares(), 10_000e18);
        assertEq(pool.shareValue(), 1e18);
        assertEq(usdc.balanceOf(address(pool)), 10_000e18);

        _assertInvariants();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        assertEq(usdc.balanceOf(borrower), 1_000e18);
        assertEq(pool.totalReceivables(), 1_000e18);
        assertEq(usdc.balanceOf(address(pool)), 9_000e18);

        assertApproxEqAbs(
            collateral.balanceOf(address(murabaha)),
            0.825e18,
            1
        );

        assertEq(murabaha.outstanding(borrower), 1_100e18);

        _assertInvariants();

        usdc.mint(borrower, 1_100e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);
            _assertInvariants();
        }

        assertFalse(_isActive(borrower));
        assertEq(pool.totalReceivables(), 0);
        assertEq(murabaha.outstanding(borrower), 0);

        assertApproxEqAbs(
            collateral.balanceOf(borrower),
            10e18,
            1
        );

        assertEq(usdc.balanceOf(treasury), 20e18);
        assertEq(pool.totalProfitDistributed(), 80e18);
        assertEq(usdc.balanceOf(address(pool)), 10_080e18);

        assertEq(
            pool.shareValue(),
            1_008_000_000_000_000_000
        );

        _assertInvariants();

        uint256 balBefore = usdc.balanceOf(lender);

        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);

        assertEq(out, 10_080e18);
        assertEq(usdc.balanceOf(lender) - balBefore, 10_080e18);
        assertEq(pool.totalShares(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);

        assertEq(
            usdc.balanceOf(lender) - 10_000e18,
            80e18
        );
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 2 — Late Payment
    // ═══════════════════════════════════════════════════════════

    function test_E2E_LatePayment_PenaltyGoesToCharity() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        vm.prank(borrower);
        murabaha.payInstallment();

        assertEq(usdc.balanceOf(charity), 0);

        vm.warp(block.timestamp + 40 days);

        uint256 charityBefore = usdc.balanceOf(charity);

        vm.prank(borrower);
        murabaha.payInstallment();

        uint256 penaltyExpected = (275e18 * 100) / 10_000;

        assertEq(
            usdc.balanceOf(charity) - charityBefore,
            penaltyExpected
        );

        assertEq(usdc.balanceOf(charity), penaltyExpected);

        _assertInvariants();
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 3 — Full Default and Liquidation
    // ═══════════════════════════════════════════════════════════

    function test_E2E_Default_Liquidation_PoolAbsorbsLoss() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        vm.warp(block.timestamp + 61 days);

        _setupLiquidator(liquidator, 1_000e18);

        uint256 poolBefore = usdc.balanceOf(address(pool));

        vm.prank(liquidator);
        murabaha.liquidate(borrower);

        assertEq(usdc.balanceOf(liquidator), 10e18);

        assertApproxEqAbs(
            collateral.balanceOf(liquidator),
            0.825e18,
            1
        );

        assertEq(
            usdc.balanceOf(address(pool)) - poolBefore,
            990e18
        );

        assertEq(pool.totalLossRecorded(), 10e18);
        assertEq(pool.totalReceivables(), 0);

        assertEq(
            pool.shareValue(),
            999_000_000_000_000_000
        );

        _assertInvariants();

        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);

        assertEq(out, 9_990e18);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 4 — Default After Partial Payment
    // ═══════════════════════════════════════════════════════════

    function test_E2E_DefaultAfterPartialPayment() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        // Pay two installments.
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);
        }

        assertEq(pool.totalReceivables(), 500e18);

        // Wait beyond the next due date and grace period.
        vm.warp(block.timestamp + 61 days);

        _setupLiquidator(liquidator, 1_000e18);

        vm.prank(liquidator);
        murabaha.liquidate(borrower);

        assertEq(pool.totalReceivables(), 0);
        assertEq(pool.totalLossRecorded(), 5e18);

        assertEq(
            usdc.balanceOf(address(pool)),
            10_035e18
        );

        assertEq(usdc.balanceOf(treasury), 10e18);

        assertEq(
            pool.shareValue(),
            1_003_500_000_000_000_000
        );

        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);

        assertEq(out, 10_035e18);

        assertEq(
            usdc.balanceOf(lender) - 10_000e18,
            35e18
        );
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 5 — Multiple Lenders and Borrowers
    // ═══════════════════════════════════════════════════════════

    function test_E2E_MultipleLenders_MultipleBorrowers() public {
        _setupLender(lender, 10_000e18);

        vm.prank(lender);
        pool.deposit(10_000e18);

        _setupLender(lenderB, 5_000e18);

        vm.prank(lenderB);
        pool.deposit(5_000e18);

        assertEq(pool.totalShares(), 15_000e18);
        assertEq(pool.shares(lender), 10_000e18);
        assertEq(pool.shares(lenderB), 5_000e18);

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        _setupBorrower(borrowerB, 10e18);

        vm.prank(borrowerB);
        murabaha.requestFinancing(500e18, 4);

        assertEq(pool.totalReceivables(), 1_500e18);

        usdc.mint(borrower, 1_100e18);
        usdc.mint(borrowerB, 550e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.prank(borrowerB);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);
        }

        assertEq(pool.totalReceivables(), 0);
        assertFalse(_isActive(borrower));
        assertFalse(_isActive(borrowerB));

        assertEq(usdc.balanceOf(treasury), 30e18);
        assertEq(usdc.balanceOf(address(pool)), 15_120e18);

        assertEq(
            pool.shareValue(),
            1_008_000_000_000_000_000
        );

        vm.prank(lender);
        uint256 outA = pool.withdraw(10_000e18);

        vm.prank(lenderB);
        uint256 outB = pool.withdraw(5_000e18);

        assertEq(outA, 10_080e18);
        assertEq(outB, 5_040e18);
        assertEq(outA + outB, 15_120e18);
        assertEq(pool.totalShares(), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 6 — Liquidity Constraint
    // ═══════════════════════════════════════════════════════════

    function test_E2E_LenderCannotWithdrawIlliquidCapital() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(5_000e18, 4);

        assertEq(usdc.balanceOf(address(pool)), 5_000e18);
        assertEq(pool.shareValue(), 1e18);

        vm.prank(lender);
        vm.expectRevert();
        pool.withdraw(10_000e18);

        assertEq(pool.shares(lender), 10_000e18);
        assertEq(usdc.balanceOf(address(pool)), 5_000e18);

        vm.prank(lender);
        uint256 partialWithdrawal = pool.withdraw(5_000e18);

        assertEq(partialWithdrawal, 5_000e18);
        assertEq(pool.shares(lender), 5_000e18);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 7 — No Interest Accrual
    // ═══════════════════════════════════════════════════════════

    function test_E2E_NoInterest_OutstandingConstant() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 12);

        uint256 owed0 = murabaha.outstanding(borrower);

        assertEq(owed0, 1_100e18);

        vm.warp(block.timestamp + 365 days);

        assertEq(
            murabaha.outstanding(borrower),
            1_100e18,
            "Debt grew (year 1)"
        );

        vm.warp(block.timestamp + 365 days);

        assertEq(
            murabaha.outstanding(borrower),
            1_100e18,
            "Debt grew (year 2)"
        );

        vm.warp(block.timestamp + 5 * 365 days);

        assertEq(
            murabaha.outstanding(borrower),
            1_100e18,
            "Debt grew (year 7)"
        );
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 8 — Second Financing
    // ═══════════════════════════════════════════════════════════

    function test_E2E_SecondFinancingAfterComplete() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);
        }

        assertFalse(_isActive(borrower));

        assertApproxEqAbs(
            collateral.balanceOf(borrower),
            10e18,
            1
        );

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        assertTrue(_isActive(borrower));
        assertEq(murabaha.outstanding(borrower), 1_100e18);
        assertEq(pool.totalReceivables(), 1_000e18);

        assertApproxEqAbs(
            collateral.balanceOf(address(murabaha)),
            0.825e18,
            1
        );

        usdc.mint(borrower, 1_100e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);
        }

        assertEq(usdc.balanceOf(treasury), 40e18);
        assertEq(pool.totalProfitDistributed(), 160e18);

        assertEq(
            pool.shareValue(),
            1_016_000_000_000_000_000
        );
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 9 — Single Installment
    // ═══════════════════════════════════════════════════════════

    function test_E2E_SingleInstallment() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 1);

        assertEq(murabaha.outstanding(borrower), 1_100e18);

        usdc.mint(borrower, 1_100e18);

        vm.prank(borrower);
        murabaha.payInstallment();

        assertFalse(_isActive(borrower));
        assertEq(pool.totalReceivables(), 0);

        assertApproxEqAbs(
            collateral.balanceOf(borrower),
            10e18,
            1
        );

        assertEq(usdc.balanceOf(treasury), 20e18);
        assertEq(pool.totalProfitDistributed(), 80e18);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 10 — Mixed Lifecycle Invariants
    // ═══════════════════════════════════════════════════════════

    function test_E2E_InvariantsAcrossMixedLifecycle() public {
        _seedPool();

        _assertInvariants();

        // Loan A: Normal repayment.
        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);

            _assertInvariants();
        }

        // Loan B: Default and liquidation.
        _setupBorrower(borrowerB, 10e18);

        vm.prank(borrowerB);
        murabaha.requestFinancing(500e18, 4);

        _assertInvariants();

        vm.warp(block.timestamp + 61 days);

        _setupLiquidator(liquidator, 500e18);

        vm.prank(liquidator);
        murabaha.liquidate(borrowerB);

        _assertInvariants();

        // Loan C: Normal repayment.
        _setupBorrower(borrower, 10e18);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();

            vm.warp(block.timestamp + 30 days);

            _assertInvariants();
        }

        assertEq(pool.totalReceivables(), 0);
        assertEq(usdc.balanceOf(address(murabaha)), 0);

        _assertInvariants();

        assertEq(usdc.balanceOf(treasury), 40e18);
        assertEq(pool.totalLossRecorded(), 5e18);

        assertEq(
            usdc.balanceOf(address(pool)),
            10_155e18
        );

        assertEq(
            pool.shareValue(),
            1_015_500_000_000_000_000
        );
    }
}
