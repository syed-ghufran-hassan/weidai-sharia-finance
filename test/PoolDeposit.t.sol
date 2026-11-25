// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MudarabahPool.sol";
import "./mocks/ERC20Mock.sol";

contract PoolDepositTest is Test {
    MudarabahPool pool;
    ERC20Mock usdc;

    address lender = address(0xA11CE);
    address dustDepositor = address(0xBEEF);
    address treasury = address(0x7BE5);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC");
        pool = new MudarabahPool(address(usdc), treasury);

        // Initial lender deposits 1 USDC.
        usdc.mint(lender, 1e18);

        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(1e18);
        vm.stopPrank();
    }

    function test_DustDepositReverts() public {
        usdc.mint(address(pool), 1e18);

        usdc.mint(dustDepositor, 1);

        vm.startPrank(dustDepositor);
        usdc.approve(address(pool), 1);

        vm.expectRevert("Zero shares minted");
        pool.deposit(1);

        vm.stopPrank();

        assertEq(usdc.balanceOf(dustDepositor), 1);
        assertEq(pool.shares(dustDepositor), 0);
    }

    function test_ResidualDustBlocksNextDepositor() public {
        MudarabahPool dustPool = new MudarabahPool(address(usdc), treasury);

        // Lender A deposits 3 wei.
        usdc.mint(lender, 3);

        vm.startPrank(lender);
        usdc.approve(address(dustPool), 3);
        dustPool.deposit(3);
        vm.stopPrank();

        // Direct donation creates rounding dust.
        usdc.mint(address(dustPool), 1);

        // Lender A withdraws all shares.
        uint256 lenderAShares = dustPool.shares(lender);

        vm.prank(lender);
        dustPool.withdraw(lenderAShares);

        assertEq(dustPool.totalShares(), 0);
        assertEq(usdc.balanceOf(address(dustPool)), 1);

        // Lender B attempts to deposit while residual assets remain.
        address lenderB = address(0xBEEF);
        usdc.mint(lenderB, 1);

        vm.startPrank(lenderB);
        usdc.approve(address(dustPool), 1);

        vm.expectRevert(bytes("Residual assets"));
        dustPool.deposit(1);

        vm.stopPrank();

        // Original residual asset remains protected.
        assertEq(dustPool.totalShares(), 0);
        assertEq(usdc.balanceOf(address(dustPool)), 1);
    }
}
