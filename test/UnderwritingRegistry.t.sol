// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UnderwritingRegistry.sol";

/// @dev Simulates the configured financing contract when consuming an approval.
contract UnderwritingConsumer {
    function consume(UnderwritingRegistry registry, address borrower) external {
        registry.consumeApproval(borrower);
    }
}

contract UnderwritingRegistryTest is Test {
    UnderwritingRegistry internal registry;
    UnderwritingConsumer internal financingConsumer;

    address internal borrower = address(0xB0B);
    address internal underwriter = address(0xBEEF);
    address internal unauthorizedReviewer = address(0xBAD);

    bytes32 internal constant DOCUMENT_HASH = keccak256("borrower-encrypted-underwriting-record");

    function setUp() public {
        registry = new UnderwritingRegistry(address(this));
        financingConsumer = new UnderwritingConsumer();

        registry.grantUnderwriter(underwriter);
        registry.setFinancingContract(address(financingConsumer));
    }

    function _submitAsBorrower() internal {
        vm.prank(borrower);
        registry.submitRecord(DOCUMENT_HASH);
    }

    function _approveAsUnderwriter() internal {
        vm.prank(underwriter);
        registry.reviewRecord(borrower, true);
    }

    function _statusOf(address account) internal view returns (UnderwritingRegistry.Status status) {
        (, status,,,) = registry.records(account);
    }

    // ─────────────────────────────────────────────
    // 1. Record submission
    // ─────────────────────────────────────────────

    function testSubmitRecordSetsPendingStatusAndHash() public {
        _submitAsBorrower();

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.PENDING));

        (bytes32 storedHash,,,,) = registry.records(borrower);
        assertEq(storedHash, DOCUMENT_HASH);
    }

    // ─────────────────────────────────────────────
    // 2. Approval
    // ─────────────────────────────────────────────

    function testAuthorizedUnderwriterCanApproveRecord() public {
        _submitAsBorrower();
        _approveAsUnderwriter();

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.APPROVED));

        assertTrue(registry.isApproved(borrower));
    }

    function testUnauthorizedAddressCannotReviewRecord() public {
        _submitAsBorrower();

        vm.prank(unauthorizedReviewer);
        vm.expectRevert();

        registry.reviewRecord(borrower, true);
    }

    // ─────────────────────────────────────────────
    // 3. Rejection
    // ─────────────────────────────────────────────

    function testUnderwriterCanRejectRecord() public {
        _submitAsBorrower();

        vm.prank(underwriter);
        registry.reviewRecord(borrower, false);

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.REJECTED));

        assertFalse(registry.isApproved(borrower));
    }

    // ─────────────────────────────────────────────
    // 4. Duplicate submission protection
    // ─────────────────────────────────────────────

    function testCannotSubmitAnotherRecordWhileOneIsPending() public {
        _submitAsBorrower();

        vm.prank(borrower);
        vm.expectRevert(bytes("Record already active"));

        registry.submitRecord(keccak256("second-record"));
    }

    // ─────────────────────────────────────────────
    // 5. Resubmission after rejection
    // ─────────────────────────────────────────────

    function testBorrowerCanResubmitAfterRejection() public {
        _submitAsBorrower();

        vm.prank(underwriter);
        registry.reviewRecord(borrower, false);

        bytes32 replacementHash = keccak256("replacement-record");

        vm.prank(borrower);
        registry.submitRecord(replacementHash);

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.PENDING));

        (bytes32 storedHash,,,,) = registry.records(borrower);
        assertEq(storedHash, replacementHash);
    }

    // ─────────────────────────────────────────────
    // 6. Approval consumption
    // ─────────────────────────────────────────────

    function testFinancingContractCanConsumeApproval() public {
        _submitAsBorrower();
        _approveAsUnderwriter();

        financingConsumer.consume(registry, borrower);

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.CONSUMED));

        assertFalse(registry.isApproved(borrower));
    }

    function testOnlyConfiguredFinancingContractCanConsumeApproval() public {
        _submitAsBorrower();
        _approveAsUnderwriter();

        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("Only financing contract"));

        registry.consumeApproval(borrower);
    }

    function testConsumedApprovalCannotBeConsumedAgain() public {
        _submitAsBorrower();
        _approveAsUnderwriter();

        financingConsumer.consume(registry, borrower);

        vm.expectRevert(bytes("Underwriting not approved"));

        financingConsumer.consume(registry, borrower);
    }

    // ─────────────────────────────────────────────
    // 7. New application after consumption
    // ─────────────────────────────────────────────

    function testBorrowerCanSubmitAgainAfterApprovalIsConsumed() public {
        _submitAsBorrower();
        _approveAsUnderwriter();

        financingConsumer.consume(registry, borrower);

        bytes32 nextHash = keccak256("next-financing-record");

        vm.prank(borrower);
        registry.submitRecord(nextHash);

        assertEq(uint256(_statusOf(borrower)), uint256(UnderwritingRegistry.Status.PENDING));

        (bytes32 storedHash,,,,) = registry.records(borrower);
        assertEq(storedHash, nextHash);
    }

    // ─────────────────────────────────────────────
    // 8. Invalid input
    // ─────────────────────────────────────────────

    function testCannotSubmitZeroHash() public {
        vm.prank(borrower);
        vm.expectRevert(bytes("Invalid hash"));

        registry.submitRecord(bytes32(0));
    }
}
