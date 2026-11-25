// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MudarabahPool.sol";
import "../src/MurabahaFinancing.sol";
import "../src/MockOracle.sol";
import "./mocks/ERC20Mock.sol";
import "../src/UnderwritingRegistry.sol";

/**
 * @title Handler
 * @notice Bounded random actions against pool + murabaha, with ghost tracking
 *         for the share-value-monotonicity invariant.
 */
contract Handler is Test {
    MudarabahPool public pool;
    MurabahaFinancing public murabaha;
    MockOracle public oracle;
    ERC20Mock public usdc;
    ERC20Mock public weth;
    UnderwritingRegistry public registry;

    address[3] public lenders;
    address[3] public borrowers;
    address public liquidator;

    // Ghosts
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_lastShareValue;
    uint256 public ghost_lastLossRecorded;
    uint256 public ghost_shareValueDropCount;
    uint256 public ghost_shareValueDropWithLoss;

    constructor(
        MudarabahPool _pool,
        MurabahaFinancing _murabaha,
        MockOracle _oracle,
        ERC20Mock _usdc,
        ERC20Mock _weth,
        UnderwritingRegistry _registry
    ) {
        pool = _pool;
        murabaha = _murabaha;
        oracle = _oracle;
        usdc = _usdc;
        weth = _weth;
        registry = _registry;

        lenders[0] = address(0xA1);
        lenders[1] = address(0xA2);
        lenders[2] = address(0xA3);
        borrowers[0] = address(0xB1);
        borrowers[1] = address(0xB2);
        borrowers[2] = address(0xB3);
        liquidator = address(0xC1);

        ghost_lastShareValue = pool.shareValue();
    }

    function _checkpoint() internal {
        uint256 currentSV = pool.shareValue();
        // Only check monotonicity when shares > 0 (empty pool resets SV to 1e18)
        if (pool.totalShares() > 0 && currentSV < ghost_lastShareValue) {
            ghost_shareValueDropCount++;
            if (pool.totalLossRecorded() > ghost_lastLossRecorded) {
                ghost_shareValueDropWithLoss++;
            }
        }
        ghost_lastShareValue = currentSV;
        ghost_lastLossRecorded = pool.totalLossRecorded();
    }

    function _isActive(address who) internal view returns (bool active) {
        (,,,,,,,,,, active) = murabaha.financings(who);
    }

    // ─── Actions ─────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = lenders[actorSeed % 3];
        amount = bound(amount, 1e18, 5_000e18);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        ghost_totalDeposited += amount;
        _checkpoint();
    }

    function withdraw(uint256 actorSeed, uint256 sharesToBurn) external {
        address actor = lenders[actorSeed % 3];
        uint256 bal = pool.shares(actor);
        if (bal == 0) return;
        if (usdc.balanceOf(address(pool)) == 0) return;
        sharesToBurn = bound(sharesToBurn, 1, bal);

        vm.prank(actor);
        try pool.withdraw(sharesToBurn) returns (uint256 out) {
            ghost_totalWithdrawn += out;
        } catch {}
        _checkpoint();
    }

    function requestFinancing(uint256 actorSeed, uint256 amount, uint256 installments) external {
        address actor = borrowers[actorSeed % 3];

        if (_isActive(actor)) return;
        if (usdc.balanceOf(address(pool)) < 10e18) return;

        amount = bound(amount, 100e18, 2_000e18);
        installments = bound(installments, 1, 12);

        uint256 requiredCollateral = (amount * 110e16 * 150e16) / (oracle.getPrice() * 100e16);

        weth.mint(actor, requiredCollateral);

        // Submit the borrower's encrypted-record hash.
        bytes32 documentHash = keccak256(abi.encode(actor, block.timestamp, block.number));

        vm.prank(actor);
        registry.submitRecord(documentHash);

        // Handler is the authorized underwriter.
        registry.reviewRecord(actor, true);

        // Borrower approves collateral and requests financing.
        vm.startPrank(actor);
        weth.approve(address(murabaha), requiredCollateral);

        try murabaha.requestFinancing(amount, installments) {}
        catch {
            vm.stopPrank();
            return;
        }

        vm.stopPrank();
        _checkpoint();
    }

    function payInstallment(uint256 actorSeed) external {
        address actor = borrowers[actorSeed % 3];
        if (!_isActive(actor)) return;
        uint256 owed = murabaha.outstanding(actor);

        usdc.mint(actor, owed + 10e18); // buffer for penalty
        vm.startPrank(actor);
        usdc.approve(address(murabaha), type(uint256).max);
        try murabaha.payInstallment() {}
        catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();
        _checkpoint();
    }

    function topUp(uint256 actorSeed, uint256 amount) external {
        address actor = borrowers[actorSeed % 3];
        if (!_isActive(actor)) return;
        amount = bound(amount, 1e16, 1e18);

        weth.mint(actor, amount);
        vm.startPrank(actor);
        weth.approve(address(murabaha), amount);
        murabaha.topUp(amount);
        vm.stopPrank();
        _checkpoint();
    }

    function flag(uint256 actorSeed) external {
        address actor = borrowers[actorSeed % 3];
        if (!_isActive(actor)) return;
        if (murabaha.isFlagged(actor)) return;
        try murabaha.flagUnhealthy(actor) {} catch {}
        _checkpoint();
    }

    function liquidate(uint256 actorSeed) external {
        address actor = borrowers[actorSeed % 3];
        if (!_isActive(actor)) return;
        if (!murabaha.isLiquidatable(actor)) return;
        usdc.mint(liquidator, 5_000e18);
        vm.startPrank(liquidator);
        usdc.approve(address(murabaha), type(uint256).max);
        try murabaha.liquidate(actor, 0) {} catch {}
        vm.stopPrank();
        _checkpoint();
    }

    function movePrice(uint256 delta) external {
        uint256 current = oracle.getPrice();
        delta = bound(delta, 80e16, 120e16);
        uint256 newPrice = (current * delta) / 100e16;
        newPrice = bound(newPrice, 1000e18, 3000e18);
        oracle.setPrice(newPrice);
        _checkpoint();
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 7 days);
        vm.warp(block.timestamp + seconds_);
        _checkpoint();
    }
}

