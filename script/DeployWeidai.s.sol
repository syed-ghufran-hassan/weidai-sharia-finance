// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/MurabahaFinancing.sol";
import "../src/MudarabahPool.sol";
import "../src/MockOracle.sol";
import "../src/UnderwritingRegistry.sol";
import "../test/mocks/ERC20Mock.sol";

contract DeployWeidai is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address underwriter = vm.envOr("UNDERWRITER_ADDRESS", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock financing and collateral tokens.
        ERC20Mock financingToken = new ERC20Mock("Mock USDC", "mUSDC");

        ERC20Mock collateralToken = new ERC20Mock("Mock Collateral", "mCOL");

        // 2. Deploy price oracle.
        MockOracle oracle = new MockOracle();

        // 3. Deploy Mudarabah pool.
        MudarabahPool pool = new MudarabahPool(address(financingToken), deployer);

        // 4. Deploy Murabaha financing.
        MurabahaFinancing murabaha = new MurabahaFinancing(
            address(financingToken), address(collateralToken), address(oracle), address(pool), deployer
        );

        // 5. Deploy underwriting registry.
        UnderwritingRegistry registry = new UnderwritingRegistry(deployer);

        // 6. Configure contract connections.
        pool.setFinancingContract(address(murabaha));

        registry.setFinancingContract(address(murabaha));

        murabaha.setUnderwritingRegistry(address(registry));

        // 7. Grant underwriter permission.
        registry.grantUnderwriter(underwriter);

        vm.stopBroadcast();

        // 8. Print deployed addresses.
        console2.log("=== WEIDAI SHIELD DEPLOYMENT ===");
        console2.log("Deployer:", deployer);
        console2.log("Underwriter:", underwriter);
        console2.log("Financing Token:", address(financingToken));
        console2.log("Collateral Token:", address(collateralToken));
        console2.log("Oracle:", address(oracle));
        console2.log("Mudarabah Pool:", address(pool));
        console2.log("Murabaha Financing:", address(murabaha));
        console2.log("Underwriting Registry:", address(registry));
    }
}
