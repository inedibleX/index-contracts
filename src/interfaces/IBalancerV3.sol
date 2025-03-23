// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWeightedPool {
    // In V3, pool is identified by its address directly, not by poolId
    function getPoolTokens() external view returns (address[] memory);
}

interface IAsset {
// solhint-disable-previous-line no-empty-blocks
}

interface IVault {
    function queryAddLiquidity(
        address pool,
        uint256[] memory amountsIn,
        bool fromInternalBalance,
        bytes memory userData
    ) external view returns (uint256);

    function queryRemoveLiquidity(address pool, uint256 bptAmountIn, bool toInternalBalance, bytes memory userData)
        external
        view
        returns (uint256[] memory);

    function addLiquidity(
        address pool,
        uint256[] memory amountsIn,
        uint256 minBptAmountOut,
        bool fromInternalBalance,
        bytes memory userData
    ) external returns (uint256);

    function removeLiquidity(
        address pool,
        uint256 bptAmountIn,
        uint256[] memory minAmountsOut,
        bool toInternalBalance,
        bytes memory userData
    ) external;
}

interface IRouter {
    /**
     * @notice Add arbitrary amounts of tokens to an ERC4626 pool through the buffer.
     * @param pool Address of the liquidity pool
     * @param wrapUnderlying Flags indicating whether the corresponding token should be wrapped or
     * used as a standard ERC20
     * @param exactAmountsIn Exact amounts of underlying/wrapped tokens in, sorted in token registration order
     * @param minBptAmountOut Minimum amount of pool tokens to be received
     * @param wethIsEth If true, incoming ETH will be wrapped to WETH and outgoing WETH will be unwrapped to ETH
     * @param userData Additional (optional) data required for adding liquidity
     * @return bptAmountOut Actual amount of pool tokens received
     */
    function addLiquidityUnbalancedToERC4626Pool(
        address pool,
        bool[] memory wrapUnderlying,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 bptAmountOut);

    /**
     * @notice Remove proportional amounts of tokens from an ERC4626 pool, burning an exact pool token amount.
     * @param pool Address of the liquidity pool
     * @param unwrapWrapped Flags indicating whether the corresponding token should be unwrapped or
     * used as a standard ERC20
     * @param exactBptAmountIn Exact amount of pool tokens provided
     * @param minAmountsOut Minimum amounts of each token, corresponding to `tokensOut`
     * @param wethIsEth If true, incoming ETH will be wrapped to WETH and outgoing WETH will be unwrapped to ETH
     * @param userData Additional (optional) data required for removing liquidity
     * @return tokensOut Actual tokens received
     * @return amountsOut Actual amounts of tokens received
     */
    function removeLiquidityProportionalFromERC4626Pool(
        address pool,
        bool[] memory unwrapWrapped,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (address[] memory tokensOut, uint256[] memory amountsOut);

    /**
     * @notice Queries an `addLiquidityUnbalancedToERC4626Pool` operation without actually executing it.
     * @param pool Address of the liquidity pool
     * @param wrapUnderlying Flags indicating whether the corresponding token should be wrapped or
     * used as a standard ERC20
     * @param exactAmountsIn Exact amounts of underlying/wrapped tokens in, sorted in token registration order
     * @param sender The sender passed to the operation. It can influence results (e.g., with user-dependent hooks)
     * @param userData Additional (optional) data required for the query
     * @return bptAmountOut Expected amount of pool tokens to receive
     */
    function queryAddLiquidityUnbalancedToERC4626Pool(
        address pool,
        bool[] memory wrapUnderlying,
        uint256[] memory exactAmountsIn,
        address sender,
        bytes memory userData
    ) external returns (uint256 bptAmountOut);

    /**
     * @notice Queries a `removeLiquidityProportionalFromERC4626Pool` operation without actually executing it.
     * @param pool Address of the liquidity pool
     * @param unwrapWrapped Flags indicating whether the corresponding token should be unwrapped or
     * used as a standard ERC20
     * @param exactBptAmountIn Exact amount of pool tokens provided for the query
     * @param sender The sender passed to the operation. It can influence results (e.g., with user-dependent hooks)
     * @param userData Additional (optional) data required for the query
     * @return tokensOut Expected tokens to receive
     * @return amountsOut Expected amounts of tokens to receive
     */
    function queryRemoveLiquidityProportionalFromERC4626Pool(
        address pool,
        bool[] memory unwrapWrapped,
        uint256 exactBptAmountIn,
        address sender,
        bytes memory userData
    ) external returns (address[] memory tokensOut, uint256[] memory amountsOut);
}
