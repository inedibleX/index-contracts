// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OracleLibrary} from "./lib/external/OracleLibrary.sol";
import {IWeightedPool, IVault, IAsset} from "./interfaces/IBalancer.sol";
import {IUniswapV3Router, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswap.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title IndexFund
/// @notice This contract facilitates the creation and redemption of fund shares
/// by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.
/// @dev The contract interacts with Uniswap V3 for swaps and the Balancer Vault for pool management.
/// Ensure that necessary token approvals are set.
contract IndexFund is ReentrancyGuard, Ownable {
    enum SwapPoolType {
        None,
        UniV2,
        UniV3OnePercent,
        UniV3PointThreePercent
    }

    // Contract state variables

    address public immutable wethAddress;
    address public immutable uniswapV3Router;
    address public immutable uniswapV3Factory;
    address public immutable uniswapV2Router;
    address public immutable balancerVault;
    bytes32 public balancerPoolId;
    address public balancerPoolToken;

    // Token configuration
    address[] public indexTokens;
    uint256[] public tokenWeights;
    mapping(address => SwapPoolType) public swapPoolTypes;

    // Swap configuration
    uint24 public constant DEFAULT_FEE_TIER = 10000; // 1%
    uint24 public constant DIVISOR = 10000;
    uint16 public slippageTolerance = 2000; // 20% default

    /// @notice Fee basis points for mint and redeem fees (default: 50 = 0.5%)
    uint256 public feeBasisPoints = 50;

    // Events
    /// @notice Emitted when a user mints fund shares.
    /// @param user The address of the user.
    /// @param ethAmount The amount of ETH deposited.
    /// @param sharesIssued The number of shares issued.
    event Minted(address indexed user, uint256 ethAmount, uint256 sharesIssued);

    /// @notice Emitted when a user redeems fund shares.
    /// @param user The address of the user.
    /// @param sharesRedeemed The number of shares redeemed.
    /// @param ethAmount The amount of ETH returned.
    event Redeemed(address indexed user, uint256 sharesRedeemed, uint256 ethAmount);

    /// @notice Emitted when the slippage tolerance is updated.
    /// @param newSlippageTolerance The new slippage tolerance value.
    event SlippageToleranceUpdated(uint16 newSlippageTolerance);

    /// @notice Emitted when the fee basis points are updated.
    /// @param newFeeBasisPoints The new fee basis points.
    event FeeUpdated(uint256 newFeeBasisPoints);

    /// @notice Initializes the IndexFund contract.
    /// @param _wethAddress The address of WETH.
    /// @param _uniswapV3Router The Uniswap V3 router address.
    /// @param _uniswapV3Factory The Uniswap V3 factory address.
    /// @param _uniswapV2Router The Uniswap V2 router address.
    /// @param _balancerVault The Balancer Vault address.
    /// @param _balancerPoolToken The address of the Balancer pool token.
    /// @param _indexTokens The addresses of the index tokens.
    /// @param _tokenWeights The weights for the index tokens.
    /// @param _swapPoolTypes The pool types for swapping each token.
    constructor(
        address _wethAddress,
        address _uniswapV3Router,
        address _uniswapV3Factory,
        address _uniswapV2Router,
        address _balancerVault,
        address _balancerPoolToken,
        address[] memory _indexTokens,
        uint256[] memory _tokenWeights,
        SwapPoolType[] memory _swapPoolTypes
    ) Ownable(msg.sender) {
        wethAddress = _wethAddress;
        uniswapV3Router = _uniswapV3Router;
        uniswapV3Factory = _uniswapV3Factory;
        uniswapV2Router = _uniswapV2Router;
        balancerVault = _balancerVault;
        // Retrieve the pool ID from the weighted pool contract
        balancerPoolId = IWeightedPool(_balancerPoolToken).getPoolId();
        // Although getPoolTokens is called, we override indexTokens with _indexTokens.
        (indexTokens,,) = IVault(_balancerVault).getPoolTokens(balancerPoolId);
        balancerPoolToken = _balancerPoolToken;
        indexTokens = _indexTokens;
        tokenWeights = _tokenWeights;

        for (uint256 i = 0; i < _indexTokens.length; i++) {
            IERC20(_indexTokens[i]).approve(_uniswapV3Router, type(uint256).max);
            IERC20(_indexTokens[i]).approve(_uniswapV2Router, type(uint256).max);
            IERC20(_indexTokens[i]).approve(_balancerVault, type(uint256).max);
            swapPoolTypes[_indexTokens[i]] = _swapPoolTypes[i];
        }
    }

    /// @notice Mints pool tokens (BPT) by swapping ETH for index tokens and joining the Balancer pool.
    /// @dev The ETH deposit is subject to a 0.5% fee. The remaining amount is divided equally among the index tokens for swapping. The pool tokens received are transferred directly to the sender.
    function mint() external payable nonReentrant {
        // Calculate fee (0.5% of msg.value)
        uint256 feeAmount = (msg.value * feeBasisPoints) / DIVISOR;
        uint256 netDeposit = msg.value - feeAmount;

        uint256 swapAmount = netDeposit / indexTokens.length;
        uint256[] memory maxAmountsIn = new uint256[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            uint256 amountOut = getQuote(wethAddress, indexTokens[i], uint128(swapAmount));
            uint256 amountOutMinimum = amountOut * (DIVISOR - slippageTolerance) / DIVISOR;
            maxAmountsIn[i] =
                swapExactInputSingle(wethAddress, indexTokens[i], uint128(swapAmount), uint128(amountOutMinimum), true);
        }

        IAsset[] memory assets = new IAsset[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            assets[i] = IAsset(indexTokens[i]);
        }

        uint256 poolBalanceBefore = IERC20(balancerPoolToken).balanceOf(address(this));
        joinBalancerPool(assets, maxAmountsIn);
        uint256 poolBalanceAfter = IERC20(balancerPoolToken).balanceOf(address(this));
        uint256 mintedPoolTokens = poolBalanceAfter - poolBalanceBefore;

        require(IERC20(balancerPoolToken).transfer(msg.sender, mintedPoolTokens), "Transfer of BPT failed");

        payable(owner()).transfer(feeAmount);

        emit Minted(msg.sender, netDeposit, mintedPoolTokens);
    }

    /// @notice Swaps an input amount of a token for another token via Uniswap V3.
    /// @dev The function sends ETH only if the swap is initiated during minting.
    /// @param tokenIn The input token address.
    /// @param tokenOut The output token address.
    /// @param amountIn The amount of tokenIn to swap.
    /// @param amountOutMinimum The minimum amount of tokenOut expected.
    /// @param isMint A flag indicating if the swap is part of the mint process.
    /// @return amountOut The amount of tokenOut received.
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool isMint
    ) internal returns (uint256 amountOut) {
        address token = isMint ? tokenOut : tokenIn;
        SwapPoolType poolType = swapPoolTypes[token];

        // For V2 swaps, use the dedicated V2 swap function
        if (poolType == SwapPoolType.UniV2) {
            return swapTokensV2(tokenIn, tokenOut, amountIn, amountOutMinimum, isMint);
        }

        // Else proceed with V3 swap
        if (IERC20(tokenIn).allowance(address(this), uniswapV3Router) < amountIn) {
            IERC20(tokenIn).approve(uniswapV3Router, type(uint256).max);
        }

        uint24 fee = poolType == SwapPoolType.UniV3OnePercent ? 10000 : 3000;

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = IUniswapV3Router(uniswapV3Router).exactInputSingle{value: isMint ? amountIn : 0}(params);
    }

    /**
     * @notice Swap tokens using the Uniswap V2 Router
     * @dev Used for tokens that have more liquidity in V2 pools
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The amount of input tokens
     * @param amountOutMinimum The minimum expected output amount
     * @param isMint Whether this is a mint operation (ETH → token) or a redeem operation (token → WETH)
     * @return amountOut The amount of output tokens received
     */
    function swapTokensV2(address tokenIn, address tokenOut, uint128 amountIn, uint128 amountOutMinimum, bool isMint)
        internal
        returns (uint256 amountOut)
    {
        // Create the token path for the swap
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Set deadline to a reasonable value in the future
        uint256 deadline = block.timestamp + 15 minutes;

        if (isMint) {
            // Minting: ETH → token
            require(tokenIn == wethAddress, "Expected WETH as input token for minting");

            // No need to approve since we're sending ETH directly
            uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).swapExactETHForTokens{value: amountIn}(
                amountOutMinimum, path, address(this), deadline
            );

            amountOut = amounts[amounts.length - 1];
        } else {
            // Redeeming: token → WETH (not ETH directly)
            require(tokenOut == wethAddress, "Expected WETH as output token for redeeming");

            // Approve the V2 router to spend our tokens
            if (IERC20(tokenIn).allowance(address(this), uniswapV2Router) < amountIn) {
                IERC20(tokenIn).approve(uniswapV2Router, type(uint256).max);
            }

            // Swap tokens for WETH (not directly to ETH)
            uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).swapExactTokensForTokens(
                amountIn, amountOutMinimum, path, address(this), deadline
            );

            amountOut = amounts[amounts.length - 1];
        }
    }

    /**
     * @notice Get a quote for swapping tokens using Uniswap V2
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amountIn The amount of input tokens
     * @return The estimated amount of output tokens
     */
    function getQuoteV2(address tokenIn, address tokenOut, uint128 amountIn) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    /// @notice Retrieves a quote for swapping tokens using the current Uniswap pool tick.
    /// @param tokenIn The input token address.
    /// @param tokenOut The output token address.
    /// @param amountIn The amount of tokenIn.
    /// @return The estimated amount of tokenOut obtainable.
    function getQuote(address tokenIn, address tokenOut, uint128 amountIn) public view returns (uint256) {
        // Check if the token should use V2 swaps
        SwapPoolType poolType = swapPoolTypes[tokenOut];

        if (poolType == SwapPoolType.UniV2) {
            return getQuoteV2(tokenIn, tokenOut, amountIn);
        }

        // Otherwise use V3 quote logic
        address pool = IUniswapV3Factory(uniswapV3Factory).getPool(tokenIn, tokenOut, DEFAULT_FEE_TIER);
        require(pool != address(0), "Pool does not exist.");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        return OracleLibrary.getQuoteAtTick(tick, amountIn, tokenIn, tokenOut);
    }

    /// @notice Redeems pool tokens (BPT) for ETH by exiting the Balancer pool and swapping tokens back to WETH.
    /// @param bptAmount The amount of Balancer pool tokens to redeem.
    function redeem(uint256 bptAmount) external nonReentrant {
        require(IERC20(balancerPoolToken).transferFrom(msg.sender, address(this), bptAmount), "Transfer of BPT failed");

        uint256 len = indexTokens.length;
        address[] memory tokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i] = indexTokens[i];
        }
        uint256[] memory minAmountsOut = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            minAmountsOut[i] = 0;
        }

        exitBalancerPool(bptAmount, tokens, minAmountsOut);

        uint256 totalWETH;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenBalance = IERC20(tokens[i]).balanceOf(address(this));
            if (tokenBalance > 0) {
                if (tokens[i] == wethAddress) {
                    totalWETH += tokenBalance;
                } else {
                    uint256 wethReceived = swapExactInputSingle(tokens[i], wethAddress, uint128(tokenBalance), 0, false);
                    totalWETH += wethReceived;
                }
            }
        }

        // Calculate redemption fee (0.5% of totalWETH)
        uint256 feeOnRedeem = (totalWETH * feeBasisPoints) / DIVISOR;
        uint256 netWETH = totalWETH - feeOnRedeem;

        if (netWETH > 0) {
            IWETH(wethAddress).withdraw(totalWETH);
        }

        (bool success,) = msg.sender.call{value: netWETH}("");
        require(success, "ETH transfer failed");

        payable(owner()).transfer(feeOnRedeem);

        emit Redeemed(msg.sender, bptAmount, netWETH);
    }

    /// @notice Joins a Balancer pool with the provided assets and maximum token amounts.
    /// @param assets The array of assets to join the pool with.
    /// @param maxAmountsIn The corresponding maximum amounts for each asset.
    function joinBalancerPool(IAsset[] memory assets, uint256[] memory maxAmountsIn) internal {
        uint256 poolSupply = IERC20(balancerPoolToken).totalSupply();
        bytes memory userData;

        if (poolSupply == 0) {
            userData = abi.encode(0, maxAmountsIn);
        } else {
            uint256 minimumBPT = 0;
            userData = abi.encode(1, maxAmountsIn, minimumBPT);
        }

        IVault(balancerVault).joinPool(
            balancerPoolId,
            address(this),
            address(this),
            IVault.JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: userData,
                fromInternalBalance: false
            })
        );
    }

    /// @notice Exits the Balancer pool by redeeming a specified amount of BPT for underlying assets.
    /// @param bptToRedeem The amount of Balancer pool tokens to redeem.
    /// @param assets The addresses of the assets in the pool.
    /// @param minAmountsOut The minimum amounts expected for each asset.
    function exitBalancerPool(uint256 bptToRedeem, address[] memory assets, uint256[] memory minAmountsOut) internal {
        IAsset[] memory iAssets = new IAsset[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            iAssets[i] = IAsset(assets[i]);
        }

        IVault(balancerVault).exitPool(
            balancerPoolId,
            address(this),
            payable(address(this)),
            IVault.ExitPoolRequest({
                assets: iAssets,
                minAmountsOut: minAmountsOut,
                userData: abi.encode(1, bptToRedeem),
                toInternalBalance: false
            })
        );
    }

    /// @notice Updates the slippage tolerance for swaps.
    /// @param newSlippageTolerance The new slippage tolerance value.
    function setSlippageTolerance(uint16 newSlippageTolerance) external onlyOwner {
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(newSlippageTolerance);
    }

    /// @notice Updates the fee basis points used for mint and redeem fees.
    /// @param newFeeBasisPoints The new fee basis points (e.g. 50 for 0.5%).
    function setFeeBasisPoints(uint256 newFeeBasisPoints) external onlyOwner {
        feeBasisPoints = newFeeBasisPoints;
        emit FeeUpdated(newFeeBasisPoints);
    }

    function setSwapPoolType(address token, SwapPoolType newSwapPoolType) external onlyOwner {
        swapPoolTypes[token] = newSwapPoolType;
    }

    receive() external payable {}
}
