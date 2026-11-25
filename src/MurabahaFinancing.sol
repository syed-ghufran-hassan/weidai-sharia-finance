// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IMudarabahPool.sol";
import "./interfaces/IUnderwritingRegistry.sol";

contract MurabahaFinancing is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable financingToken;
    IERC20 public immutable collateralToken;
    IPriceOracle public immutable oracle;
    IMudarabahPool public immutable pool;
    address public immutable charity;
    IUnderwritingRegistry public underwritingRegistry;

    uint256 public constant BPS = 10_000;
    uint256 public constant MARKUP_BPS = 1_000;
    uint256 public constant COLLATERAL_RATIO = 150e16;
    uint256 public constant LATE_PENALTY_BPS = 100;
    uint256 public constant INSTALLMENT_PERIOD = 30 days;
    uint256 public constant DEFAULT_GRACE = 30 days;
    uint256 public constant MAX_INSTALLMENTS = 12;

    // ─── Health / cure / liquidation ─────────────────────────────────
    uint256 public constant HEALTH_THRESHOLD = 150e16; // 150%
    uint256 public constant CRITICAL_THRESHOLD = 110e16; // 110%
    uint256 public constant TARGET_RATIO = 155e16; // post-partial-liq target
    uint256 public constant CURE_WINDOW = 60 hours; // between 48–72h
    uint256 public constant DISCOUNT_RAMP = 48 hours;
    uint256 public constant DISCOUNT_MIN = 1e16; // 1%
    uint256 public constant DISCOUNT_MAX = 10e16; // 10%

    struct Financing {
        uint256 costPrice;
        uint256 salePrice;
        uint256 paidAmount;
        uint256 costRepaid;
        uint256 collateralAmount;
        uint256 installmentAmount;
        uint256 installmentsTotal;
        uint256 installmentsPaid;
        uint256 nextDueDate;
        uint256 flaggedAt; // 0 = healthy / not flagged
        bool active;
    }

    mapping(address => Financing) public financings;
    uint256 public totalFinanced;
    uint256 public totalProfitEarned;

    event FinancingCreated(
        address indexed borrower, uint256 costPrice, uint256 salePrice, uint256 collateral, uint256 installments
    );
    event InstallmentPaid(address indexed borrower, uint256 payment, uint256 remaining);
    event UnderwritingRegistryUpdated(address indexed registry);
    event FinancingCompleted(address indexed borrower);
    event LatePenaltyCharged(address indexed borrower, uint256 amount);
    event PositionFlagged(address indexed borrower, uint256 ratio, uint256 cureDeadline);
    event PositionCured(address indexed borrower, uint256 newRatio);
    event ToppedUp(address indexed borrower, uint256 addedCollateral, uint256 newRatio);
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 debtReduced,
        uint256 collateralSeized,
        uint256 payment,
        uint256 poolLoss
    );
    event ProfitFromLiquidation(uint256 profit, uint256 lenderShare, uint256 mudaribShare);

    constructor(address _financingToken, address _collateralToken, address _oracle, address _pool, address _charity)
        Ownable(msg.sender)
    {
        require(_financingToken != address(0), "Zero financingToken");
        require(_collateralToken != address(0), "Zero collateralToken");
        require(_oracle != address(0), "Zero oracle");
        require(_pool != address(0), "Zero pool");
        require(_charity != address(0), "Zero charity");

        financingToken = IERC20(_financingToken);
        collateralToken = IERC20(_collateralToken);
        oracle = IPriceOracle(_oracle);
        pool = IMudarabahPool(_pool);
        charity = _charity;
    }

    function setUnderwritingRegistry(address registry) external onlyOwner {
        require(registry != address(0), "Invalid registry");
        require(registry.code.length > 0, "Not a contract");

        underwritingRegistry = IUnderwritingRegistry(registry);

        emit UnderwritingRegistryUpdated(registry);
    }

    // ══════════════════════════════════════════════════════════════════
    // Views
    // ══════════════════════════════════════════════════════════════════

    function _healthRatio(Financing storage f) internal view returns (uint256) {
        uint256 debt = f.salePrice - f.paidAmount;
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = (f.collateralAmount * oracle.getPrice()) / 1e18;
        return (collateralValue * 1e18) / debt;
    }

    function healthRatio(address borrower) external view returns (uint256) {
        return _healthRatio(financings[borrower]);
    }

    function isFlagged(address borrower) external view returns (bool) {
        return financings[borrower].flaggedAt > 0;
    }

    function cureDeadline(address borrower) external view returns (uint256) {
        uint256 t = financings[borrower].flaggedAt;
        return t == 0 ? 0 : t + CURE_WINDOW;
    }

    /// @notice Current liquidation discount for a flagged position.
    /// Ramp: 0h post-cure = MIN, 48h post-cure = MAX, then flat.
    function currentDiscount(address borrower) public view returns (uint256) {
        uint256 flaggedAt = financings[borrower].flaggedAt;
        if (flaggedAt == 0) return 0;
        uint256 rampStart = flaggedAt + CURE_WINDOW;
        if (block.timestamp <= rampStart) return DISCOUNT_MIN;
        uint256 elapsed = block.timestamp - rampStart;
        if (elapsed >= DISCOUNT_RAMP) return DISCOUNT_MAX;
        return DISCOUNT_MIN + ((DISCOUNT_MAX - DISCOUNT_MIN) * elapsed) / DISCOUNT_RAMP;
    }

    function isLiquidatable(address borrower) public view returns (bool) {
        Financing storage f = financings[borrower];
        if (!f.active) return false;

        uint256 D = f.salePrice - f.paidAmount;
        if (D == 0) return false;
        uint256 C = (f.collateralAmount * oracle.getPrice()) / 1e18;
        uint256 ratio = (C * 1e18) / D;

        if (block.timestamp > f.nextDueDate + DEFAULT_GRACE) return true;
        if (ratio < CRITICAL_THRESHOLD) return true;
        if (f.flaggedAt > 0 && block.timestamp >= f.flaggedAt + CURE_WINDOW && ratio < HEALTH_THRESHOLD) return true;
        return false;
    }

    function outstanding(address borrower) external view returns (uint256) {
        Financing memory f = financings[borrower];
        return f.active ? f.salePrice - f.paidAmount : 0;
    }

    function isLate(address borrower) external view returns (bool) {
        Financing memory f = financings[borrower];
        return f.active && block.timestamp > f.nextDueDate;
    }

    // ══════════════════════════════════════════════════════════════════
    // Flag & Cure
    // ══════════════════════════════════════════════════════════════════

    /// @notice Permissionless — flag an unhealthy position, starts the cure window.
    function flagUnhealthy(address borrower) external {
        Financing storage f = financings[borrower];
        require(f.active, "Not active");
        require(f.flaggedAt == 0, "Already flagged");

        uint256 ratio = _healthRatio(f);
        require(ratio < HEALTH_THRESHOLD, "Position healthy");

        f.flaggedAt = block.timestamp;
        emit PositionFlagged(borrower, ratio, block.timestamp + CURE_WINDOW);
    }

    /// @notice Borrower adds collateral. Callable any time — even before flag.
    function topUp(uint256 additionalCollateral) external nonReentrant {
        require(additionalCollateral > 0, "Amount must be > 0");
        Financing storage f = financings[msg.sender];
        require(f.active, "Not active");

        collateralToken.safeTransferFrom(msg.sender, address(this), additionalCollateral);
        f.collateralAmount += additionalCollateral;

        uint256 newRatio = _healthRatio(f);
        emit ToppedUp(msg.sender, additionalCollateral, newRatio);

        if (f.flaggedAt > 0 && newRatio >= HEALTH_THRESHOLD) {
            f.flaggedAt = 0;
            emit PositionCured(msg.sender, newRatio);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Request financing
    // ══════════════════════════════════════════════════════════════════

    function requestFinancing(uint256 amount, uint256 installments) external nonReentrant {
        require(address(underwritingRegistry) != address(0), "Registry not configured");
        require(underwritingRegistry.isApproved(msg.sender), "Underwriting not approved");

        require(amount > 0, "Amount must be > 0");
        require(installments > 0 && installments <= MAX_INSTALLMENTS, "Bad installments");
        require(!financings[msg.sender].active, "Existing financing");

        underwritingRegistry.consumeApproval(msg.sender);

        uint256 markup = (amount * MARKUP_BPS) / BPS;
        uint256 salePrice = amount + markup;
        uint256 collateralPrice = oracle.getPrice();
        uint256 requiredCollateral = (salePrice * COLLATERAL_RATIO) / collateralPrice;

        // Effects
        financings[msg.sender] = Financing({
            costPrice: amount,
            salePrice: salePrice,
            paidAmount: 0,
            costRepaid: 0,
            collateralAmount: requiredCollateral,
            installmentAmount: salePrice / installments,
            installmentsTotal: installments,
            installmentsPaid: 0,
            // forge-lint: disable-next-line(block-timestamp)
            nextDueDate: block.timestamp + INSTALLMENT_PERIOD,
            flaggedAt: 0,
            active: true
        });
        totalFinanced += amount;
        emit FinancingCreated(msg.sender, amount, salePrice, requiredCollateral, installments);

        // Interactions
        collateralToken.safeTransferFrom(msg.sender, address(this), requiredCollateral);
        pool.addReceivable(amount);
        pool.disburse(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    // Installments
    // ══════════════════════════════════════════════════════════════════

    function payInstallment() external nonReentrant {
        Financing storage f = financings[msg.sender];
        require(f.active, "No active financing");

        uint256 paymentAmount = f.installmentAmount;
        if (f.installmentsPaid == f.installmentsTotal - 1) {
            paymentAmount = f.salePrice - f.paidAmount;
        }

        bool isFinal = f.installmentsPaid == f.installmentsTotal - 1;
        // forge-lint: disable-next-line(block-timestamp)
        bool _late = block.timestamp > f.nextDueDate;

        // Effects
        uint256 costPortion = isFinal ? f.costPrice - f.costRepaid : (paymentAmount * f.costPrice) / f.salePrice;
        uint256 markupPortion = paymentAmount - costPortion;

        f.paidAmount += paymentAmount;
        f.costRepaid += costPortion;
        f.installmentsPaid += 1;

        bool complete = f.paidAmount >= f.salePrice;
        if (complete) {
            f.active = false;
            f.flaggedAt = 0;
        } else {
            // forge-lint: disable-next-line(block-timestamp)
            f.nextDueDate = block.timestamp + INSTALLMENT_PERIOD;
            if (f.flaggedAt > 0) {
                uint256 newRatio = _healthRatio(f);
                if (newRatio >= HEALTH_THRESHOLD) {
                    f.flaggedAt = 0;
                    emit PositionCured(msg.sender, newRatio);
                }
            }
        }

        // Events
        emit InstallmentPaid(msg.sender, paymentAmount, f.salePrice - f.paidAmount);
        if (complete) emit FinancingCompleted(msg.sender);

        // Interactions
        if (_late) {
            uint256 penalty = (paymentAmount * LATE_PENALTY_BPS) / BPS;
            if (penalty > 0) {
                emit LatePenaltyCharged(msg.sender, penalty);
                financingToken.safeTransferFrom(msg.sender, charity, penalty);
            }
        }

        financingToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        if (costPortion > 0) {
            financingToken.safeTransfer(address(pool), costPortion);
            pool.reduceReceivable(costPortion);
        }
        if (markupPortion > 0) {
            financingToken.safeTransfer(address(pool), markupPortion);
            pool.distributeProfit(markupPortion);
            totalProfitEarned += markupPortion;
        }
        if (complete) {
            collateralToken.safeTransfer(msg.sender, f.collateralAmount);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Liquidation
    // ══════════════════════════════════════════════════════════════════

    /// @notice Liquidate a flagged/underwater/defaulted position.
    /// @param borrower   The borrower.
    /// @param debtToRepay If 0 → auto-size (restore TARGET_RATIO, or full if forced).
    ///                    If >0 → must be >= min-restore, or exactly full.
    function liquidate(address borrower, uint256 debtToRepay) external nonReentrant {
        Financing storage f = financings[borrower];
        require(f.active, "Not active");

        uint256 D = f.salePrice - f.paidAmount;
        require(D > 0, "Nothing owed");
        uint256 price = oracle.getPrice();
        uint256 C = (f.collateralAmount * price) / 1e18;
        uint256 ratio = (C * 1e18) / D;

        // forge-lint: disable-next-line(block-timestamp)
        bool isDefaulted = block.timestamp > f.nextDueDate + DEFAULT_GRACE;
        bool isCritical = ratio < CRITICAL_THRESHOLD;
        bool isFlaggedPastCure = f.flaggedAt > 0 && 
            // forge-lint: disable-next-line(block-timestamp)
            block.timestamp >= f.flaggedAt + CURE_WINDOW;

        require(isDefaulted || isCritical || isFlaggedPastCure, "Not liquidatable");
        require(isDefaulted || ratio < HEALTH_THRESHOLD, "Position healthy");

        bool mustFull = isDefaulted || isCritical;
        uint256 minRestore = mustFull ? D : _computeRestoreAmount(D, C, TARGET_RATIO);

        uint256 x; // debt to reduce
        if (debtToRepay == 0) {
            x = mustFull ? D : (minRestore == 0 ? D : minRestore);
        } else {
            x = debtToRepay;
            require(x > 0 && x <= D, "Invalid amount");
            if (mustFull) {
                require(x == D, "Full liquidation required");
            } else if (x < D) {
                require(x >= minRestore, "Partial must restore TARGET_RATIO");
            }
        }

        // Discount
        uint256 discount;
        if (isDefaulted || isCritical) {
            discount = DISCOUNT_MAX;
        } else {
            discount = currentDiscount(borrower);
        }

        // Collateral to seize — only worth the debt being discharged, capped by availability
        uint256 collateralValueSeized = x <= C ? x : C;
        uint256 collateralSeized = (collateralValueSeized * 1e18) / price;
        if (collateralSeized > f.collateralAmount) {
            collateralSeized = f.collateralAmount;
            collateralValueSeized = (collateralSeized * price) / 1e18;
        }

        uint256 payment = (collateralValueSeized * (1e18 - discount)) / 1e18;

        // Cost-basis reduction (proportional)
        uint256 remainingCostBasis = f.costPrice - f.costRepaid;
        uint256 costReduced = (x * remainingCostBasis) / D;

        // ─── Effects ─────────────────────────────────────────────────
        bool fullLiquidation = (x == D);
        f.paidAmount += x;
        f.costRepaid += costReduced;
        f.collateralAmount -= collateralSeized;

        if (fullLiquidation) {
            f.active = false;
            f.flaggedAt = 0;
        } else {
            uint256 newRatio = _healthRatio(f);
            if (newRatio >= HEALTH_THRESHOLD) {
                f.flaggedAt = 0;
                emit PositionCured(borrower, newRatio);
            }
        }

        uint256 profit = payment > costReduced ? payment - costReduced : 0;
        uint256 loss = payment < costReduced ? costReduced - payment : 0;

        emit Liquidated(borrower, msg.sender, x, collateralSeized, payment, loss);

        // ─── Interactions ────────────────────────────────────────────
        if (payment > 0) {
            financingToken.safeTransferFrom(msg.sender, address(pool), payment);
        }
        if (collateralSeized > 0) {
            collateralToken.safeTransfer(msg.sender, collateralSeized);
        }
        if (costReduced > 0) {
            pool.reduceReceivable(costReduced);
        }
        if (loss > 0) {
            pool.recordLoss(loss);
        }
        if (profit > 0) {
            pool.distributeProfit(profit);
            totalProfitEarned += profit;
            emit ProfitFromLiquidation(profit, (profit * 80) / 100, (profit * 20) / 100);
        }
    }

    /// @dev Solve for debt reduction x such that (C - x) / (D - x) = targetRatio.
    ///      x = (targetRatio * D - C) / (targetRatio - 1)
    function _computeRestoreAmount(uint256 D, uint256 C, uint256 targetRatio) internal pure returns (uint256) {
        uint256 targetDebtCovered = (targetRatio * D) / 1e18;
        if (targetDebtCovered <= C) return 0;
        return ((targetDebtCovered - C) * 1e18) / (targetRatio - 1e18);
    }
}
