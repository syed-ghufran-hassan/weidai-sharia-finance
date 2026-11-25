// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MudarabahPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable financingToken;
    address public immutable treasury;
    address public financingContract;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 public totalReceivables;
    uint256 public totalProfitDistributed;
    uint256 public totalLossRecorded;
    uint256 public totalDeposited; // cumulative tokens in
    uint256 public totalWithdrawn; // cumulative tokens out

    uint256 public constant SHARE_PRECISION = 1e18;
    uint256 public constant MUDARIB_SHARE = 20e16;

    event Deposited(address indexed lender, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed lender, uint256 sharesBurned, uint256 amount);
    event ProfitDistributed(uint256 profit, uint256 lenderShare, uint256 mudaribShare);
    event LossRecorded(uint256 loss);
    event Disbursed(address indexed to, uint256 amount);
    event ReceivableIncreased(uint256 amount, uint256 newTotal);
    event ReceivableDecreased(uint256 amount, uint256 newTotal);
    event FinancingContractUpdated(address indexed previous, address indexed current);
    event ResidualAssetsSwept(uint256 amount, address indexed treasury);

    modifier onlyFinancing() {
        require(msg.sender == financingContract, "Only financing contract");
        _;
    }

    constructor(address _financingToken, address _treasury) Ownable(msg.sender) {
        require(_financingToken != address(0), "Zero financingToken");
        require(_treasury != address(0), "Zero treasury");
        financingToken = IERC20(_financingToken);
        treasury = _treasury;
    }

    function setFinancingContract(address _financing) external onlyOwner {
        require(_financing != address(0), "Zero financing");
        emit FinancingContractUpdated(financingContract, _financing);
        financingContract = _financing;
    }

    function shareValue() public view returns (uint256) {
        if (totalShares == 0) return SHARE_PRECISION;
        uint256 totalAssets = financingToken.balanceOf(address(this)) + totalReceivables;
        return (totalAssets * SHARE_PRECISION) / totalShares;
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256 sharesMinted) {
        require(amount > 0, "Amount must be > 0");
        if (totalShares == 0) {
            require(totalReceivables == 0 && financingToken.balanceOf(address(this)) == 0, "Residual assets");
        }
        sharesMinted = (amount * SHARE_PRECISION) / shareValue();

        require(sharesMinted > 0, "Zero shares minted");

        shares[msg.sender] += sharesMinted;
        totalShares += sharesMinted;
        totalDeposited += amount; // ← new
        emit Deposited(msg.sender, amount, sharesMinted);

        financingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 amountOut) {
        require(sharesToBurn > 0, "Shares must be > 0");
        require(shares[msg.sender] >= sharesToBurn, "Insufficient shares");
        amountOut = (sharesToBurn * shareValue()) / SHARE_PRECISION;

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalWithdrawn += amountOut; // ← new
        emit Withdrawn(msg.sender, sharesToBurn, amountOut);

        financingToken.safeTransfer(msg.sender, amountOut);
    }

    function sweepResidualAssets() external onlyOwner nonReentrant {
        require(totalShares == 0, "Shares still exist");
        require(totalReceivables == 0, "Receivables still exist");

        uint256 amount = financingToken.balanceOf(address(this));
        require(amount > 0, "No residual assets");

        emit ResidualAssetsSwept(amount, treasury);
        financingToken.safeTransfer(treasury, amount);
    }

    // ─── Financing hooks ──────────────────────────────────────────────

    function disburse(address to, uint256 amount) external onlyFinancing nonReentrant {
        require(to != address(0), "Zero recipient");
        require(financingToken.balanceOf(address(this)) >= amount, "Insufficient liquidity");
        emit Disbursed(to, amount);
        financingToken.safeTransfer(to, amount);
    }

    function addReceivable(uint256 amount) external onlyFinancing {
        totalReceivables += amount;
        emit ReceivableIncreased(amount, totalReceivables);
    }

    function reduceReceivable(uint256 amount) external onlyFinancing {
        require(totalReceivables >= amount, "Receivable underflow");
        totalReceivables -= amount;
        emit ReceivableDecreased(amount, totalReceivables);
    }

    function distributeProfit(uint256 profitAmount) external onlyFinancing nonReentrant {
        require(profitAmount > 0, "Profit must be > 0");
        uint256 mudaribShare = (profitAmount * MUDARIB_SHARE) / SHARE_PRECISION;
        uint256 lenderShare = profitAmount - mudaribShare;
        totalProfitDistributed += lenderShare;
        emit ProfitDistributed(profitAmount, lenderShare, mudaribShare);
        if (mudaribShare > 0) {
            financingToken.safeTransfer(treasury, mudaribShare);
        }
    }

    function recordLoss(uint256 lossAmount) external onlyFinancing {
        totalLossRecorded += lossAmount;
        emit LossRecorded(lossAmount);
    }
}
