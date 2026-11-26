import {
  generateSealKeys,
  recipientOf,
  seal,
  open,
  envelopeToText,
  envelopeFromText,
} from "@qorechain/qoreseal";

import { keccak256, toUtf8Bytes } from "ethers";

export async function runQoreSealBrowserTest() {
  // Generate temporary keys in browser memory.
  const borrower = generateSealKeys();
  const underwriter = generateSealKeys();

  // Dummy financing information.
  const financialData = {
    borrower: "BrowserTest001",
    requestedAmount: "5000",
    currency: "USDC",
    monthlyIncome: "1200",
  };

  const originalText = JSON.stringify(financialData);

  const plaintext = new TextEncoder().encode(originalText);

  // Encrypt for both borrower and underwriter.
  const envelope = seal({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    recipients: [
      recipientOf(borrower),
      recipientOf(underwriter),
    ],
    plaintext,
  });

  // Serialize encrypted envelope.
  const encryptedText = envelopeToText(envelope);

  if (!encryptedText.startsWith("qoreseal:")) {
    throw new Error("Invalid QoreSeal envelope.");
  }

  // Restore serialized envelope.
  const restoredEnvelope = envelopeFromText(encryptedText);

  // Decrypt using borrower key.
  const borrowerResult = open({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    envelope: restoredEnvelope,
    keys: borrower,
  });

  // Decrypt using underwriter key.
  const underwriterResult = open({
    chainId: "qorechain-diana",
    purpose: "weidai-underwriting",
    envelope: restoredEnvelope,
    keys: underwriter,
  });

  const borrowerText = new TextDecoder().decode(borrowerResult);
  const underwriterText = new TextDecoder().decode(underwriterResult);

  if (borrowerText !== originalText) {
    throw new Error("Borrower decryption verification failed.");
  }

  if (underwriterText !== originalText) {
    throw new Error("Underwriter decryption verification failed.");
  }

  // Hash exactly the serialized envelope.
  const ciphertextHash = keccak256(
    toUtf8Bytes(encryptedText)
  );

  return {
    encryption: "SUCCESS",
    borrowerDecryption: "SUCCESS",
    underwriterDecryption: "SUCCESS",
    envelopeFormat: "qoreseal:",
    envelopeLength: encryptedText.length,
    ciphertextHash,
  };
}