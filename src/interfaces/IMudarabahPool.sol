// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMudarabahPool {
    function disburse(address to, uint256 amount) external;
    function addReceivable(uint256 amount) external;
    function reduceReceivable(uint256 amount) external;
    function distributeProfit(uint256 amount) external;
    function recordLoss(uint256 amount) external;
}
