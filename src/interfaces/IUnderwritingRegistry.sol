// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUnderwritingRegistry {
    function isApproved(address borrower) external view returns (bool);

    function consumeApproval(address borrower) external;
}
