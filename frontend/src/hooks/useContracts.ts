import {
  BrowserProvider,
  Contract,
  JsonRpcProvider,
  formatUnits,
  parseUnits,
  keccak256,
  toUtf8Bytes,
  isAddress,
} from "ethers";

import {
  QORE_CONFIG,
  CONTRACT_ADDRESSES,
} from "../contracts/addresses";

import MurabahaABI from "../contracts/MurabahaFinancing.json";
import UnderwritingABI from "../contracts/UnderwritingRegistry.json";
import TokenABI from "../contracts/ERC20Mock.json";

// =========================================
// PROVIDER AND CONTRACT INSTANCES
// =========================================

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

// =========================================
// BORROWER DASHBOARD
// =========================================

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
    collateralBalance,
    collateralAllowance,
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

    collateralToken.balanceOf(address),

    collateralToken.allowance(
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

      status:
        UNDERWRITING_STATUSES[statusNumber] ?? "UNKNOWN",

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

      collateralAmount: formatCollateral(
        financing.collateralAmount
      ),

      installmentAmount: formatUSDC(
        financing.installmentAmount
      ),

      installmentsTotal: Number(
        financing.installmentsTotal
      ),

      installmentsPaid: Number(
        financing.installmentsPaid
      ),

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

      collateralBalance: formatCollateral(
        collateralBalance
      ),

      collateralAllowance: formatCollateral(
        collateralAllowance
      ),

      collateralBalanceRaw: collateralBalance.toString(),
      collateralAllowanceRaw: collateralAllowance.toString(),
    },
  };
}

// =========================================
// UNDERWRITING SUBMISSION
// =========================================

