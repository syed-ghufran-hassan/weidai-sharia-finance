 
import { useEffect, useState } from "react";
import { BrowserProvider } from "ethers";
import { runQoreSealBrowserTest } from "./lib/qoresealBrowserTest";

import {
  getBorrowerDashboard,
  submitUnderwritingRecord,
  getUnderwriterAccess,
  getUnderwriterRecord,
  reviewUnderwritingRecord,
} from "./hooks/useContracts";

import "./App.css";

const QORE_CHAIN_ID = 9800;

const QORE_NETWORK = {
  chainId: "0x2648",
  chainName: "QORE Diana Testnet",
  nativeCurrency: {
    name: "QORE",
    symbol: "QOR",
    decimals: 18,
  },
  rpcUrls: ["https://evm-testnet.qore.host"],
};

type DashboardData = Awaited<
  ReturnType<typeof getBorrowerDashboard>
>;

function App() {
  const [account, setAccount] = useState("");
  const [connecting, setConnecting] = useState(false);

  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [loadingData, setLoadingData] = useState(false);

  const [error, setError] = useState("");

  const [encryptedEnvelope, setEncryptedEnvelope] = useState("");
  const [submittingUnderwriting, setSubmittingUnderwriting] =
    useState(false);
  const [underwritingMessage, setUnderwritingMessage] = useState("");
  const [testingQoreSeal, setTestingQoreSeal] = useState(false);
  const [qoreSealResult, setQoreSealResult] = useState("");

  // =========================================
// UNDERWRITER DASHBOARD STATE
// =========================================

const [isUnderwriter, setIsUnderwriter] = useState(false);
const [isAdmin, setIsAdmin] = useState(false);

const [underwriterBorrower, setUnderwriterBorrower] = useState("");

const [underwriterRecord, setUnderwriterRecord] =
  useState<Awaited<ReturnType<typeof getUnderwriterRecord>> | null>(null);

const [loadingUnderwriterRecord, setLoadingUnderwriterRecord] =
  useState(false);

const [reviewingApplication, setReviewingApplication] =
  useState(false);

const [underwriterMessage, setUnderwriterMessage] = useState("");
  // =========================================
  // INITIAL WALLET SYNCHRONIZATION
  // =========================================

  useEffect(() => {
    async function syncWallet() {
      if (!window.ethereum) return;

      try {
        const provider = new BrowserProvider(window.ethereum);
        const network = await provider.getNetwork();

        if (Number(network.chainId) !== QORE_CHAIN_ID) {
          setAccount("");
          return;
        }

        const accounts = await provider.send("eth_accounts", []);
        const address = accounts[0] || "";

        setAccount(address);

        console.log("Initially detected MetaMask account:", address);
      } catch (err) {
        console.error("Wallet synchronization failed:", err);
      }
    }

    syncWallet();
  }, []);

  // =========================================
  // WALLET CONNECTION
  // =========================================

  async function connectWallet() {
    if (!window.ethereum) {
      setError("Please install MetaMask to access WEIDAI.");
      return;
    }

    try {
      setConnecting(true);
      setError("");

      let provider = new BrowserProvider(window.ethereum);
      let network = await provider.getNetwork();

      if (Number(network.chainId) !== QORE_CHAIN_ID) {
        try {
          await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: QORE_NETWORK.chainId }],
          });
        } catch (switchError: any) {
          if (switchError.code === 4902) {
            await window.ethereum.request({
              method: "wallet_addEthereumChain",
              params: [QORE_NETWORK],
            });
          } else {
            throw switchError;
          }
        }

        provider = new BrowserProvider(window.ethereum);
        network = await provider.getNetwork();

        if (Number(network.chainId) !== QORE_CHAIN_ID) {
          throw new Error(
            "Please switch MetaMask to QORE Diana Testnet."
          );
        }
      }

      // Request the currently selected MetaMask account.
      const accounts = await provider.send(
        "eth_requestAccounts",
        []
      );

      const address = accounts[0];

      if (!address) {
        throw new Error("No MetaMask account selected.");
      }

      setAccount(address);

      console.log("Connected MetaMask account:", address);
    } catch (err: any) {
      console.error("Wallet connection error:", err);

      setError(
        err.shortMessage ||
          err.message ||
          "Wallet connection failed."
      );
    } finally {
      setConnecting(false);
    }
  }

  // =========================================
  // LOAD BORROWER DASHBOARD
  // =========================================

  async function loadDashboard(address: string) {
    try {
      setLoadingData(true);
      setError("");

      const data = await getBorrowerDashboard(address);

      setDashboard(data);
    } catch (err: any) {
      console.error("Dashboard loading error:", err);

      setError(
        err.shortMessage ||
          err.message ||
          "Unable to load contract data."
      );
    } finally {
      setLoadingData(false);
    }
  }

  // =========================================
  // UNDERWRITING SUBMISSION
  // =========================================

  async function handleUnderwritingSubmit() {
    try {
      setSubmittingUnderwriting(true);
      setError("");
      setUnderwritingMessage("");

      if (!account) {
        throw new Error("Connect your wallet first.");
      }

      if (!encryptedEnvelope.trim()) {
        throw new Error(
          "Please provide an encrypted evidence envelope."
        );
      }

      const result = await submitUnderwritingRecord(
        encryptedEnvelope
      );

      setUnderwritingMessage(
        `Application submitted successfully. Transaction: ${result.transactionHash}`
      );

      setEncryptedEnvelope("");

      await loadDashboard(account);
    } catch (err: any) {
      console.error("Underwriting submission error:", err);

      setError(
        err.shortMessage ||
          err.reason ||
          err.message ||
          "Underwriting submission failed."
      );
    } finally {
      setSubmittingUnderwriting(false);
    }
  }

  // =========================================
  // QORESEAL BROWSER TEST
  // =========================================

  async function handleQoreSealTest() {
    try {
      setTestingQoreSeal(true);
      setQoreSealResult("");

      const result = await runQoreSealBrowserTest();

      setQoreSealResult(
        [
          "QoreSeal browser test successful!",
          "",
          `Encryption: ${result.encryption}`,
          `Borrower decryption: ${result.borrowerDecryption}`,
          `Underwriter decryption: ${result.underwriterDecryption}`,
          `Envelope format: ${result.envelopeFormat}`,
          `Envelope length: ${result.envelopeLength}`,
          `Ciphertext hash: ${result.ciphertextHash}`,
        ].join("\n")
      );
    } catch (err: any) {
      console.error("QoreSeal browser test failed:", err);

      setQoreSealResult(
        `QoreSeal browser test failed: ${
          err.message || "Unknown error"
        }`
      );
    } finally {
      setTestingQoreSeal(false);
    }
  }

  // =========================================
