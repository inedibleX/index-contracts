// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/IndexFund.sol";
import {BalancerWeightedPoolDeployer} from "../src/Helpers.sol";

contract DeployIndexFund is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Hardcoded addresses as in the test file
        address WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
        address UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
        address UNISWAP_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
        address BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

        // Set up the index tokens array in sorted order
        address[] memory tokens = new address[](8);
        tokens[0] = 0x0d97F261b1e88845184f678e2d1e7a98D9FD38dE; // tybg
        tokens[1] = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed; // degen
        tokens[2] = 0x532f27101965dd16442E59d40670FaF5eBB142E4; // brett
        tokens[3] = 0x6921B130D297cc43754afba22e5EAc0FBf8Db75b; // doginme
        tokens[4] = 0x768BE13e1680b5ebE0024C42c896E3dB59ec0149; // ski
        tokens[5] = 0x9a26F5433671751C3276a065f57e5a02D2817973; // keycat
        tokens[6] = 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4; // toshi
        tokens[7] = 0xB1a03EdA10342529bBF8EB700a06C60441fEf25d; // miggles

        // All token weights are 12.5% => 125e15 so that the sum equals 1e18.
        uint256[] memory weights = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            weights[i] = 125e15;
        }

        // Swap fee: 0.0001e18
        uint256 swapFee = 0.0001e18;

        // Create a deterministic salt. Using the same salt as in the test.
        bytes32 salt = keccak256(abi.encodePacked("Muse Index", "IMUSE", "test_salt"));

        BalancerWeightedPoolDeployer poolDeployer = new BalancerWeightedPoolDeployer();

        // Create the weighted pool.
        // Note: This pool address will be used as the balancerPoolToken in IndexFund.
        address pool = poolDeployer.createWeightedPool(
            "Muse Index",
            "IMUSE",
            tokens,
            weights,
            swapFee,
            msg.sender, // setting the deployer as the owner of the pool
            salt
        );

        // Deploy the IndexFund contract passing the pool address as the pool token.
        IndexFund fund =
            new IndexFund(WETH_ADDRESS, UNISWAP_ROUTER, UNISWAP_FACTORY, BALANCER_VAULT, pool, tokens, weights);

        console.log("Weighted pool deployed at:", pool);
        console.log("IndexFund deployed at:", address(fund));

        vm.stopBroadcast();
    }
}