/**
 * @title InvariantsTest
 * @notice Boardy's two invariants, encoded and fuzzed.
 */
contract InvariantsTest is Test {
    MudarabahPool pool;
    MurabahaFinancing murabaha;
    MockOracle oracle;
    ERC20Mock usdc;
    ERC20Mock weth;
    Handler handler;
    UnderwritingRegistry registry;

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

        registry = new UnderwritingRegistry(address(this));
        registry.setFinancingContract(address(murabaha));
        murabaha.setUnderwritingRegistry(address(registry));

        handler = new Handler(pool, murabaha, oracle, usdc, weth, registry);

        // Allow the handler to review borrower records.
        registry.grantUnderwriter(address(handler));

        // Only handler can drive the system
        targetContract(address(handler));

        // Seed via handler so accounting identity ghost tracks it
        handler.deposit(0, 5_000e18);
        handler.deposit(1, 5_000e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // INVARIANT 1 — Accounting identity (Boardy's "assets cover shares")
    //
    //   cash + receivables + lossRecorded
    //      == totalDeposited - totalWithdrawn + profitDistributed
    //
    // Catches:
    //   - Markup credited to receivables at draw (riba bug)
    //   - Forgotten reduceReceivable / recordLoss
    //   - Tokens stuck in murabaha invisible to pool
    // ─────────────────────────────────────────────────────────────────
    function invariant_accountingIdentity() public view {
        uint256 assets = usdc.balanceOf(address(pool)) + pool.totalReceivables() + pool.totalLossRecorded();

        uint256 liabilities =
            handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn() + pool.totalProfitDistributed();

        // Tolerance = 1e6 wei (0.000001 USDC) for cumulative withdrawal rounding
        if (assets > liabilities) {
            assertLe(assets - liabilities, 1e6, "Assets exceed liabilities (phantom profit)");
        } else {
            assertLe(liabilities - assets, 1e6, "Liabilities exceed assets (phantom loss)");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // INVARIANT 2 — Share price never drops except through recorded loss
    //
    // Boardy: "share price never drops except through a recorded loss."
    // ─────────────────────────────────────────────────────────────────
    function invariant_shareValueMonotonic() public view {
        assertEq(
            handler.ghost_shareValueDropCount(),
            handler.ghost_shareValueDropWithLoss(),
            "Share value dropped without a recorded loss"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // INVARIANT 3 — Financing contract holds no USDC between txs
    // (guards Bug #5 from the build log)
    // ─────────────────────────────────────────────────────────────────
    function invariant_murabahaHoldsNoTokens() public view {
        assertEq(usdc.balanceOf(address(murabaha)), 0, "USDC stuck in murabaha");
    }

    // ─────────────────────────────────────────────────────────────────
    // INVARIANT 4 — Receivables always cover active loan cost bases
    // ─────────────────────────────────────────────────────────────────
    function invariant_receivablesCoverActiveLoans() public view {
        uint256 activeCostBasis = 0;
        address[3] memory borrowers = [address(0xB1), address(0xB2), address(0xB3)];
        for (uint256 i = 0; i < 3; i++) {
            (uint256 cost,, uint256 paidAmount, uint256 costRepaid,,,,,,, bool active) =
                murabaha.financings(borrowers[i]);
            if (active) {
                activeCostBasis += cost - costRepaid;
            }
        }
        assertEq(activeCostBasis, pool.totalReceivables(), "Receivables mismatch");
    }
}
