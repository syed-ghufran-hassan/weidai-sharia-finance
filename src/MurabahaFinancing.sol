// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IMudarabahPool.sol";

contract MurabahaFinancing is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable financingToken;
    IERC20 public immutable collateralToken;
    IPriceOracle public immutable oracle;
    IMudarabahPool public immutable pool;
    address public immutable charity;

    uint256 public constant BPS = 10_000;
    uint256 public constant MARKUP_BPS = 1_000;
    uint256 public constant COLLATERAL_RATIO = 150e16;
    uint256 public constant LATE_PENALTY_BPS = 100;
    uint256 public constant LIQUIDATION_DISCOUNT = 10e16;
    uint256 public constant INSTALLMENT_PERIOD = 30 days;
    uint256 public constant DEFAULT_GRACE = 30 days;
    uint256 public constant MAX_INSTALLMENTS = 12;

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
        bool active;
    }

    mapping(address => Financing) public financings;
    uint256 public totalFinanced;
    uint256 public totalProfitEarned;

    event FinancingCreated(address indexed borrower, uint256 costPrice, uint256 salePrice, uint256 collateral, uint256 installments);
    event InstallmentPaid(address indexed borrower, uint256 payment, uint256 remaining);
    event FinancingCompleted(address indexed borrower);
    event LatePenaltyCharged(address indexed borrower, uint256 amount);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 collateralSeized, uint256 liquidatorPaid, uint256 poolLoss);

    constructor(
        address _financingToken,
        address _collateralToken,
        address _oracle,
        address _pool,
        address _charity
    )
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

    // ─── Borrower functions ───────────────────────────────────────────

    function requestFinancing(uint256 amount, uint256 installments) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(installments > 0 && installments <= MAX_INSTALLMENTS, "Bad installments");
        require(!financings[msg.sender].active, "Existing financing");

        uint256 markup = (amount * MARKUP_BPS) / BPS;
        uint256 salePrice = amount + markup;
        uint256 collateralPrice = oracle.getPrice();
        uint256 requiredCollateral = (salePrice * COLLATERAL_RATIO) / collateralPrice;
        uint256 installmentAmount = salePrice / installments;

        // ─── Effects first (CEI) ──────────────────────────────────────
        financings[msg.sender] = Financing({
            costPrice: amount,
            salePrice: salePrice,
            paidAmount: 0,
            costRepaid: 0,
            collateralAmount: requiredCollateral,
            installmentAmount: installmentAmount,
            installmentsTotal: installments,
            installmentsPaid: 0,
            // forge-lint: disable-next-line(block-timestamp)
            nextDueDate: block.timestamp + INSTALLMENT_PERIOD,
            active: true
        });
        totalFinanced += amount;
        emit FinancingCreated(msg.sender, amount, salePrice, requiredCollateral, installments);

        // ─── Interactions last ────────────────────────────────────────
        collateralToken.safeTransferFrom(msg.sender, address(this), requiredCollateral);
        pool.addReceivable(amount);
        pool.disburse(msg.sender, amount);
    }

    function payInstallment() external nonReentrant {
        Financing storage f = financings[msg.sender];
        require(f.active, "No active financing");

        uint256 paymentAmount = f.installmentAmount;
        if (f.installmentsPaid == f.installmentsTotal - 1) {
            paymentAmount = f.salePrice - f.paidAmount;
        }

        bool isFinal = f.installmentsPaid == f.installmentsTotal - 1;
        // forge-lint: disable-next-line(block-timestamp)
        bool isLate = block.timestamp > f.nextDueDate;

        // ─── Effects first (CEI) ──────────────────────────────────────
        uint256 costPortion = isFinal
            ? f.costPrice - f.costRepaid
            : (paymentAmount * f.costPrice) / f.salePrice;
        uint256 markupPortion = paymentAmount - costPortion;

        f.paidAmount += paymentAmount;
        f.costRepaid += costPortion;
        f.installmentsPaid += 1;

        bool complete = f.paidAmount >= f.salePrice;
        if (complete) {
            f.active = false;
        } else {
            // forge-lint: disable-next-line(block-timestamp)
            f.nextDueDate = block.timestamp + INSTALLMENT_PERIOD;
        }

        // ─── Events ───────────────────────────────────────────────────
        emit InstallmentPaid(msg.sender, paymentAmount, f.salePrice - f.paidAmount);
        if (complete) emit FinancingCompleted(msg.sender);

        // ─── Interactions ─────────────────────────────────────────────
        if (isLate) {
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

    // ─── Liquidation ──────────────────────────────────────────────────

    function liquidate(address borrower) external nonReentrant {
        Financing storage f = financings[borrower];
        require(f.active, "No active financing");
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp > f.nextDueDate + DEFAULT_GRACE, "Not yet defaulted");

        uint256 outstandingSale = f.salePrice - f.paidAmount;
        uint256 liquidatorPayment = (outstandingSale * (1e18 - LIQUIDATION_DISCOUNT)) / 1e18;
        uint256 remainingCostBasis = f.costPrice - f.costRepaid;
        uint256 collateralSeized = f.collateralAmount;

        // ─── Effects first (CEI) ──────────────────────────────────────
        f.active = false;
        uint256 loss = liquidatorPayment < remainingCostBasis
            ? remainingCostBasis - liquidatorPayment
            : 0;

        // ─── Events ───────────────────────────────────────────────────
        emit Liquidated(borrower, msg.sender, collateralSeized, liquidatorPayment, loss);

        // ─── Interactions ─────────────────────────────────────────────
        financingToken.safeTransferFrom(msg.sender, address(pool), liquidatorPayment);
        collateralToken.safeTransfer(msg.sender, collateralSeized);
        pool.reduceReceivable(remainingCostBasis);
        if (loss > 0) pool.recordLoss(loss);
    }

    // ─── Views ────────────────────────────────────────────────────────

    function outstanding(address borrower) external view returns (uint256) {
        Financing memory f = financings[borrower];
        if (!f.active) return 0;
        return f.salePrice - f.paidAmount;
    }

    function isLate(address borrower) external view returns (bool) {
        Financing memory f = financings[borrower];
        // forge-lint: disable-next-line(block-timestamp)
        return f.active && block.timestamp > f.nextDueDate;
    }
}