/**
 * Submits the hash of an already-encrypted QoreSeal envelope.
 *
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

  const walletProvider = new BrowserProvider(
    window.ethereum
  );

  const network = await walletProvider.getNetwork();

  if (Number(network.chainId) !== QORE_CONFIG.chainId) {
    throw new Error(
      "Please connect to QORE Diana Testnet."
    );
  }

  const signer = await walletProvider.getSigner();

  const ciphertextHash = keccak256(
    toUtf8Bytes(envelope)
  );

  const registry = new Contract(
    CONTRACT_ADDRESSES.UNDERWRITING_REGISTRY,
    UnderwritingABI,
    signer
  );

  const transaction = await registry.submitRecord(
    ciphertextHash
  );

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

export async function getUnderwriterAccess(
  address: string
) {
  if (!isAddress(address)) {
    throw new Error("Invalid wallet address.");
  }

  const [
    underwriterRole,
    adminRole,
  ] = await Promise.all([
    underwriting.UNDERWRITER_ROLE(),
    underwriting.DEFAULT_ADMIN_ROLE(),
  ]);

  const [
    authorized,
    isAdmin,
  ] = await Promise.all([
    underwriting.hasRole(
      underwriterRole,
      address
    ),

    underwriting.hasRole(
      adminRole,
      address
    ),
  ]);

  return {
    authorized,
    isAdmin,
  };
}

// =========================================
// FETCH UNDERWRITING RECORD
// =========================================

const getStatusName = (status: number) =>
  UNDERWRITING_STATUSES[status] ?? "UNKNOWN";

export async function getUnderwriterRecord(
  borrower: string
) {
  if (!isAddress(borrower)) {
    throw new Error(
      "Please enter a valid borrower address."
    );
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
// FETCH PENDING APPLICATIONS
// =========================================

export async function getPendingUnderwritingApplications() {
  const latestBlock = await provider.getBlockNumber();

  // MVP: scan the most recent 20,000 blocks.
  // We can replace this with the exact deployment block later.
  const fromBlock = Math.max(
    0,
    latestBlock - 20_000
  );

  const chunkSize = 2_000;

  const filter = underwriting.filters.RecordSubmitted();

  const borrowerAddresses = new Set<string>();

  for (
    let startBlock = fromBlock;
    startBlock <= latestBlock;
    startBlock += chunkSize
  ) {
    const endBlock = Math.min(
      startBlock + chunkSize - 1,
      latestBlock
    );

    const events = await underwriting.queryFilter(
      filter,
      startBlock,
      endBlock
    );

    for (const event of events) {
      const borrower = (event as any).args?.borrower;

      if (borrower) {
        borrowerAddresses.add(
          borrower.toLowerCase()
        );
      }
    }
  }

  const applications = [];

  for (const borrower of borrowerAddresses) {
    const record = await getUnderwriterRecord(
      borrower
    );

    if (record.status === "PENDING") {
      applications.push(record);
    }
  }

  return applications.sort(
    (a, b) =>
      Number(b.submittedAt) -
      Number(a.submittedAt)
  );
}

// =========================================
// APPROVE OR REJECT APPLICATION
// =========================================

export async function reviewUnderwritingRecord(
  borrower: string,
  approved: boolean
) {
  if (!window.ethereum) {
    throw new Error(
      "Please install or unlock MetaMask."
    );
  }

  if (!isAddress(borrower)) {
    throw new Error("Invalid borrower address.");
  }

  const walletProvider = new BrowserProvider(
    window.ethereum
  );

  const network = await walletProvider.getNetwork();

  if (Number(network.chainId) !== QORE_CONFIG.chainId) {
    throw new Error(
      "Please connect to QORE Diana Testnet."
    );
  }

  const signer = await walletProvider.getSigner();

  const reviewer = await signer.getAddress();

  const registry = new Contract(
    CONTRACT_ADDRESSES.UNDERWRITING_REGISTRY,
    UnderwritingABI,
    signer
  );

  const role = await registry.UNDERWRITER_ROLE();

  const authorized = await registry.hasRole(
    role,
    reviewer
  );

  if (!authorized) {
    throw new Error(
      "This wallet does not have UNDERWRITER_ROLE."
    );
  }

  const transaction = await registry.reviewRecord(
    borrower,
    approved
  );

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "Underwriting review transaction failed."
    );
  }

  return {
    transactionHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    borrower,
    reviewer,
    status: approved ? "APPROVED" : "REJECTED",
  };
}

// =========================================
// QORE WALLET SIGNER
// =========================================

async function getQoreSigner() {
  if (!window.ethereum) {
    throw new Error(
      "Please install or unlock MetaMask."
    );
  }

  const walletProvider = new BrowserProvider(
    window.ethereum
  );

  const network = await walletProvider.getNetwork();

  if (Number(network.chainId) !== QORE_CONFIG.chainId) {
    throw new Error(
      "Please connect to QORE Diana Testnet."
    );
  }

  return walletProvider.getSigner();
}

// =========================================
// MURABAHA FINANCING QUOTE
// =========================================

export async function getFinancingQuote(
  amount: string,
  installments: number
) {
  if (!amount.trim()) {
    throw new Error(
      "Enter a financing amount."
    );
  }

  if (!Number.isInteger(installments)) {
    throw new Error(
      "Installments must be a whole number."
    );
  }

  const [
    usdcDecimals,
    collateralDecimals,
    markupBps,
    bps,
    collateralRatio,
    maxInstallments,
    oracleAddress,
  ] = await Promise.all([
    usdc.decimals(),
    collateralToken.decimals(),

    murabaha.MARKUP_BPS(),
    murabaha.BPS(),
    murabaha.COLLATERAL_RATIO(),

    murabaha.MAX_INSTALLMENTS(),
    murabaha.oracle(),
  ]);

  if (
    installments <= 0 ||
    installments > Number(maxInstallments)
  ) {
    throw new Error(
      `Installments must be between 1 and ${Number(maxInstallments)}.`
    );
  }

  const amountRaw = parseUnits(
    amount.trim(),
    Number(usdcDecimals)
  );

  if (amountRaw <= 0n) {
    throw new Error(
      "Financing amount must be greater than zero."
    );
  }

  // Read the live collateral oracle price.
  const oracle = new Contract(
    oracleAddress,
    [
      "function getPrice() view returns (uint256)",
    ],
    provider
  );

  const oraclePrice = BigInt(
    (await oracle.getPrice()).toString()
  );

  if (oraclePrice <= 0n) {
    throw new Error(
      "The collateral oracle returned an invalid price."
    );
  }

  // Calculate Murabaha markup.
  const markup =
    (amountRaw * BigInt(markupBps)) /
    BigInt(bps);

  // Calculate agreed sale price.
  const salePrice = amountRaw + markup;

  // Calculate required collateral.
  const requiredCollateral =
    (salePrice * BigInt(collateralRatio)) /
    oraclePrice;

  return {
    amount: formatUnits(
      amountRaw,
      Number(usdcDecimals)
    ),

    markup: formatUnits(
      markup,
      Number(usdcDecimals)
    ),

    salePrice: formatUnits(
      salePrice,
      Number(usdcDecimals)
    ),

    requiredCollateral: formatUnits(
      requiredCollateral,
      Number(collateralDecimals)
    ),

    amountRaw: amountRaw.toString(),

    salePriceRaw: salePrice.toString(),

    requiredCollateralRaw:
      requiredCollateral.toString(),

    oraclePrice: formatUnits(
      oraclePrice,
      18
    ),

    installments,
  };
}

// =========================================
// APPROVE COLLATERAL
// =========================================

export async function approveCollateral(
  amountRaw: string
) {
  const signer = await getQoreSigner();

  const token = new Contract(
    CONTRACT_ADDRESSES.COLLATERAL,
    TokenABI,
    signer
  );

  const transaction = await token.approve(
    CONTRACT_ADDRESSES.MURABAHA_FINANCING,
    BigInt(amountRaw)
  );

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "Collateral approval failed."
    );
  }

  return receipt.hash;
}

// =========================================
// REQUEST MURABAHA FINANCING
// =========================================

export async function requestMurabahaFinancing(
  amount: string,
  installments: number,
  collateralRequiredRaw: string
) {
  const signer = await getQoreSigner();

  const borrower = await signer.getAddress();

  const collateral = new Contract(
    CONTRACT_ADDRESSES.COLLATERAL,
    TokenABI,
    signer
  );

  const allowance = BigInt(
    (
      await collateral.allowance(
        borrower,
        CONTRACT_ADDRESSES.MURABAHA_FINANCING
      )
    ).toString()
  );

  if (allowance < BigInt(collateralRequiredRaw)) {
    throw new Error(
      "Insufficient collateral allowance. Approve the required collateral first."
    );
  }

  const financing = new Contract(
    CONTRACT_ADDRESSES.MURABAHA_FINANCING,
    MurabahaABI,
    signer
  );

  const usdcDecimals = await usdc.decimals();

  const amountRaw = parseUnits(
    amount,
    Number(usdcDecimals)
  );

  const transaction = await financing.requestFinancing(
    amountRaw,
    installments
  );

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "Murabaha financing request failed."
    );
  }

  return receipt.hash;
}

// =========================================
// APPROVE USDC FOR REPAYMENT
// =========================================

export async function approveRepayment() {
  const signer = await getQoreSigner();

  const borrower = await signer.getAddress();

  const outstanding = BigInt(
    (
      await murabaha.outstanding(borrower)
    ).toString()
  );

  if (outstanding <= 0n) {
    throw new Error(
      "There is no outstanding financing balance."
    );
  }

  // Allow outstanding balance plus 1% for a
  // possible late-payment penalty.
  const approvalAmount =
    outstanding +
    (outstanding * 100n) / 10_000n;

  const token = new Contract(
    CONTRACT_ADDRESSES.USDC,
    TokenABI,
    signer
  );

  const transaction = await token.approve(
    CONTRACT_ADDRESSES.MURABAHA_FINANCING,
    approvalAmount
  );

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "USDC repayment approval failed."
    );
  }

  return receipt.hash;
}

// =========================================
// PAY MURABAHA INSTALLMENT
// =========================================

export async function payMurabahaInstallment() {
  const signer = await getQoreSigner();

  const financing = new Contract(
    CONTRACT_ADDRESSES.MURABAHA_FINANCING,
    MurabahaABI,
    signer
  );

  const transaction = await financing.payInstallment();

  const receipt = await transaction.wait(1);

  if (!receipt || receipt.status !== 1) {
    throw new Error(
      "Installment payment failed."
    );
  }

  return receipt.hash;
}

export async function mintCollateral(
  recipient: string,
  amount: string
) {
  const signer = await getQoreSigner();

  const collateralAddress =
    "0x8DA2367f9800FBFF7aD0Ff1785A6771AA2A829a5";

  const abi = [
    "function mint(address to, uint256 amount) external"
  ];

  const contract = new Contract(
    collateralAddress,
    abi,
    signer
  );

  const amountRaw = parseUnits(amount, 18);

  const tx = await contract.mint(recipient, amountRaw);

  await tx.wait();

  return tx.hash;
}