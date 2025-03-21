// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWeightedPoolFactory, IVault} from "./interfaces/IBalancer.sol";

/**
 * @title BalancerWeightedPoolDeployer
 * @notice A contract to deploy Balancer V2 Weighted Pools on Base mainnet
 */
contract BalancerWeightedPoolDeployer {
    IWeightedPoolFactory public immutable factory;
    IVault public immutable vault;

    // Constants
    uint256 private constant ONE = 1e18; // 100% in fixed point 18 decimals
    uint256 private constant MIN_WEIGHT = 0.01e18; // 1% minimum weight
    uint256 private constant MIN_SWAP_FEE = 0.0001e18; // 0.01% minimum swap fee
    uint256 private constant MAX_SWAP_FEE = 0.1e18; // 10% maximum swap fee

    event PoolCreated(
        address indexed pool, string name, string symbol, address[] tokens, uint256[] weights, uint256 swapFee
    );

    /**
     * @notice Constructor
     */
    constructor() {
        factory = IWeightedPoolFactory(0x4C32a8a8fDa4E24139B51b456B42290f51d6A1c4);
        vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    }

    /**
     * @notice Creates a new Balancer Weighted Pool
     * @param name The name of the pool token
     * @param symbol The symbol of the pool token
     * @param tokens Array of token addresses to include in the pool
     * @param weights Array of token weights (must sum to 1e18)
     * @param swapFeePercentage The swap fee percentage (between 0.0001e18 and 0.1e18)
     * @param owner The owner of the pool
     * @param salt Optional unique salt for pool deployment
     * @return pool The address of the newly created pool
     */
    function createWeightedPool(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address pool) {
        // Validate inputs
        require(tokens.length == weights.length, "Tokens and weights arrays must have the same length");
        require(tokens.length >= 2, "Pool must have at least 2 tokens");
        require(tokens.length <= 8, "Pool cannot have more than 8 tokens"); // Standard limit for weighted pools

        // Validate weights
        uint256 weightSum = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            require(weights[i] >= MIN_WEIGHT, "Weight below minimum");
            weightSum += weights[i];
        }
        require(weightSum == ONE, "Weights must sum to 1e18");

        // Validate swap fee
        require(swapFeePercentage >= MIN_SWAP_FEE, "Swap fee below minimum");
        require(swapFeePercentage <= MAX_SWAP_FEE, "Swap fee above maximum");

        // Create rateProviders array (use zero address for each token)
        address[] memory rateProviders = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            rateProviders[i] = address(0);
        }

        // Create the pool
        pool = factory.create(name, symbol, tokens, weights, rateProviders, swapFeePercentage, owner, salt);

        emit PoolCreated(pool, name, symbol, tokens, weights, swapFeePercentage);

        return pool;
    }

    /**
     * @notice Creates a new Balancer Weighted Pool with a default salt
     * @param name The name of the pool token
     * @param symbol The symbol of the pool token
     * @param tokens Array of token addresses to include in the pool
     * @param weights Array of token weights (must sum to 1e18)
     * @param swapFeePercentage The swap fee percentage (between 0.0001e18 and 0.1e18)
     * @param owner The owner of the pool
     * @return pool The address of the newly created pool
     */
    function createWeightedPool(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 swapFeePercentage,
        address owner
    ) external returns (address) {
        // Generate a random salt based on name, symbol and current block values
        bytes32 salt = keccak256(abi.encodePacked(name, symbol, block.timestamp, block.prevrandao));
        return this.createWeightedPool(name, symbol, tokens, weights, swapFeePercentage, owner, salt);
    }
}
