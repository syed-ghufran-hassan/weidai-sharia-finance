import {
  generateSealKeys,
  recipientOf,
  seal,
  open,
  envelopeToText,
  envelopeFromText
} from "@qorechain/qoreseal";

import {
  JsonRpcProvider,
  Wallet,
  Contract,
  keccak256,
  toUtf8Bytes
} from "ethers";

import "dotenv/config";
import { writeFile } from "node:fs/promises";

async function main() {
  // Generate encryption keys for borrower and underwriter.
  const borrower = generateSealKeys();
  const underwriter = generateSealKeys();

  const financialData = {
    borrower: "Borrower001",
    requestedAmount: "5000",
    currency: "USDC",
    monthlyIncome: "1200"
  };

  const plaintext = new TextEncoder().encode(
    JSON.stringify(financialData)
  );

  // Encrypt for both borrower and underwriter.
  const envelope = seal({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    recipients: [
      recipientOf(borrower),
      recipientOf(underwriter)
    ],
    plaintext
  });

  const encryptedDocument = envelopeToText(envelope);

  // Generate Keccak-256 hash of the encrypted document.
  const ciphertextHash = keccak256(
    toUtf8Bytes(encryptedDocument)
  );

  console.log("\nEncrypted document hash:");
  console.log(ciphertextHash);

  // Save encrypted document locally.
  await writeFile(
    "encrypted-underwriting-record.txt",
    encryptedDocument,
    "utf8"
  );

  console.log("\nEncrypted document saved locally.");

  // Validate environment variables.
  const rpcUrl = process.env.RPC_URL;
  const registryAddress = process.env.REGISTRY_ADDRESS;
  const borrowerPrivateKey = process.env.BORROWER_PRIVATE_KEY;

  if (!rpcUrl || !registryAddress || !borrowerPrivateKey) {
    throw new Error(
      "Missing RPC_URL, REGISTRY_ADDRESS, or BORROWER_PRIVATE_KEY in .env"
    );
  }

  // Connect to local Anvil.
  const provider = new JsonRpcProvider(rpcUrl);

  const borrowerWallet = new Wallet(
    borrowerPrivateKey,
    provider
  );

  // Minimal UnderwritingRegistry ABI.
  const registryABI = [
    "function submitRecord(bytes32 ciphertextHash) external",
    "function records(address) view returns (bytes32, uint8, address, uint64, uint64)"
  ];

  const registry = new Contract(
    registryAddress,
    registryABI,
    borrowerWallet
  );

  console.log("\nBorrower address:");
  console.log(borrowerWallet.address);

  // Submit encrypted document hash to the blockchain.
  const tx = await registry.submitRecord(ciphertextHash);

  console.log("\nTransaction submitted:");
  console.log(tx.hash);

  const receipt = await tx.wait();

  console.log("\nTransaction confirmed in block:");
  console.log(receipt.blockNumber);

  // Read and verify the borrower's registry record.
  const record = await registry.records(
    borrowerWallet.address
  );

  console.log("\nOn-chain record:");
  console.log("Ciphertext hash:", record[0]);
  console.log("Status:", record[1].toString());

  // Underwriter decrypts the encrypted document.
  const restoredEnvelope = envelopeFromText(encryptedDocument);

  const decrypted = open({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    envelope: restoredEnvelope,
    keys: underwriter
  });

  console.log("\nDecrypted document:");
  console.log(new TextDecoder().decode(decrypted));

  // Close provider connection.
  await provider.destroy();
}

main().catch((error) => {
  console.error("\nApplication failed:");
  console.error(error);
  process.exitCode = 1;
});