// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceOracle {
    /// @return Price of 1 collateral unit in financing token (18 decimals)
    function getPrice() external view returns (uint256);
}
