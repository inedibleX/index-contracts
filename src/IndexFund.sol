// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OracleLibrary} from "./lib/external/OracleLibrary.sol";
import {IWeightedPool, IVault, IAsset} from "./interfaces/IBalancer.sol";
import {IUniswapV3Router, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswap.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title IndexFund
/// @notice This contract facilitates the creation and redemption of fund shares
/// by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.
/// @dev The contract interacts with Uniswap V3 for swaps and the Balancer Vault for pool management.
/// Ensure that necessary token approvals are set.
contract IndexFund is ReentrancyGuard, Ownable {
    // Contract state variables
    address public immutable wethAddress;
    address public immutable uniswapRouter;
    address public immutable uniswapFactory;
    address public immutable balancerVault;
    bytes32 public balancerPoolId;
    address public balancerPoolToken;

    // Token configuration
    address[] public indexTokens;
    uint256[] public tokenWeights;

    // Swap configuration
    uint24 public constant DEFAULT_FEE_TIER = 10000; // 1%
    uint24 public constant DIVISOR = 10000;
    uint16 public slippageTolerance = 2000; // 20% default

    // User accounting
    mapping(address => uint256) public userShares;
    uint256 public totalShares;

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

    /// @notice Initializes the IndexFund contract.
    /// @param _wethAddress The address of WETH.
    /// @param _uniswapRouter The Uniswap V3 router address.
    /// @param _uniswapFactory The Uniswap V3 factory address.
    /// @param _balancerVault The Balancer Vault address.
    /// @param _balancerPoolToken The address of the Balancer pool token.
    /// @param _indexTokens The addresses of the index tokens.
    /// @param _tokenWeights The weights for the index tokens.
    constructor(
        address _wethAddress,
        address _uniswapRouter,
        address _uniswapFactory,
        address _balancerVault,
        address _balancerPoolToken,
        address[] memory _indexTokens,
        uint256[] memory _tokenWeights
    ) Ownable(msg.sender) {
        wethAddress = _wethAddress;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;
        balancerVault = _balancerVault;
        // Retrieve the pool ID from the weighted pool contract
        balancerPoolId = IWeightedPool(_balancerPoolToken).getPoolId();
        // Although getPoolTokens is called, we override indexTokens with _indexTokens.
        (indexTokens,,) = IVault(_balancerVault).getPoolTokens(balancerPoolId);
        balancerPoolToken = _balancerPoolToken;
        indexTokens = _indexTokens;
        tokenWeights = _tokenWeights;

        for (uint256 i = 0; i < _indexTokens.length; i++) {
            IERC20(_indexTokens[i]).approve(_uniswapRouter, type(uint256).max);
            IERC20(_indexTokens[i]).approve(_balancerVault, type(uint256).max);
        }
    }

    /// @notice Mints fund shares by swapping ETH for index tokens and joining the Balancer pool.
    /// @dev The ETH deposit is divided equally among the index tokens for swapping.
    /// The pool tokens received determine the shares issued.
    function mint() external payable nonReentrant {
        uint256 totalAmount = msg.value;
        uint256 swapAmount = totalAmount / indexTokens.length;
        uint256[] memory maxAmountsIn = new uint256[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            uint256 amountOut = getQuote(wethAddress, indexTokens[i], uint128(swapAmount));
            uint256 amountOutMinimum = amountOut * (DIVISOR - slippageTolerance) / DIVISOR;
            maxAmountsIn[i] = swapExactInputSingle(
                wethAddress, indexTokens[i], DEFAULT_FEE_TIER, uint128(swapAmount), uint128(amountOutMinimum), true
            );
        }

        IAsset[] memory assets = new IAsset[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            assets[i] = IAsset(indexTokens[i]);
        }

        uint256 poolBalanceBefore = IERC20(balancerPoolToken).balanceOf(address(this));
        joinBalancerPool(assets, maxAmountsIn);
        uint256 poolBalanceAfter = IERC20(balancerPoolToken).balanceOf(address(this));
        uint256 mintedPoolTokens = poolBalanceAfter - poolBalanceBefore;

        uint256 sharesIssued;
        if (totalShares == 0) {
            sharesIssued = mintedPoolTokens;
        } else {
            sharesIssued = mintedPoolTokens * totalShares / poolBalanceBefore;
        }
        totalShares += sharesIssued;
        userShares[msg.sender] += sharesIssued;

        emit Minted(msg.sender, msg.value, sharesIssued);
    }

    /// @notice Swaps an input amount of a token for another token via Uniswap V3.
    /// @dev The function sends ETH only if the swap is initiated during minting.
    /// @param tokenIn The input token address.
    /// @param tokenOut The output token address.
    /// @param fee The Uniswap fee tier.
    /// @param amountIn The amount of tokenIn to swap.
    /// @param amountOutMinimum The minimum amount of tokenOut expected.
    /// @param isMint A flag indicating if the swap is part of the mint process.
    /// @return amountOut The amount of tokenOut received.
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool isMint
    ) internal returns (uint256 amountOut) {
        if (IERC20(tokenIn).allowance(address(this), uniswapRouter) < amountIn) {
            IERC20(tokenIn).approve(uniswapRouter, type(uint256).max);
        }

        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = IUniswapV3Router(uniswapRouter).exactInputSingle{value: isMint ? amountIn : 0}(params);
    }

    /// @notice Retrieves a quote for swapping tokens using the current Uniswap pool tick.
    /// @param tokenIn The input token address.
    /// @param tokenOut The output token address.
    /// @param amountIn The amount of tokenIn.
    /// @return The estimated amount of tokenOut obtainable.
    function getQuote(address tokenIn, address tokenOut, uint128 amountIn) public view returns (uint256) {
        address pool = IUniswapV3Factory(uniswapFactory).getPool(tokenIn, tokenOut, DEFAULT_FEE_TIER);
        require(pool != address(0), "Pool does not exist.");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        return OracleLibrary.getQuoteAtTick(tick, amountIn, tokenIn, tokenOut);
    }

    /// @notice Redeems shares for ETH by exiting the Balancer pool and swapping tokens back to WETH.
    /// @param sharesToRedeem The number of shares to redeem.
    function redeem(uint256 sharesToRedeem) external nonReentrant {
        require(userShares[msg.sender] >= sharesToRedeem, "Insufficient shares.");
        require(totalShares > 0, "No shares exist.");

        uint256 poolBalance = IERC20(balancerPoolToken).balanceOf(address(this));
        uint256 poolTokensToRedeem = (poolBalance * sharesToRedeem) / totalShares;

        userShares[msg.sender] -= sharesToRedeem;
        totalShares -= sharesToRedeem;

        uint256 len = indexTokens.length;
        address[] memory tokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i] = indexTokens[i];
        }
        uint256[] memory minAmountsOut = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            minAmountsOut[i] = 0;
        }

        exitBalancerPool(poolTokensToRedeem, tokens, minAmountsOut);

        uint256 totalWETH;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenBalance = IERC20(tokens[i]).balanceOf(address(this));
            if (tokenBalance > 0) {
                if (tokens[i] == wethAddress) {
                    totalWETH += tokenBalance;
                } else {
                    uint256 wethReceived =
                        swapExactInputSingle(tokens[i], wethAddress, DEFAULT_FEE_TIER, uint128(tokenBalance), 0, false);
                    totalWETH += wethReceived;
                }
            }
        }

        if (totalWETH > 0) {
            IWETH(wethAddress).withdraw(totalWETH);
        }

        (bool success,) = msg.sender.call{value: totalWETH}("");
        require(success, "ETH transfer failed.");

        emit Redeemed(msg.sender, sharesToRedeem, totalWETH);
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

    receive() external payable {}
}
