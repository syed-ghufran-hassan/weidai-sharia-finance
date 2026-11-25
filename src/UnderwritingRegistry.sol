// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract UnderwritingRegistry is AccessControl {
    bytes32 public constant UNDERWRITER_ROLE = keccak256("UNDERWRITER_ROLE");

    enum Status {
        NONE,
        PENDING,
        APPROVED,
        REJECTED,
        CONSUMED
    }

    struct Record {
        bytes32 ciphertextHash;
        Status status;
        address reviewer;
        uint64 submittedAt;
        uint64 reviewedAt;
    }

    mapping(address => Record) public records;

    address public financingContract;

    event RecordSubmitted(address indexed borrower, bytes32 ciphertextHash);

    event RecordReviewed(address indexed borrower, address indexed reviewer, Status status);

    event ApprovalConsumed(address indexed borrower);

    event FinancingContractUpdated(address financingContract);

    constructor(address admin) {
        require(admin != address(0), "Invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function grantUnderwriter(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Invalid account");

        _grantRole(UNDERWRITER_ROLE, account);
    }

    function revokeUnderwriter(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(UNDERWRITER_ROLE, account);
    }

    function setFinancingContract(address financing) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(financing != address(0), "Invalid financing");
        require(financing.code.length > 0, "Not a contract");

        financingContract = financing;

        emit FinancingContractUpdated(financing);
    }

    // Borrower submits the hash of their encrypted QoreSeal envelope.
    function submitRecord(bytes32 ciphertextHash) external {
        require(ciphertextHash != bytes32(0), "Invalid hash");

        Status currentStatus = records[msg.sender].status;

        require(
            currentStatus == Status.NONE || currentStatus == Status.REJECTED || currentStatus == Status.CONSUMED,
            "Record already active"
        );

        records[msg.sender] = Record({
            ciphertextHash: ciphertextHash,
            status: Status.PENDING,
            reviewer: address(0),
            submittedAt: uint64(block.timestamp),
            reviewedAt: 0
        });

        emit RecordSubmitted(msg.sender, ciphertextHash);
    }

    // Authorized underwriter approves or rejects the record.
    function reviewRecord(address borrower, bool approved) external onlyRole(UNDERWRITER_ROLE) {
        Record storage record = records[borrower];

        require(record.status == Status.PENDING, "Record not pending");

        record.status = approved ? Status.APPROVED : Status.REJECTED;

        record.reviewer = msg.sender;
        record.reviewedAt = uint64(block.timestamp);

        emit RecordReviewed(borrower, msg.sender, record.status);
    }

    function isApproved(address borrower) external view returns (bool) {
        return records[borrower].status == Status.APPROVED;
    }

    // Only MurabahaFinancing can consume an approval.
    function consumeApproval(address borrower) external {
        require(msg.sender == financingContract, "Only financing contract");

        Record storage record = records[borrower];

        require(record.status == Status.APPROVED, "Underwriting not approved");

        record.status = Status.CONSUMED;

        emit ApprovalConsumed(borrower);
    }
}