// CHECK UNDERWRITER PERMISSIONS
// =========================================

async function checkUnderwriterPermissions(address: string) {
  try {
    const permissions = await getUnderwriterAccess(address);

    setIsUnderwriter(permissions.authorized);
    setIsAdmin(permissions.isAdmin);

    console.log("Underwriter permissions:", permissions);
  } catch (err) {
    console.error("Permission check failed:", err);

    setIsUnderwriter(false);
    setIsAdmin(false);
  }
}

// =========================================
// LOAD BORROWER RECORD
// =========================================

async function loadUnderwriterRecord() {
  try {
    setLoadingUnderwriterRecord(true);
    setError("");
    setUnderwriterMessage("");

    if (!underwriterBorrower.trim()) {
      throw new Error("Enter a borrower wallet address.");
    }

    if (!isUnderwriter) {
      throw new Error("Your wallet is not authorized as an underwriter.");
    }

    const record = await getUnderwriterRecord(
      underwriterBorrower.trim()
    );

    setUnderwriterRecord(record);
  } catch (err: any) {
    console.error("Record loading error:", err);

    setUnderwriterRecord(null);

    setError(
      err.shortMessage ||
        err.reason ||
        err.message ||
        "Unable to load underwriting record."
    );
  } finally {
    setLoadingUnderwriterRecord(false);
  }
}

