import {
  generateSealKeys,
  recipientOf,
  seal,
  open,
  envelopeToText,
  envelopeFromText,
} from "@qorechain/qoreseal";

import { keccak256, toUtf8Bytes } from "ethers";
import assert from "node:assert/strict";

async function main() {
  console.log("\nWEIDAI - QoreSeal encryption test\n");

  // Generate temporary keys for this test only.
  const borrower = generateSealKeys();
  const underwriter = generateSealKeys();

  const financialData = {
    borrower: "Borrower001",
    requestedAmount: "5000",
    currency: "USDC",
    monthlyIncome: "1200",
  };

  const plaintext = new TextEncoder().encode(
    JSON.stringify(financialData)
  );

  // Encrypt for both recipients.
  const envelope = seal({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    recipients: [
      recipientOf(borrower),
      recipientOf(underwriter),
    ],
    plaintext,
  });

  // Convert to the portable QoreSeal text format.
  const encryptedText = envelopeToText(envelope);

  assert.ok(
    encryptedText.startsWith("qoreseal:"),
    "Invalid QoreSeal envelope format"
  );

  // Restore the envelope from its text representation.
  const restoredEnvelope = envelopeFromText(encryptedText);

  // Verify borrower can decrypt.
  const borrowerPlaintext = open({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    envelope: restoredEnvelope,
    keys: borrower,
  });

  // Verify underwriter can decrypt.
  const underwriterPlaintext = open({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    envelope: restoredEnvelope,
    keys: underwriter,
  });

  const expected = JSON.stringify(financialData);

  assert.equal(
    new TextDecoder().decode(borrowerPlaintext),
    expected
  );

  assert.equal(
    new TextDecoder().decode(underwriterPlaintext),
    expected
  );

  // Calculate the same commitment format used by the Solidity contract.
  const ciphertextHash = keccak256(
    toUtf8Bytes(encryptedText)
  );

  console.log("Encryption: SUCCESS");
  console.log("Envelope format:", encryptedText.slice(0, 9));
  console.log("Borrower decryption: SUCCESS");
  console.log("Underwriter decryption: SUCCESS");
  console.log("Ciphertext hash:", ciphertextHash);
  console.log("Envelope length:", encryptedText.length);

  console.log("\nQoreSeal test completed successfully.");
}

main().catch((error) => {
  console.error("\nQoreSeal test failed:");
  console.error(error);
  process.exitCode = 1;
});