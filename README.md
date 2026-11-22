## Weidai Sharia Finance

### Decentralized Islamic Finance, Built on Trust.

Weidai Sharia Finance is a decentralized financing protocol built with Solidity that combines Murabaha-based financing with Mudarabah profit-sharing liquidity pools.

The protocol enables borrowers to access collateral-backed financing through a predefined cost-plus-profit structure while allowing liquidity providers to participate in profits through a shared investment pool.

Built with Solidity, Foundry, and OpenZeppelin.

## 🌙 Overview

Weidai Sharia Finance aims to bring transparent, accessible, and programmable Islamic financing to decentralized finance.

The protocol consists of two primary components:

 1. Murabaha Financing

The Murabaha contract manages borrower financing through a predefined cost-plus-profit arrangement.

Features:

Fixed 10% markup on financing.
Collateral-backed financing.
Flexible installment schedules (1–12 installments).
Fixed repayment obligations.
Late-payment penalties directed to charity.
Default management and collateral liquidation.
Automatic collateral return upon successful repayment.

2. Mudarabah Liquidity Pool

The Mudarabah pool manages lender capital and profit distribution.

Features:

ERC-20 deposits and withdrawals.
Share-based liquidity accounting.
Dynamic share valuation.
Financing disbursement management.
Receivable tracking.
80/20 profit allocation between lenders and the Mudarib.
Loss recording and accounting.

🏗️ Architecture

The protocol consists of the following smart contracts:

Contract	Responsibility
MurabahaFinancing.sol	Manages financing requests, repayments, collateral, and liquidation.
MudarabahPool.sol	Manages lender deposits, shares, withdrawals, and profit distribution.
MockOracle.sol	Provides collateral pricing for testing.
IPriceOracle.sol	Price oracle interface.
IMudarabahPool.sol	Mudarabah pool interface.
Protocol Flow
text
              LENDER
                 |
                 | Deposit USDC
                 v
        +-------------------+
        |  Mudarabah Pool   |
        |                   |
        | Share Accounting  |
        | Liquidity Mgmt    |
        +-------------------+
                 |
                 | Financing Capital
                 v
        +-------------------+
        | Murabaha Financing|
        |                   |
        | Fixed 10% Markup  |
        | Collateral Mgmt   |
        | Installments      |
        +-------------------+
                 |
                 | Financing
                 v
              BORROWER
                 |
                 | Repay Installments
                 v
        +-------------------+
        | Profit Allocation |
        +-------------------+
              /       \
             /         \
            v           v
         LENDERS     TREASURY
           80%          20%

⚙️ Protocol Parameters
Parameter	Value
Financing markup	10%
Required collateral ratio	150%
Mudarib profit share	20%
Lender profit share	80%
Late-payment penalty	1%
Liquidation discount	10%
Installment period	30 days
Default grace period	30 days
Maximum installments	12

All percentages are defined through fixed contract constants.

💰 Financing Example

Suppose a borrower requests 1,000 USDC with four installments.

Item	Amount
Financing cost	1,000 USDC
Fixed markup (10%)	100 USDC
Total sale price	1,100 USDC
Number of installments	4
Each installment	275 USDC
Required collateral	0.825 WETH

The borrower repays 275 USDC every 30 days.

The 100 USDC markup is distributed as follows:

Recipient	Share	Amount
Lenders	80%	80 USDC
Mudarib/Treasury	20%	20 USDC

The financing obligation remains fixed and does not increase merely because time passes.

🔐 Collateral and Liquidation

Borrowers must deposit collateral before receiving financing.

The collateral requirement is calculated using the oracle price and the configured collateral ratio.

If a borrower defaults beyond the due date and grace period:

A liquidator can initiate liquidation.
The liquidator pays 90% of the outstanding sale obligation.
The liquidator receives the borrower's collateral.
The pool's remaining receivable is cleared.
Any shortfall against the remaining financing cost is recorded as a pool loss.
🧪 Testing

The project uses Foundry for smart contract testing.

The current E2E test suite contains 10 lifecycle scenarios.

#	Test Scenario
1	Complete financing lifecycle
2	Late-payment penalty to charity
3	Full default and liquidation
4	Default after partial repayment
5	Multiple lenders and borrowers
6	Lender withdrawal liquidity constraints
7	No interest accrual over time
8	Second financing after completion
9	Single-installment financing
10	Mixed lifecycle accounting invariants

Current test status: 10 E2E tests passing.

Run Tests

Install Foundry if it is not already installed.

Clone the repository:

```bash
git clone <YOUR_REPOSITORY_URL>
cd weidai-sharia-finance
```


Install dependencies:

```bash
forge install
```


Compile contracts:

```bash
forge build
```


Run all tests:

```bash
forge test -vv
```


Run E2E tests:

```bash
forge test --match-path "test/e2e.t.sol" -vv
```

🛠️ Technology Stack
Solidity: Smart contract development.
Foundry: Development, testing, and deployment framework.
OpenZeppelin: ERC-20 utilities, access control, and reentrancy protection.
ERC-20: Financing and collateral token standards.
Price Oracle: Collateral valuation.
⚠️ Important Considerations

This project is currently an MVP/prototype.

Before production deployment, additional work is required:

Independent smart contract security audit.
Oracle manipulation and stale-price protection.
Comprehensive fuzz and invariant testing.
Liquidity and insolvency risk assessment.
Production-grade liquidation mechanisms.
Token compatibility and decimal handling.
Review of profit-and-loss accounting.
Independent Sharia compliance review by qualified scholars.

Passing automated tests does not guarantee security or Sharia compliance.

The protocol has not been independently audited or certified as Sharia-compliant.

🗺️ Roadmap
Murabaha financing contract.
Mudarabah liquidity pool.
Collateral management.
Installment repayment mechanism.
Charity-directed late-payment penalties.
Default and liquidation mechanism.
Profit distribution.
End-to-end lifecycle testing.
Fuzz testing and invariant testing.
Independent security audit.
Sharia compliance review.
Testnet deployment.
Frontend integration.
Mainnet deployment.
📜 License

This project is licensed under the MIT License.

🤝 Contributions

Contributions, suggestions, and discussions are welcome.

If you discover a vulnerability, please report it responsibly rather than publicly disclosing exploit details.

Weidai Sharia Finance

Decentralized Islamic Finance, Built on Trust.