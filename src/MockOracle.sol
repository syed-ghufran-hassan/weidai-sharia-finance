// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./interfaces/IPriceOracle.sol";

contract MockOracle is IPriceOracle {
    uint256 public price = 2000e18;

    function setPrice(uint256 p) external {
        price = p;
    }

    function getPrice() external view override returns (uint256) {
        return price;
    }
}
