// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OracleLibrary} from "./lib/external/OracleLibrary.sol";
import {IRouter} from "./interfaces/IBalancerV3.sol";
import {IUniswapV3Router, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswap.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title IndexFund
/// @notice This contract facilitates the creation and redemption of fund shares
/// by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.
/// @dev The contract interacts with Uniswap V3 for swaps and the Balancer V3 for pool management.
/// Ensure that necessary token approvals are set.
contract IndexFund is ReentrancyGuard, Ownable {
    // Contract state variables
    address public immutable wethAddress;
    address public immutable uniswapRouter;
    address public immutable uniswapFactory;
    address public immutable balancerVault;
    address public immutable balancerRouter; // Added Router address
    address public balancerPoolToken; // Now using pool address directly instead of poolId

    // Permit2 address used by Balancer V3 for token approvals
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Token configuration
    address[] public indexTokens;
    uint256[] public tokenWeights;

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
    /// @param _uniswapRouter The Uniswap V3 router address.
    /// @param _uniswapFactory The Uniswap V3 factory address.
    /// @param _balancerVault The Balancer Vault address.
    /// @param _balancerRouter The Balancer Router address.
    /// @param _balancerPoolToken The address of the Balancer pool token.
    /// @param _indexTokens The addresses of the index tokens.
    /// @param _tokenWeights The weights for the index tokens.
    constructor(
        address _wethAddress,
        address _uniswapRouter,
        address _uniswapFactory,
        address _balancerVault,
        address _balancerRouter,
        address _balancerPoolToken,
        address[] memory _indexTokens,
        uint256[] memory _tokenWeights
    ) Ownable(msg.sender) {
        wethAddress = _wethAddress;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;
        balancerVault = _balancerVault;
        balancerRouter = _balancerRouter;
        balancerPoolToken = _balancerPoolToken;
        indexTokens = _indexTokens;
        tokenWeights = _tokenWeights;

        for (uint256 i = 0; i < _indexTokens.length; i++) {
            IERC20(_indexTokens[i]).approve(_uniswapRouter, type(uint256).max);
            IERC20(_indexTokens[i]).approve(_balancerVault, type(uint256).max);
            IERC20(_indexTokens[i]).approve(_balancerRouter, type(uint256).max);
            // Add approval for Permit2
            IERC20(_indexTokens[i]).approve(PERMIT2_ADDRESS, type(uint256).max);
        }
    }

    /// @notice Mints pool tokens (BPT) by swapping ETH for index tokens and joining the Balancer pool.
    /// @dev The ETH deposit is subject to a 0.5% fee. The remaining amount is divided equally among the index tokens for swapping. The pool tokens received are transferred directly to the sender.
    function mint() external payable nonReentrant {
        // Calculate fee (0.5% of msg.value)
        uint256 feeAmount = (msg.value * feeBasisPoints) / DIVISOR;
        uint256 netDeposit = msg.value - feeAmount;

        uint256 swapAmount = netDeposit / indexTokens.length;
        uint256[] memory exactAmountsIn = new uint256[](indexTokens.length);

        for (uint256 i = 0; i < indexTokens.length; i++) {
            uint256 amountOut = getQuote(wethAddress, indexTokens[i], uint128(swapAmount));
            uint256 amountOutMinimum = amountOut * (DIVISOR - slippageTolerance) / DIVISOR;
            exactAmountsIn[i] = swapExactInputSingle(
                wethAddress, indexTokens[i], DEFAULT_FEE_TIER, uint128(swapAmount), uint128(amountOutMinimum), true
            );
        }

        // Create wrapUnderlying flags - false means use as standard ERC20
        bool[] memory wrapUnderlying = new bool[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            wrapUnderlying[i] = false;
        }

        // Add liquidity to the pool via the Router with no minimum output (as requested)
        uint256 bptAmountOut = IRouter(balancerRouter).addLiquidityUnbalancedToERC4626Pool(
            balancerPoolToken,
            wrapUnderlying,
            exactAmountsIn,
            0, // No minimum output as requested
            false, // wethIsEth = false, as we're already dealing with WETH
            "0x" // Empty userData
        );

        require(IERC20(balancerPoolToken).transfer(msg.sender, bptAmountOut), "Transfer of BPT failed");

        payable(owner()).transfer(feeAmount);

        emit Minted(msg.sender, netDeposit, bptAmountOut);
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

    /// @notice Redeems pool tokens (BPT) for ETH by exiting the Balancer pool and swapping tokens back to WETH.
    /// @param bptAmount The amount of Balancer pool tokens to redeem.
    function redeem(uint256 bptAmount) external nonReentrant {
        require(IERC20(balancerPoolToken).transferFrom(msg.sender, address(this), bptAmount), "Transfer of BPT failed");

        uint256 len = indexTokens.length;
        uint256[] memory minAmountsOut = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            minAmountsOut[i] = 0; // No minimum amounts as requested
        }

        // Create unwrapWrapped flags - false means use as standard ERC20
        bool[] memory unwrapWrapped = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            unwrapWrapped[i] = false;
        }

        // Remove liquidity from the pool via the Router
        (, uint256[] memory amountsOut) = IRouter(balancerRouter).removeLiquidityProportionalFromERC4626Pool(
            balancerPoolToken,
            unwrapWrapped,
            bptAmount,
            minAmountsOut,
            false, // wethIsEth = false, we want to receive WETH tokens
            "0x" // Empty userData
        );

        uint256 totalWETH;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenBalance = amountsOut[i];
            if (tokenBalance > 0) {
                if (indexTokens[i] == wethAddress) {
                    totalWETH += tokenBalance;
                } else {
                    uint256 wethReceived = swapExactInputSingle(
                        indexTokens[i], wethAddress, DEFAULT_FEE_TIER, uint128(tokenBalance), 0, false
                    );
                    totalWETH += wethReceived;
                }
            }
        }

        // Calculate redemption fee (0.5% of totalWETH)
        uint256 feeOnRedeem = (totalWETH * feeBasisPoints) / DIVISOR;
        uint256 netWETH = totalWETH - feeOnRedeem;

        if (netWETH > 0) {
            IWETH(wethAddress).withdraw(netWETH);
        }

        (bool success,) = msg.sender.call{value: netWETH}("");
        require(success, "ETH transfer failed");

        payable(owner()).transfer(feeOnRedeem);

        emit Redeemed(msg.sender, bptAmount, netWETH);
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

    receive() external payable {}
}