// =========================================
// APPROVE OR REJECT APPLICATION
// =========================================

async function handleUnderwritingReview(approved: boolean) {
  try {
    setReviewingApplication(true);
    setError("");
    setUnderwriterMessage("");

    if (!isUnderwriter) {
      throw new Error("Your wallet is not authorized to review applications.");
    }

    if (!underwriterRecord) {
      throw new Error("Load an application first.");
    }

    if (underwriterRecord.status !== "PENDING") {
      throw new Error("Only pending applications can be reviewed.");
    }

    const result = await reviewUnderwritingRecord(
      underwriterRecord.borrower,
      approved
    );

    setUnderwriterMessage(
      `Application ${result.status}. Transaction: ${result.transactionHash}`
    );

    const updatedRecord = await getUnderwriterRecord(
      underwriterRecord.borrower
    );

    setUnderwriterRecord(updatedRecord);

    if (
      account.toLowerCase() ===
      underwriterRecord.borrower.toLowerCase()
    ) {
      await loadDashboard(account);
    }
  } catch (err: any) {
    console.error("Review transaction error:", err);

    setError(
      err.shortMessage ||
        err.reason ||
        err.message ||
        "Unable to review application."
    );
  } finally {
    setReviewingApplication(false);
  }
}

  // =========================================
  // LOAD DASHBOARD WHEN ACCOUNT CHANGES
  // =========================================

  useEffect(() => {
  if (account) {
    loadDashboard(account);

    setUnderwriterBorrower(account);

    checkUnderwriterPermissions(account);
  } else {
    setDashboard(null);

    setIsUnderwriter(false);
    setIsAdmin(false);

    setUnderwriterRecord(null);
    setUnderwriterBorrower("");
  }
}, [account]);
  // =========================================
  // WALLET EVENTS
  // =========================================

  useEffect(() => {
    if (!window.ethereum) return;

    const handleAccountsChanged = (accounts: string[]) => {
      console.log("MetaMask account changed:", accounts[0]);

      setDashboard(null);
      setAccount(accounts[0] || "");
      setError("");
      setUnderwritingMessage("");
    };

    const handleChainChanged = () => {
      console.log("MetaMask network changed.");

      setDashboard(null);
      setError(
        "Network changed. Please reconnect to QORE Testnet."
      );
      setAccount("");
    };

    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);

    return () => {
      window.ethereum?.removeListener(
        "accountsChanged",
        handleAccountsChanged
      );

      window.ethereum?.removeListener(
        "chainChanged",
        handleChainChanged
      );
    };
  }, []);

  // =========================================
  // HELPERS
  // =========================================

  function formatDate(timestamp: number) {
    if (!timestamp || Number(timestamp) <= 0) {
      return "Not scheduled";
    }

    return new Date(
      Number(timestamp) * 1000
    ).toLocaleDateString(undefined, {
      day: "numeric",
      month: "short",
      year: "numeric",
    });
  }

  function shortenAddress(address: string) {
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
  }

  function statusClass(status: string) {
    switch (status) {
      case "APPROVED":
      case "ACTIVE":
      case "NONE":
        return "badge badge-success";

      case "PENDING":
        return "badge badge-warning";

      case "REJECTED":
      case "LATE":
        return "badge badge-danger";

      default:
        return "badge badge-neutral";
    }
  }

  const installmentTotal = dashboard
    ? Number(dashboard.financing.installmentsTotal)
    : 0;

  const installmentsPaid = dashboard
    ? Number(dashboard.financing.installmentsPaid)
    : 0;

  const repaymentProgress =
    installmentTotal > 0
      ? Math.min(
          100,
          Math.max(0, (installmentsPaid / installmentTotal) * 100)
        )
      : 0;

  const canSubmitUnderwriting =
    dashboard &&
    ["NONE", "REJECTED", "CONSUMED"].includes(
      dashboard.underwriting.status
    );

  // =========================================
  // UI
  // =========================================

  return (
    <div className="app">

      {/* NAVIGATION */}

      <nav className="navbar">
        <div className="logo">
          WEIDAI<span>.</span>
        </div>

        <div className="nav-right">
          <span className="network">
            ● QORE DIANA TESTNET
          </span>

          <button
            className="connect-btn"
            onClick={connectWallet}
            disabled={connecting}
          >
            {connecting
              ? "Connecting..."
              : account
                ? shortenAddress(account)
                : "Connect Wallet"}
          </button>
        </div>
      </nav>

      <main className="container">

        {/* HERO */}

        <section className="hero">
          <div className="hero-content">
            <p className="eyebrow">
              DECENTRALIZED ISLAMIC FINANCE
            </p>

            <h1>
              Ethical Finance.
              <br />
              <span>Powered by Blockchain.</span>
            </h1>

            <p className="subtitle">
              A new approach to ethical, transparent and
              Sharia-compliant financing, powered by QORE Chain.
            </p>

            <div className="hero-features">
              <span>✓ Transparent Financing</span>
              <span>✓ On-chain Records</span>
              <span>✓ Ethical Investment</span>
            </div>

            {!account && (
              <button
                className="primary-btn hero-btn"
                onClick={connectWallet}
                disabled={connecting}
              >
                {connecting
                  ? "Connecting..."
                  : "Access Your Account →"}
              </button>
            )}
          </div>

          <div className="hero-side">
            <div className="hero-side-icon">✦</div>
            <p>FINANCIAL TRANSPARENCY</p>
            <strong>Built on Trust.</strong>
            <span>Powered by QORE Chain.</span>
          </div>
        </section>

        {/* ERROR */}

        {error && (
          <div className="error">
            <span>⚠ {error}</span>
            <button
              className="dismiss-btn"
              onClick={() => setError("")}
            >
              ×
            </button>
          </div>
        )}

        {/* BORROWER DASHBOARD */}

        {account && (
          <section className="dashboard">

            <div className="section-heading">
              <div>
                <p className="eyebrow">ON-CHAIN ACCOUNT</p>
                <h2>Welcome Back</h2>
                <p className="section-description">
                  Manage your financing and underwriting applications.
                </p>
              </div>

              <button
                className="refresh-btn"
                onClick={() => loadDashboard(account)}
                disabled={loadingData}
              >
                {loadingData ? "↻ Refreshing..." : "↻ Refresh"}
              </button>
            </div>

            {loadingData && !dashboard && (
              <div className="empty-state">
                <div className="loader" />
                <h3>Loading your account</h3>
                <p>
                  Fetching your latest QORE blockchain records...
                </p>
              </div>
            )}

            {!loadingData && !dashboard && (
              <div className="empty-state">
                <div className="empty-icon">◈</div>
                <h3>Account data unavailable</h3>
                <p>
                  Your wallet is connected, but we could not
                  retrieve your dashboard information.
                </p>
                <button
                  className="primary-btn"
                  onClick={() => loadDashboard(account)}
                >
                  Try Again
                </button>
              </div>
            )}

            {dashboard && (
              <>

                {/* ACCOUNT OVERVIEW */}

                <div className="overview-grid">

                  <div className="overview-card wallet-card">
                    <div className="overview-top">
                      <span className="overview-icon">◈</span>
                      <span className="overview-label">
                        CONNECTED WALLET
                      </span>
                    </div>

                    <h3 title={account}>
                      {shortenAddress(account)}
                    </h3>

                    <span className="overview-caption">
                      QORE Diana Testnet
                    </span>
                  </div>

                  <div className="overview-card">
                    <div className="overview-top">
                      <span className="overview-icon">＄</span>
                      <span className="overview-label">
                        AVAILABLE BALANCE
                      </span>
                    </div>

                    <h3>
                      {dashboard.token.balance}
                    </h3>

                    <span className="overview-caption">
                      USDC
                    </span>
                  </div>

                  <div className="overview-card">
                    <div className="overview-top">
                      <span className="overview-icon">✓</span>
                      <span className="overview-label">
                        UNDERWRITING
                      </span>
                    </div>

                    <h3 className="overview-status">
                      {dashboard.underwriting.status}
                    </h3>

                    <span
                      className={statusClass(
                        dashboard.underwriting.status
                      )}
                    >
                      {dashboard.underwriting.status}
                    </span>
                  </div>

                </div>

                {/* UNDERWRITING */}

                <div className="module-heading">
                  <div>
                    <p className="eyebrow">APPLICATION CENTER</p>
                    <h2>Underwriting</h2>
                    <p className="section-description">
                      Submit encrypted evidence for financing eligibility.
                    </p>
                  </div>

                  <span
                    className={statusClass(
                      dashboard.underwriting.status
                    )}
                  >
                    {dashboard.underwriting.status}
                  </span>
                </div>

                <div className="underwriting-panel">

                  <div className="module-intro">
                    <div className="module-icon">🛡️</div>
                    <div>
                      <h3>Underwriting Application</h3>
                      <p>
                        Securely submit your encrypted QoreSeal
                        evidence envelope for review.
                      </p>
                    </div>
                  </div>

                  <div className="underwriting-details">

                    <div className="detail-item">
                      <span className="data-label">
                        Application Status
                      </span>
                      <strong>
                        {dashboard.underwriting.status}
                      </strong>
                    </div>

                    <div className="detail-item">
                      <span className="data-label">
                        Submission Date
                      </span>
                      <strong>
                        {formatDate(
                          dashboard.underwriting.submittedAt
                        )}
                      </strong>
                    </div>

                    {dashboard.underwriting.reviewer !==
                      "0x0000000000000000000000000000000000000000" && (
                      <div className="detail-item">
                        <span className="data-label">
                          Assigned Reviewer
                        </span>
                        <strong>
                          {shortenAddress(
                            dashboard.underwriting.reviewer
                          )}
                        </strong>
                      </div>
                    )}

                  </div>

                  {canSubmitUnderwriting ? (
                    <div className="submission-form">

                      <label htmlFor="encryptedEnvelope">
                        Encrypted QoreSeal Evidence Envelope
                      </label>

                      <textarea
                        id="encryptedEnvelope"
                        value={encryptedEnvelope}
                        onChange={(event) =>
                          setEncryptedEnvelope(event.target.value)
                        }
                        placeholder="Paste your already-encrypted test evidence envelope..."
                        rows={5}
                        disabled={submittingUnderwriting}
                      />

                      <div className="form-footer">
                        <p>
                          🔒 Submit encrypted evidence only.
                        </p>

                        <button
                          className="primary-btn"
                          onClick={handleUnderwritingSubmit}
                          disabled={
                            submittingUnderwriting ||
                            !encryptedEnvelope.trim()
                          }
                        >
                          {submittingUnderwriting
                            ? "Submitting..."
                            : "Submit Application →"}
                        </button>
                      </div>
                    </div>
                  ) : dashboard.underwriting.status === "PENDING" ? (
                    <div className="notice notice-warning">
                      <strong>Application Under Review</strong>
                      <p>
                        Your application is awaiting underwriter review.
                      </p>
                    </div>
                  ) : dashboard.underwriting.status === "APPROVED" ? (
                    <div className="notice notice-success">
                      <strong>Application Approved</strong>
                      <p>
                        Your underwriting application has been approved.
                        You can proceed to the Murabaha financing stage.
                      </p>
                    </div>
                  ) : (
                    <div className="notice notice-neutral">
                      Your application cannot currently be submitted.
                      Please check your application status.
                    </div>
                  )}

                  {underwritingMessage && (
                    <div className="success">
                      <strong>✓ Transaction Submitted</strong>
                      <p>{underwritingMessage}</p>
                    </div>
                  )}

                </div>

                {/* MURABAHA FINANCING */}

                <div className="module-heading financing-heading">
                  <div>
                    <p className="eyebrow">ASSET-BACKED FINANCING</p>
                    <h2>Murabaha Financing</h2>
                    <p className="section-description">
                      Track your purchase cost, sale price and repayment.
                    </p>
                  </div>

                  <span
                    className={
                      dashboard.financing.active
                        ? "badge badge-success"
                        : "badge badge-neutral"
                    }
                  >
                    {dashboard.financing.active
                      ? "ACTIVE FINANCING"
                      : "NO ACTIVE FINANCING"}
                  </span>
                </div>

                {!dashboard.financing.active ? (
                  <div className="empty-state financing-empty">
                    <div className="empty-icon">⌂</div>
                    <h3>No active Murabaha financing</h3>
                    <p>
                      Your financing details will appear here once
                      a Murabaha agreement has been created.
                    </p>
                  </div>
                ) : (
                  <>
                    <div className="data-grid">

                      <div className="data-card">
                        <span className="data-label">
                          FINANCING COST
                        </span>
                        <strong>
                          {dashboard.financing.costPrice}
                        </strong>
                      </div>

                      <div className="data-card highlight-card">
                        <span className="data-label">
                          AGREED SALE PRICE
                        </span>
                        <strong>
                          {dashboard.financing.salePrice}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          AMOUNT PAID
                        </span>
                        <strong>
                          {dashboard.financing.paidAmount}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          OUTSTANDING BALANCE
                        </span>
                        <strong>
                          {dashboard.financing.outstanding}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          INSTALLMENT AMOUNT
                        </span>
                        <strong>
                          {dashboard.financing.installmentAmount}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          COLLATERAL
                        </span>
                        <strong>
                          {dashboard.financing.collateralAmount}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          INSTALLMENTS PAID
                        </span>
                        <strong>
                          {installmentsPaid} / {installmentTotal}
                        </strong>
                      </div>

                      <div className="data-card">
                        <span className="data-label">
                          NEXT DUE DATE
                        </span>
                        <strong>
                          {formatDate(
                            dashboard.financing.nextDueDate
                          )}
                        </strong>
                      </div>

                    </div>

                    {/* REPAYMENT PROGRESS */}

                    <div className="progress-panel">
                      <div className="progress-heading">
                        <div>
                          <h3>Repayment Progress</h3>
                          <p>
                            Installments completed
                          </p>
                        </div>

                        <strong>
                          {repaymentProgress.toFixed(0)}%
                        </strong>
                      </div>

                      <div className="progress-track">
                        <div
                          className="progress-fill"
                          style={{
                            width: `${repaymentProgress}%`,
                          }}
                        />
                      </div>

                      <div className="progress-footer">
                        <span>
                          {installmentsPaid} completed
                        </span>
                        <span>
                          {Math.max(
                            0,
                            installmentTotal - installmentsPaid
                          )} remaining
                        </span>
                      </div>
                    </div>
                  </>
                )}

                {/* FINANCING STATUS */}

                <h3 className="dashboard-subtitle">
                  Account & Risk Status
                </h3>

                <div className="account-summary status-summary">

                  <div>
                    <span className="data-label">
                      FINANCING STATUS
                    </span>
                    <strong>
                      {dashboard.financing.active
                        ? "Active"
                        : "No active financing"}
                    </strong>
                  </div>

                  <div>
                    <span className="data-label">
                      PAYMENT STATUS
                    </span>
                    <span
                      className={
                        dashboard.repayment.late
                          ? "badge badge-danger"
                          : "badge badge-success"
                      }
                    >
                      {dashboard.repayment.late
                        ? "Payment Late"
                        : "Payments Up to Date"}
                    </span>
                  </div>

                  <div>
                    <span className="data-label">
                      LIQUIDATION STATUS
                    </span>
                    <span
                      className={
                        dashboard.repayment.liquidatable
                          ? "badge badge-danger"
                          : "badge badge-success"
                      }
                    >
                      {dashboard.repayment.liquidatable
                        ? "Liquidatable"
                        : "Not Liquidatable"}
                    </span>
                  </div>

                </div>

              </>
            )}

          </section>
        )}
{/* ========================================= */}
{/* UNDERWRITER REVIEW DASHBOARD */}
{/* ========================================= */}

{account && (
  <section className="dashboard">

    <div className="section-heading">
      <div>
        <p className="eyebrow">APPLICATION MANAGEMENT</p>
        <h2>Underwriter Review</h2>
        <p className="section-description">
          Review borrower applications and record decisions on QORE Chain.
        </p>
      </div>

      <span
        className={
          isUnderwriter
            ? "badge badge-success"
            : "badge badge-danger"
        }
      >
        {isUnderwriter ? "AUTHORIZED UNDERWRITER" : "NOT AUTHORIZED"}
      </span>
    </div>

    {!isUnderwriter ? (
      <div className="notice notice-warning">
        <strong>Underwriter access required</strong>
        <p>
          Your connected wallet does not have permission to review applications.
        </p>
      </div>
    ) : (
      <div className="underwriting-panel">

        <div className="module-intro">
          <div className="module-icon">⚖️</div>

          <div>
            <h3>Application Review</h3>
            <p>
              Enter a borrower wallet address to retrieve its underwriting record.
            </p>
          </div>
        </div>

        <div className="detail-item">
          <span className="data-label">CONNECTED UNDERWRITER</span>
          <strong>{shortenAddress(account)}</strong>
        </div>

        {isAdmin && (
          <span className="badge badge-success">
            ADMINISTRATOR
          </span>
        )}

        <div className="submission-form">

          <label htmlFor="underwriterBorrower">
            Borrower Wallet Address
          </label>

          <input
            id="underwriterBorrower"
            type="text"
            value={underwriterBorrower}
            onChange={(event) => {
              setUnderwriterBorrower(event.target.value);
              setUnderwriterRecord(null);
              setUnderwriterMessage("");
            }}
            placeholder="0x..."
            disabled={
              loadingUnderwriterRecord ||
              reviewingApplication
            }
            style={{
              width: "100%",
              padding: "14px",
              borderRadius: "8px",
              border: "1px solid #dce5df",
              marginTop: "10px",
              marginBottom: "15px",
            }}
          />

          <button
            className="primary-btn"
            onClick={loadUnderwriterRecord}
            disabled={
              loadingUnderwriterRecord ||
              reviewingApplication ||
              !underwriterBorrower.trim()
            }
          >
            {loadingUnderwriterRecord
              ? "Loading Application..."
              : "Load Application →"}
          </button>

        </div>

        {underwriterRecord && (
          <div className="underwriting-details">

            <div className="detail-item">
              <span className="data-label">BORROWER</span>
              <strong title={underwriterRecord.borrower}>
                {shortenAddress(underwriterRecord.borrower)}
              </strong>
            </div>

            <div className="detail-item">
              <span className="data-label">APPLICATION STATUS</span>
              <span className={statusClass(underwriterRecord.status)}>
                {underwriterRecord.status}
              </span>
            </div>

            <div className="detail-item">
              <span className="data-label">SUBMISSION DATE</span>
              <strong>
                {formatDate(underwriterRecord.submittedAt)}
              </strong>
            </div>

            <div className="detail-item">
              <span className="data-label">REVIEWER</span>
              <strong>
                {underwriterRecord.reviewer ===
                "0x0000000000000000000000000000000000000000"
                  ? "Not reviewed"
                  : shortenAddress(underwriterRecord.reviewer)}
              </strong>
            </div>

            <div className="detail-item">
              <span className="data-label">REVIEW DATE</span>
              <strong>
                {formatDate(underwriterRecord.reviewedAt)}
              </strong>
            </div>

            <div
              className="detail-item"
              style={{ gridColumn: "1 / -1" }}
            >
              <span className="data-label">
                ENCRYPTED EVIDENCE HASH
              </span>

              <code
                style={{
                  overflowWrap: "anywhere",
                  fontSize: "12px",
                  marginTop: "8px",
                }}
              >
                {underwriterRecord.ciphertextHash}
              </code>
            </div>

          </div>
        )}

        {underwriterRecord?.status === "PENDING" && (
          <div className="form-footer">

            <button
              className="primary-btn"
              onClick={() => handleUnderwritingReview(true)}
              disabled={reviewingApplication}
            >
              {reviewingApplication
                ? "Processing..."
                : "✓ Approve Application"}
            </button>

            <button
              className="card-btn"
              onClick={() => handleUnderwritingReview(false)}
              disabled={reviewingApplication}
            >
              ✕ Reject Application
            </button>

          </div>
        )}

        {underwriterRecord &&
          underwriterRecord.status !== "PENDING" && (
            <div className="notice notice-neutral">
              This application has already been reviewed or is not
              currently eligible for review.
            </div>
          )}

        {underwriterMessage && (
          <div className="success">
            <strong>✓ Review Transaction Confirmed</strong>
            <p>{underwriterMessage}</p>
          </div>
        )}

      </div>
    )}
  </section>
)}
        {/* QORESEAL BROWSER TEST */}

        <section className="dashboard">
          <div className="module-heading">
            <div>
              <p className="eyebrow">PRIVACY & ENCRYPTION</p>
              <h2>QoreSeal Browser Test</h2>
              <p className="section-description">
                Test encrypted financial data directly in your browser.
              </p>
            </div>
          </div>

          <div className="underwriting-panel">
            <div className="module-intro">
              <div className="module-icon">🔐</div>
              <div>
                <h3>Encryption Verification</h3>
                <p>
                  Generate temporary keys, encrypt sample financial
                  information and verify decryption.
                </p>
              </div>
            </div>

            <button
              className="primary-btn"
              onClick={handleQoreSealTest}
              disabled={testingQoreSeal}
            >
              {testingQoreSeal
                ? "Testing Encryption..."
                : "Run QoreSeal Browser Test →"}
            </button>

            {qoreSealResult && (
              <pre
                style={{
                  whiteSpace: "pre-wrap",
                  overflowWrap: "anywhere",
                  marginTop: "20px",
                  padding: "18px",
                  borderRadius: "10px",
                  background: "#f1f7f3",
                  color: "#174c36",
                  fontSize: "13px",
                }}
              >
                {qoreSealResult}
              </pre>
            )}
          </div>
        </section>

        {/* FINANCIAL SERVICES */}

        <section className="dashboard services-section">

          <div className="section-heading">
            <div>
              <p className="eyebrow">YOUR PLATFORM</p>
              <h2>Financial Services</h2>
              <p className="section-description">
                Ethical financial products built on blockchain technology.
              </p>
            </div>

            <span className="status">
              ● Testnet Active
            </span>
          </div>

          <div className="cards">

            <div className="card">
              <div className="card-icon">⌂</div>
              <h3>Murabaha Financing</h3>
              <p>
                Request asset-backed financing with transparent
                purchase cost and an agreed sale price.
              </p>
              <button className="card-btn" disabled>
                Coming Next →
              </button>
            </div>

            <div className="card">
              <div className="card-icon">↗</div>
              <h3>Mudarabah Investment</h3>
              <p>
                Participate in Sharia-compliant investment
                opportunities and agreed profit-sharing arrangements.
              </p>
              <button className="card-btn" disabled>
                Coming Next →
              </button>
            </div>

            <div className="card">
              <div className="card-icon">♢</div>
              <h3>Underwriting</h3>
              <p>
                Review financing eligibility and collateral
                through on-chain underwriting.
              </p>
              <button className="card-btn" disabled>
                Available in Dashboard
              </button>
            </div>

            <div className="card">
              <div className="card-icon">⌑</div>
              <h3>QoreSeal Verification</h3>
              <p>
                Verify financing evidence and on-chain
                attestation records.
              </p>
              <button className="card-btn" disabled>
                Coming Next →
              </button>
            </div>

          </div>
        </section>

        {/* FOOTER */}

        <footer>
          <div className="footer-logo">
            WEIDAI<span>.</span>
          </div>

          <p>
            Ethical Finance. Powered by Blockchain.
          </p>

          <p className="footer-copy">
            © 2026 WEIDAI | Built on QORE Chain
          </p>
        </footer>

      </main>
    </div>
  );
}

export default App;
 