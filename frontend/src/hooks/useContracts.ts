import {
  BrowserProvider,
  Contract,
  JsonRpcProvider,
  formatUnits,
  keccak256,
  toUtf8Bytes,
  isAddress,
} from "ethers";

import { QORE_CONFIG, CONTRACT_ADDRESSES } from "../contracts/addresses";

import MurabahaABI from "../contracts/MurabahaFinancing.json";
import UnderwritingABI from "../contracts/UnderwritingRegistry.json";
import TokenABI from "../contracts/ERC20Mock.json";

const provider = new JsonRpcProvider(QORE_CONFIG.rpcUrl);

const murabaha = new Contract(
  CONTRACT_ADDRESSES.MURABAHA_FINANCING,
  MurabahaABI,
  provider
);

const underwriting = new Contract(
  CONTRACT_ADDRESSES.UNDERWRITING_REGISTRY,
  UnderwritingABI,
  provider
);

const usdc = new Contract(
  CONTRACT_ADDRESSES.USDC,
  TokenABI,
  provider
);

const collateralToken = new Contract(
  CONTRACT_ADDRESSES.COLLATERAL,
  TokenABI,
  provider
);

const UNDERWRITING_STATUSES = [
  "NONE",
  "PENDING",
  "APPROVED",
  "REJECTED",
  "CONSUMED",
];

export async function getBorrowerDashboard(address: string) {
  const [
    financing,
    outstanding,
    record,
    usdcDecimals,
    collateralDecimals,
    late,
    liquidatable,
    tokenBalance,
    tokenAllowance,
  ] = await Promise.all([
    murabaha.financings(address),
    murabaha.outstanding(address),
    underwriting.records(address),
    usdc.decimals(),
    collateralToken.decimals(),
    murabaha.isLate(address),
    murabaha.isLiquidatable(address),
    usdc.balanceOf(address),
    usdc.allowance(
      address,
      CONTRACT_ADDRESSES.MURABAHA_FINANCING
    ),
  ]);

  const formatUSDC = (value: bigint) =>
    formatUnits(value, Number(usdcDecimals));

  const formatCollateral = (value: bigint) =>
    formatUnits(value, Number(collateralDecimals));

  const statusNumber = Number(record.status);

  return {
    borrower: address,

    underwriting: {
      approved: statusNumber === 2,
      status: UNDERWRITING_STATUSES[statusNumber] ?? "UNKNOWN",
      ciphertextHash: record.ciphertextHash,
      reviewer: record.reviewer,
      submittedAt: Number(record.submittedAt),
      reviewedAt: Number(record.reviewedAt),
    },

    financing: {
      costPrice: formatUSDC(financing.costPrice),
      salePrice: formatUSDC(financing.salePrice),
      paidAmount: formatUSDC(financing.paidAmount),
      outstanding: formatUSDC(outstanding),
      collateralAmount: formatCollateral(financing.collateralAmount),
      installmentAmount: formatUSDC(financing.installmentAmount),
      installmentsTotal: Number(financing.installmentsTotal),
      installmentsPaid: Number(financing.installmentsPaid),
      nextDueDate: Number(financing.nextDueDate),
      active: financing.active,
    },

    repayment: {
      late,
      liquidatable,
    },

    token: {
      balance: formatUSDC(tokenBalance),
      allowance: formatUSDC(tokenAllowance),
      balanceRaw: tokenBalance.toString(),
      allowanceRaw: tokenAllowance.toString(),
    },
  };
}

/**
 * Submits the hash of an already-encrypted QoreSeal envelope.
 * This function does NOT encrypt the applicant's information.
 */
export async function submitUnderwritingRecord(
  encryptedEnvelope: string
) {
  if (!window.ethereum) {
    throw new Error("Please install or unlock MetaMask.");
  }

  const envelope = encryptedEnvelope.trim();

  if (!envelope) {
    throw new Error(
      "Please provide an encrypted evidence envelope."
    );
  }

  const walletProvider = new BrowserProvider(window.ethereum);

  // Verify network.
  const network = await walletProvider.getNetwork();

  if (Number(network.chainId) !== QORE_CONFIG.chainId) {
    throw new Error("Please connect to QORE Diana Testnet.");
  }

  const signer = await walletProvider.getSigner();

  // Hash the encrypted envelope.
  const ciphertextHash = keccak256(toUtf8Bytes(envelope));

  const registry = new Contract(
    CONTRACT_ADDRESSES.UNDERWRITING_REGISTRY,
    UnderwritingABI,
    signer
  );

  // Submit transaction.
  const transaction = await registry.submitRecord(ciphertextHash);

  // Wait for mining.
  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "Underwriting submission transaction failed."
    );
  }

  return {
    transactionHash: receipt.hash,
    ciphertextHash,
    blockNumber: receipt.blockNumber,
    borrower: await signer.getAddress(),
  };
}
  // =========================================
// UNDERWRITER ACCESS
// =========================================

export async function getUnderwriterAccess(address: string) {
  if (!isAddress(address)) {
    throw new Error("Invalid wallet address.");
  }

  const [underwriterRole, adminRole] = await Promise.all([
    underwriting.UNDERWRITER_ROLE(),
    underwriting.DEFAULT_ADMIN_ROLE(),
  ]);

  const [authorized, isAdmin] = await Promise.all([
    underwriting.hasRole(underwriterRole, address),
    underwriting.hasRole(adminRole, address),
  ]);

  return { authorized, isAdmin };
}
// =========================================
// FETCH A BORROWER'S UNDERWRITING RECORD
// =========================================

const getStatusName = (status: number) =>
  UNDERWRITING_STATUSES[status] ?? "UNKNOWN";

export async function getUnderwriterRecord(borrower: string) {
  if (!isAddress(borrower)) {
    throw new Error("Please enter a valid borrower address.");
  }

  const record = await underwriting.records(borrower);

  const statusNumber = Number(record.status);

  return {
    borrower,
    ciphertextHash: record.ciphertextHash,
    status: getStatusName(statusNumber),
    reviewer: record.reviewer,
    submittedAt: Number(record.submittedAt),
    reviewedAt: Number(record.reviewedAt),
  };
}

// =========================================
// APPROVE OR REJECT AN APPLICATION
// =========================================

export async function reviewUnderwritingRecord(
  borrower: string,
  approved: boolean
) {
  if (!window.ethereum) {
    throw new Error("Please install or unlock MetaMask.");
  }

  if (!isAddress(borrower)) {
    throw new Error("Invalid borrower address.");
  }

  const walletProvider = new BrowserProvider(window.ethereum);

  const network = await walletProvider.getNetwork();

  if (Number(network.chainId) !== QORE_CONFIG.chainId) {
    throw new Error("Please connect to QORE Diana Testnet.");
  }

  const signer = await walletProvider.getSigner();
  const reviewer = await signer.getAddress();

  const registry = new Contract(
    CONTRACT_ADDRESSES.UNDERWRITING_REGISTRY,
    UnderwritingABI,
    signer
  );

  const role = await registry.UNDERWRITER_ROLE();

  const authorized = await registry.hasRole(role, reviewer);

  if (!authorized) {
    throw new Error(
      "This wallet does not have UNDERWRITER_ROLE."
    );
  }

  // Submit review transaction.
  const transaction = await registry.reviewRecord(
    borrower,
    approved
  );

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error("Underwriting review transaction failed.");
  }

  return {
    transactionHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    borrower,
    reviewer,
    status: approved ? "APPROVED" : "REJECTED",
  };
}
 