// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MudarabahPool.sol";
import "../src/MurabahaFinancing.sol";
import "../src/MockOracle.sol";
import "./mocks/ERC20Mock.sol";
import "../src/UnderwritingRegistry.sol";

/**
 * @title E2E
 * @notice Full lifecycle tests across MudarabahPool + MurabahaFinancing.
 *
 * Each test runs a self-contained user journey and asserts:
 *   - Exact token balances (pool, treasury, charity, lender, borrower, liquidator)
 *   - Exact share values at each phase
 *   - Invariants: murabaha holds 0 USDC between txs; receivables clear to 0
 *   - No interest: debt never grows with time
 */
contract E2ETest is Test {
    // ─── Contracts ───────────────────────────────────────────────────
    MudarabahPool pool;
    MurabahaFinancing murabaha;
    MockOracle oracle;
    ERC20Mock usdc;
    ERC20Mock collateral;
    UnderwritingRegistry registry;

    // ─── Actors ──────────────────────────────────────────────────────
    address lender = address(0x1111);
    address lenderB = address(0x2222);
    address borrower = address(0x3333);
    address borrowerB = address(0x4444);
    address liquidator = address(0x5555);
    address treasury = address(0x7BE5);
    address charity = address(0xC4A);
    address underwriter = address(0xBEEF);

    uint256 constant COLLATERAL_PRICE = 2000e18; // 1 ETH = 2000 USDC

    // ─── Setup ───────────────────────────────────────────────────────
    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC");
        collateral = new ERC20Mock("WETH", "WETH");
        oracle = new MockOracle();
        oracle.setPrice(COLLATERAL_PRICE);

        pool = new MudarabahPool(address(usdc), treasury);
        murabaha = new MurabahaFinancing(address(usdc), address(collateral), address(oracle), address(pool), charity);
        registry = new UnderwritingRegistry(address(this));

        registry.setFinancingContract(address(murabaha));
        murabaha.setUnderwritingRegistry(address(registry));

        registry.grantUnderwriter(underwriter);
        pool.setFinancingContract(address(murabaha));
    }

    // ─── Helpers ─────────────────────────────────────────────────────

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
        (,,,,,,,,,, active) = murabaha.financings(who);
    }

    /// @notice Invariants that must hold between any two user transactions.
    function _assertInvariants() internal view {
        // No USDC ever rests in the murabaha contract between operations
        assertEq(usdc.balanceOf(address(murabaha)), 0, "USDC stuck in murabaha");

        // Share value must equal (cash + receivables) / shares
        if (pool.totalShares() > 0) {
            uint256 totalAssets = usdc.balanceOf(address(pool)) + pool.totalReceivables();
            uint256 expected = (totalAssets * 1e18) / pool.totalShares();
            assertEq(pool.shareValue(), expected, "Share value drift");
        }
    }

    /// @notice Common setup: one lender with 10,000 USDC deposited.
    function _seedPool() internal returns (uint256 depositAmount) {
        depositAmount = 10_000e18;
        _setupLender(lender, depositAmount);
        vm.prank(lender);
        pool.deposit(depositAmount);
    }

    function _approveUnderwriting(address borrowerAddress) internal {
        bytes32 documentHash = keccak256(abi.encode(borrowerAddress, block.timestamp, block.number));

        vm.prank(borrowerAddress);
        registry.submitRecord(documentHash);

        vm.prank(underwriter);
        registry.reviewRecord(borrowerAddress, true);
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 1 — Golden path: deposit → finance → pay → withdraw
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_GoldenPath_FullLifecycle() public {
        // ── Phase 1: Lender deposits 10,000 USDC ─────────────────────
        _seedPool();
        assertEq(pool.shares(lender), 10_000e18);
        assertEq(pool.totalShares(), 10_000e18);
        assertEq(pool.shareValue(), 1e18);
        assertEq(usdc.balanceOf(address(pool)), 10_000e18);
        _assertInvariants();

        // ── Phase 2: Borrower requests 1,000 USDC over 4 installments ─
        //   markup = 10% → salePrice = 1,100
        //   each installment = 275 = 250 principal + 25 markup
        //   required collateral = 1100 * 1.5 / 2000 = 0.825 ETH
        _setupBorrower(borrower, 10e18);

        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        assertEq(usdc.balanceOf(borrower), 1_000e18, "Borrower not disbursed");
        assertEq(pool.totalReceivables(), 1_000e18);
        assertEq(usdc.balanceOf(address(pool)), 9_000e18);
        assertApproxEqAbs(collateral.balanceOf(address(murabaha)), 0.825e18, 1);
        assertEq(murabaha.outstanding(borrower), 1_100e18);
        _assertInvariants();

        // ── Phase 3: Borrower pays all 4 installments on time ────────
        usdc.mint(borrower, 1_100e18); // fund repayment
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
            _assertInvariants();
        }

        // ── Phase 4: Assert final state ──────────────────────────────
        assertFalse(_isActive(borrower));
        assertEq(pool.totalReceivables(), 0, "Receivables not cleared");
        assertEq(murabaha.outstanding(borrower), 0);
        assertApproxEqAbs(collateral.balanceOf(borrower), 10e18, 1, "Collateral not returned");

        // Treasury received 20% of 100 USDC markup = 20
        assertEq(usdc.balanceOf(treasury), 20e18);
        // Lender profit (retained) = 80% of 100 = 80
        assertEq(pool.totalProfitDistributed(), 80e18);
        // Pool cash = 10,000 - 1,000 + 1,000 (principal back) + 80 (profit) = 10,080
        assertEq(usdc.balanceOf(address(pool)), 10_080e18);
        // Share value = 10,080 / 10,000 = 1.008
        assertEq(pool.shareValue(), 1_008_000_000_000_000_000);
        _assertInvariants();

        // ── Phase 5: Lender withdraws with 8% profit ─────────────────
        uint256 balBefore = usdc.balanceOf(lender);
        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);

        assertEq(out, 10_080e18, "Lender payout wrong");
        assertEq(usdc.balanceOf(lender) - balBefore, 10_080e18);
        assertEq(pool.totalShares(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);

        // Net P&L
        assertEq(usdc.balanceOf(lender) - 10_000e18, 80e18, "Lender profit wrong");
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 2 — Late payment: penalty → charity, no lender yield
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_LatePayment_PenaltyGoesToCharity() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        // First installment on time
        vm.prank(borrower);
        murabaha.payInstallment();
        assertEq(usdc.balanceOf(charity), 0, "Charity received early");

        // Warp 40 days past due date (31 days would be normal next due)
        vm.warp(block.timestamp + 40 days);

        uint256 charityBefore = usdc.balanceOf(charity);
        vm.prank(borrower);
        murabaha.payInstallment();

        // 1% penalty on 275 USDC = 2.75 USDC to charity
        uint256 penaltyExpected = (275e18 * 100) / 10_000;
        assertEq(usdc.balanceOf(charity) - charityBefore, penaltyExpected);
        assertEq(usdc.balanceOf(charity), penaltyExpected);

        // Lender yield unaffected — profit accrues only through markup
        _assertInvariants();
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 3 — Full default: liquidator steps in, pool absorbs 10 USDC loss
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_Default_Liquidation_PoolAbsorbsLoss() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        // Borrower pays nothing, defaults
        vm.warp(block.timestamp + 61 days); // > due + grace

        _setupLiquidator(liquidator, 1_000e18);

        // Expected: liquidatorPayment = 1100 * 0.9 = 990
        // Loss to pool = costBasis - liquidatorPayment = 1000 - 990 = 10
        uint256 poolBefore = usdc.balanceOf(address(pool));
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        // Liquidator paid 990, received 0.825 ETH
        assertEq(usdc.balanceOf(liquidator), 1_000e18 - 990e18);
        assertApproxEqAbs(collateral.balanceOf(liquidator), 0.55e18, 1);

        // Pool received 990
        assertEq(usdc.balanceOf(address(pool)) - poolBefore, 990e18);

        // Loss recorded
        assertEq(pool.totalLossRecorded(), 10e18);

        // Receivable cleared
        assertEq(pool.totalReceivables(), 0);

        // Share value = (9,000 + 990) / 10,000 = 0.999
        assertEq(pool.shareValue(), 999_000_000_000_000_000);
        _assertInvariants();

        // Lender withdraws with 0.1% loss
        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);
        assertEq(out, 9_990e18);

        // 20% treasury share of markup was never earned (no markup was paid)
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 4 — Default after partial payment: still profitable
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_DefaultAfterPartialPayment() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);

        // Pay 2 installments (550 USDC = 500 cost + 50 markup)
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
        }

        // After 2 payments: receivable = 500, paidAmount = 550, salePrice = 1100
        assertEq(pool.totalReceivables(), 500e18);

        // Default — liquidator steps in
        vm.warp(block.timestamp + 31 days);
        _setupLiquidator(liquidator, 1_000e18);

        // remainingCostBasis = 500
        // outstandingSale = 550
        // liquidatorPayment = 550 * 0.9 = 495
        // loss = 500 - 495 = 5
        vm.prank(liquidator);
        murabaha.liquidate(borrower, 0);

        assertEq(pool.totalReceivables(), 0);
        assertEq(pool.totalLossRecorded(), 5e18);

        // Pool cash: 10,000 - 1,000 + 500 (principals) + 40 (retained markup after 2 payments)
        //         + 495 (liquidator) = 10,035
        // Note: total markup 50, 20% (10) to treasury, 80% (40) retained
        assertEq(usdc.balanceOf(address(pool)), 10_035e18);

        // Treasury received 10 USDC from the two markup payments
        assertEq(usdc.balanceOf(treasury), 10e18);

        // Share value = 10,035 / 10,000 = 1.0035
        assertEq(pool.shareValue(), 1_003_500_000_000_000_000);

        // Lender still profits despite default
        vm.prank(lender);
        uint256 out = pool.withdraw(10_000e18);
        assertEq(out, 10_035e18);
        assertEq(usdc.balanceOf(lender) - 10_000e18, 35e18, "Lender should net +35");
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 5 — Multiple lenders + multiple borrowers in same pool
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_MultipleLenders_MultipleBorrowers() public {
        // Lender A deposits 10,000
        _setupLender(lender, 10_000e18);
        vm.prank(lender);
        pool.deposit(10_000e18);

        // Lender B deposits 5,000 (share value still 1.0)
        _setupLender(lenderB, 5_000e18);
        vm.prank(lenderB);
        pool.deposit(5_000e18);

        assertEq(pool.totalShares(), 15_000e18);
        assertEq(pool.shares(lender), 10_000e18);
        assertEq(pool.shares(lenderB), 5_000e18);

        // Borrower A finances 1,000 (markup 100)
        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        // Borrower B finances 500 (markup 50)
        _setupBorrower(borrowerB, 10e18);
        _approveUnderwriting(borrowerB);

        vm.prank(borrowerB);
        murabaha.requestFinancing(500e18, 4);

        assertEq(pool.totalReceivables(), 1_500e18);

        // Both borrowers pay all installments
        usdc.mint(borrower, 1_100e18);
        usdc.mint(borrowerB, 550e18);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.prank(borrowerB);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
        }

        assertEq(pool.totalReceivables(), 0);
        assertFalse(_isActive(borrower));
        assertFalse(_isActive(borrowerB));

        // Total markup = 150 → 30 to treasury, 120 retained
        assertEq(usdc.balanceOf(treasury), 30e18);
        // Pool cash = 15,000 - 1,500 + 1,500 + 120 = 15,120
        assertEq(usdc.balanceOf(address(pool)), 15_120e18);
        assertEq(pool.shareValue(), 1_008_000_000_000_000_000);

        // Both lenders withdraw proportionally
        vm.prank(lender);
        uint256 outA = pool.withdraw(10_000e18);
        vm.prank(lenderB);
        uint256 outB = pool.withdraw(5_000e18);

        assertEq(outA, 10_080e18);
        assertEq(outB, 5_040e18);
        assertEq(outA + outB, 15_120e18, "Pool not fully drained");
        assertEq(pool.totalShares(), 0);
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 6 — Liquidity constraint: lender can't withdraw illiquid capital
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_LenderCannotWithdrawIlliquidCapital() public {
        _seedPool(); // 10,000 cash

        // Borrower takes 5,000
        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(5_000e18, 4);

        // Pool has 5,000 cash, 5,000 receivable
        assertEq(usdc.balanceOf(address(pool)), 5_000e18);
        assertEq(pool.shareValue(), 1e18);

        // Lender tries to withdraw all 10,000 shares (= 10,000 USDC claim)
        // But only 5,000 cash is available → transfer reverts
        vm.prank(lender);
        vm.expectRevert();
        pool.withdraw(10_000e18);

        // After revert, state is unchanged
        assertEq(pool.shares(lender), 10_000e18);
        assertEq(usdc.balanceOf(address(pool)), 5_000e18);

        // Lender CAN withdraw up to available liquidity
        vm.prank(lender);
        uint256 partialWithdrawal = pool.withdraw(5_000e18);
        assertEq(partialWithdrawal, 5_000e18);
        assertEq(pool.shares(lender), 5_000e18);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 7 — No interest accrual over long time
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_NoInterest_OutstandingConstant() public {
        _seedPool();

        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 12);

        uint256 owed0 = murabaha.outstanding(borrower);
        assertEq(owed0, 1_100e18);

        // Warp 1 year, no payment
        vm.warp(block.timestamp + 365 days);
        assertEq(murabaha.outstanding(borrower), 1_100e18, "Debt grew (year 1)");

        // Warp another year
        vm.warp(block.timestamp + 365 days);
        assertEq(murabaha.outstanding(borrower), 1_100e18, "Debt grew (year 2)");

        // Warp 5 more years
        vm.warp(block.timestamp + 5 * 365 days);
        assertEq(murabaha.outstanding(borrower), 1_100e18, "Debt grew (year 7)");
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 8 — Second financing after first completes
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_SecondFinancingAfterComplete() public {
        _seedPool();
        _setupBorrower(borrower, 10e18);

        // ── Round 1 ──────────────────────────────────────────────────
        _approveUnderwriting(borrower);
        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        usdc.mint(borrower, 1_100e18);
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
        }
        assertFalse(_isActive(borrower));
        assertApproxEqAbs(collateral.balanceOf(borrower), 10e18, 1);

        // ── Round 2: same terms ──────────────────────────────────────
        _approveUnderwriting(borrower);
        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);

        assertTrue(_isActive(borrower));
        assertEq(murabaha.outstanding(borrower), 1_100e18);
        assertEq(pool.totalReceivables(), 1_000e18);
        assertApproxEqAbs(collateral.balanceOf(address(murabaha)), 0.825e18, 1);

        usdc.mint(borrower, 1_100e18);
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
        }

        // Total over both rounds: 200 markup, 40 treasury, 160 retained
        assertEq(usdc.balanceOf(treasury), 40e18);
        assertEq(pool.totalProfitDistributed(), 160e18);
        assertEq(pool.shareValue(), 1_016_000_000_000_000_000); // 1.016
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 9 — Single-installment financing (edge case)
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_SingleInstallment() public {
        _seedPool();
        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 1);

        // One installment = 1,100 full amount
        assertEq(murabaha.outstanding(borrower), 1_100e18);

        usdc.mint(borrower, 1_100e18);
        vm.prank(borrower);
        murabaha.payInstallment();

        // Single payment clears the entire obligation
        assertFalse(_isActive(borrower));
        assertEq(pool.totalReceivables(), 0);
        assertApproxEqAbs(collateral.balanceOf(borrower), 10e18, 1);
        assertEq(usdc.balanceOf(treasury), 20e18);
        assertEq(pool.totalProfitDistributed(), 80e18);
    }

    // ══════════════════════════════════════════════════════════════════
    // TEST 10 — Invariants across a mixed lifecycle (profit → loss → profit)
    // ══════════════════════════════════════════════════════════════════
    function test_E2E_InvariantsAcrossMixedLifecycle() public {
        _seedPool();
        _assertInvariants();

        // Loan A: completes normally
        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);
        usdc.mint(borrower, 1_100e18);
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
            _assertInvariants();
        }

        // Loan B: defaults → liquidation
        _setupBorrower(borrowerB, 10e18);
        _approveUnderwriting(borrowerB);

        vm.prank(borrowerB);
        murabaha.requestFinancing(500e18, 4);
        _assertInvariants();

        vm.warp(block.timestamp + 61 days);
        _setupLiquidator(liquidator, 500e18);
        vm.prank(liquidator);
        murabaha.liquidate(borrowerB, 0);
        _assertInvariants();

        // Loan C: completes normally
        _setupBorrower(borrower, 10e18);
        _approveUnderwriting(borrower);

        vm.prank(borrower);
        murabaha.requestFinancing(1_000e18, 4);
        usdc.mint(borrower, 1_100e18);
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(borrower);
            murabaha.payInstallment();
            vm.warp(block.timestamp + 31 days);
            _assertInvariants();
        }

        // Final invariants
        assertEq(pool.totalReceivables(), 0);
        assertEq(usdc.balanceOf(address(murabaha)), 0);
        _assertInvariants();

        // Net accounting over all three loans:
        //   Loan A: +100 markup → +20 treasury, +80 pool
        //   Loan B: +50 markup unpaid → 0; 500 cost, liquidator pays 450 → -50 loss
        //   Loan C: +100 markup → +20 treasury, +80 pool
        //
        // Pool cash: 10,000 - 1,000 - 500 - 1,000 + 1,000 + 500 + 1,000 + 80 + 450 + 80
        //   = 10,610
        //   Wait, loan B's cost (500) wasn't returned (liquidator only paid 450)
        //   So: 10,000 - 1000 + 1000 + 80 (A) - 500 + 450 (B) - 1000 + 1000 + 80 (C)
        //   = 10,110
        // Hmm — loss calc for loan B with 10% discount on 500 sale = 550 outstanding
        //   liquidatorPayment = 550 * 0.9 = 495, cost basis = 500, loss = 5
        // Let me recompute: 10,000 - 1,000 + 1,000 + 80 (A) - 500 + 495 (B) - 1,000 + 1,000 + 80 (C) = 10,155
        // Actually the loss was 5, so pool cash reflects: started 10k, ended with 10k + A_profit(80) - B_loss(5) + C_profit(80) = 10,155

        // Treasury: 20 (A) + 20 (C) = 40; Loan B never paid markup → 0 from B
        assertEq(usdc.balanceOf(treasury), 40e18);
        // Loss recorded: 5 USDC from Loan B
        assertEq(pool.totalLossRecorded(), 5e18);
        // Pool cash
        assertEq(usdc.balanceOf(address(pool)), 10_155e18);
        // Share value = 10,155 / 10,000 = 1.0155
        assertEq(pool.shareValue(), 1_015_500_000_000_000_000);
    }
}
