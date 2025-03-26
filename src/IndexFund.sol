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
/// @notice Facilitates minting and redemption of fund shares by swapping ETH for index tokens and joining/exiting a Balancer pool.
/// @dev Interacts with Uniswap V3/V2 for swaps and the Balancer Vault for pool management.
contract IndexFund is ReentrancyGuard, Ownable {
    /// @dev Types of swap pools available.
    enum SwapPoolType {
        None,
        UniV2,
        UniV3OnePercent,
        UniV3PointThreePercent
    }

    // =============================================================
    // State Variables
    // =============================================================

    // Immutable addresses
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

    // Swap configuration constants and parameters
    uint24 public constant DEFAULT_FEE_TIER = 10000; // 1%
    uint24 public constant DIVISOR = 10000;
    uint16 public slippageTolerance = 2000; // 20% default

    /// @notice Fee basis points for mint and redeem fees (default: 50 = 0.5%)
    uint256 public feeBasisPoints = 50;

    // =============================================================
    // Events
    // =============================================================

    /// @notice Emitted when a user mints fund shares.
    event Minted(address indexed user, uint256 ethAmount, uint256 sharesIssued);

    /// @notice Emitted when a user redeems fund shares.
    event Redeemed(address indexed user, uint256 sharesRedeemed, uint256 ethAmount);

    /// @notice Emitted when the slippage tolerance is updated.
    event SlippageToleranceUpdated(uint16 newSlippageTolerance);

    /// @notice Emitted when the fee basis points are updated.
    event FeeUpdated(uint256 newFeeBasisPoints);

    // =============================================================
    // Constructor
    // =============================================================

    /**
     * @notice Initializes the IndexFund contract.
     * @param _wethAddress The address of WETH.
     * @param _uniswapV3Router The Uniswap V3 router address.
     * @param _uniswapV3Factory The Uniswap V3 factory address.
     * @param _uniswapV2Router The Uniswap V2 router address.
     * @param _balancerVault The Balancer Vault address.
     * @param _balancerPoolToken The address of the Balancer pool token.
     * @param _indexTokens The addresses of the index tokens.
     * @param _tokenWeights The weights for the index tokens.
     * @param _swapPoolTypes The pool types for swapping each token.
     */
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
        balancerPoolId = IWeightedPool(_balancerPoolToken).getPoolId();
        // Although getPoolTokens is called, we override indexTokens with _indexTokens.
        (indexTokens,,) = IVault(_balancerVault).getPoolTokens(balancerPoolId);
        balancerPoolToken = _balancerPoolToken;
        indexTokens = _indexTokens;
        tokenWeights = _tokenWeights;

        for (uint256 i = 0; i < _indexTokens.length; i++) {
            _approveTokenForSwaps(_indexTokens[i]);
            swapPoolTypes[_indexTokens[i]] = _swapPoolTypes[i];
        }
    }

    // =============================================================
    // External Functions
    // =============================================================

    /**
     * @notice Mints pool tokens (BPT) by swapping ETH for index tokens and joining the Balancer pool.
     * @dev Deducts a fee, splits the deposit among tokens, performs swaps, and transfers the received BPT to the sender.
     */
    function mint() external payable nonReentrant {
        uint256 feeAmount = (msg.value * feeBasisPoints) / DIVISOR;
        uint256 netDeposit = msg.value - feeAmount;
        uint256 swapAmount = netDeposit / indexTokens.length;
        uint256[] memory maxAmountsIn = new uint256[](indexTokens.length);

        // Execute swaps for each index token
        for (uint256 i = 0; i < indexTokens.length; i++) {
            uint256 estimatedOut = getSwapQuote(wethAddress, indexTokens[i], uint128(swapAmount));
            uint256 minOut = (estimatedOut * (DIVISOR - slippageTolerance)) / DIVISOR;
            maxAmountsIn[i] = executeUniswapSwap(
                wethAddress,
                indexTokens[i],
                uint128(swapAmount),
                uint128(minOut),
                true // is mint operation
            );
        }

        // Prepare assets for joining the Balancer pool
        IAsset[] memory assets = new IAsset[](indexTokens.length);
        for (uint256 i = 0; i < indexTokens.length; i++) {
            assets[i] = IAsset(indexTokens[i]);
        }

        uint256 poolBalanceBefore = IERC20(balancerPoolToken).balanceOf(address(this));
        _joinBalancerPool(assets, maxAmountsIn);
        uint256 poolBalanceAfter = IERC20(balancerPoolToken).balanceOf(address(this));
        uint256 mintedPoolTokens = poolBalanceAfter - poolBalanceBefore;

        require(IERC20(balancerPoolToken).transfer(msg.sender, mintedPoolTokens), "Transfer of BPT failed");

        payable(owner()).transfer(feeAmount);
        emit Minted(msg.sender, netDeposit, mintedPoolTokens);
    }

    /**
     * @notice Redeems pool tokens (BPT) for ETH by exiting the Balancer pool and swapping tokens back to WETH.
     * @param bptAmount The amount of Balancer pool tokens to redeem.
     */
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

        _exitBalancerPool(bptAmount, tokens, minAmountsOut);

        uint256 totalWETHReceived;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenBalance = IERC20(tokens[i]).balanceOf(address(this));
            if (tokenBalance > 0) {
                if (tokens[i] == wethAddress) {
                    totalWETHReceived += tokenBalance;
                } else {
                    uint256 wethFromSwap = executeUniswapSwap(
                        tokens[i],
                        wethAddress,
                        uint128(tokenBalance),
                        0,
                        false // not a mint operation
                    );
                    totalWETHReceived += wethFromSwap;
                }
            }
        }

        uint256 feeOnRedeem = (totalWETHReceived * feeBasisPoints) / DIVISOR;
        uint256 netWETH = totalWETHReceived - feeOnRedeem;

        if (netWETH > 0) {
            IWETH(wethAddress).withdraw(totalWETHReceived);
        }

        (bool success,) = msg.sender.call{value: netWETH}("");
        require(success, "ETH transfer failed");

        payable(owner()).transfer(feeOnRedeem);
        emit Redeemed(msg.sender, bptAmount, netWETH);
    }

    /**
     * @notice Retrieves a quote for swapping tokens.
     * @param tokenIn The input token.
     * @param tokenOut The output token.
     * @param amountIn The input amount.
     * @return The estimated amount of output tokens.
     */
    function getSwapQuote(address tokenIn, address tokenOut, uint128 amountIn) public view returns (uint256) {
        SwapPoolType poolType = swapPoolTypes[tokenOut];
        if (poolType == SwapPoolType.UniV2) {
            return getV2Quote(tokenIn, tokenOut, amountIn);
        }
        address pool = IUniswapV3Factory(uniswapV3Factory).getPool(tokenIn, tokenOut, DEFAULT_FEE_TIER);
        require(pool != address(0), "Pool does not exist.");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        return OracleLibrary.getQuoteAtTick(tick, amountIn, tokenIn, tokenOut);
    }

    // =============================================================
    // Admin Functions
    // =============================================================

    /**
     * @notice Updates the slippage tolerance for swaps.
     * @param newSlippageTolerance The new slippage tolerance.
     */
    function setSlippageTolerance(uint16 newSlippageTolerance) external onlyOwner {
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(newSlippageTolerance);
    }

    /**
     * @notice Updates the fee basis points used for mint and redeem fees.
     * @param newFeeBasisPoints The new fee basis points.
     */
    function setFeeBasisPoints(uint256 newFeeBasisPoints) external onlyOwner {
        feeBasisPoints = newFeeBasisPoints;
        emit FeeUpdated(newFeeBasisPoints);
    }

    /**
     * @notice Updates the swap pool type for a given token.
     * @param token The token address.
     * @param newSwapPoolType The new swap pool type.
     */
    function setSwapPoolType(address token, SwapPoolType newSwapPoolType) external onlyOwner {
        swapPoolTypes[token] = newSwapPoolType;
    }

    // =============================================================
    // Internal Functions - Swaps & Pool Operations
    // =============================================================

    /**
     * @dev Executes a swap using Uniswap V3 or V2 depending on the token's swap pool type.
     * @param tokenIn The token to swap from.
     * @param tokenOut The token to swap to.
     * @param amountIn The input amount.
     * @param amountOutMinimum The minimum acceptable output amount.
     * @param isMintOperation True if the swap is part of a mint operation.
     * @return amountOut The amount of token received.
     */
    function executeUniswapSwap(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool isMintOperation
    ) internal returns (uint256 amountOut) {
        // Determine which pool type to use based on the token
        address tokenForPool = isMintOperation ? tokenOut : tokenIn;
        SwapPoolType poolType = swapPoolTypes[tokenForPool];

        if (poolType == SwapPoolType.UniV2) {
            return executeUniswapV2Swap(tokenIn, tokenOut, amountIn, amountOutMinimum, isMintOperation);
        }

        // Ensure sufficient allowance for Uniswap V3 router
        if (IERC20(tokenIn).allowance(address(this), uniswapV3Router) < amountIn) {
            IERC20(tokenIn).approve(uniswapV3Router, type(uint256).max);
        }

        uint24 fee = (poolType == SwapPoolType.UniV3OnePercent) ? 10000 : 3000;
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = IUniswapV3Router(uniswapV3Router).exactInputSingle{value: isMintOperation ? amountIn : 0}(params);
    }

    /**
     * @dev Executes a swap using the Uniswap V2 router.
     * @param tokenIn The token to swap from.
     * @param tokenOut The token to swap to.
     * @param amountIn The input amount.
     * @param amountOutMinimum The minimum acceptable output amount.
     * @param isMintOperation True if the swap is part of a mint operation.
     * @return amountOut The amount of token received.
     */
    function executeUniswapV2Swap(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool isMintOperation
    ) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256 deadline = block.timestamp + 15 minutes;

        if (isMintOperation) {
            require(tokenIn == wethAddress, "Expected WETH for minting");
            uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).swapExactETHForTokens{value: amountIn}(
                amountOutMinimum, path, address(this), deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else {
            require(tokenOut == wethAddress, "Expected WETH for redeeming");
            if (IERC20(tokenIn).allowance(address(this), uniswapV2Router) < amountIn) {
                IERC20(tokenIn).approve(uniswapV2Router, type(uint256).max);
            }
            uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).swapExactTokensForTokens(
                amountIn, amountOutMinimum, path, address(this), deadline
            );
            amountOut = amounts[amounts.length - 1];
        }
    }

    /**
     * @dev Retrieves a quote using Uniswap V2.
     */
    function getV2Quote(address tokenIn, address tokenOut, uint128 amountIn) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts = IUniswapV2Router(uniswapV2Router).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    /**
     * @dev Joins the Balancer pool with the provided assets and maximum token amounts.
     */
    function _joinBalancerPool(IAsset[] memory assets, uint256[] memory maxAmountsIn) internal {
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

    /**
     * @dev Exits the Balancer pool, redeeming BPT for underlying assets.
     */
    function _exitBalancerPool(uint256 bptToRedeem, address[] memory assets, uint256[] memory minAmountsOut) internal {
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

    /**
     * @dev Approves the necessary routers to spend a given token.
     */
    function _approveTokenForSwaps(address token) internal {
        IERC20(token).approve(uniswapV3Router, type(uint256).max);
        IERC20(token).approve(uniswapV2Router, type(uint256).max);
        IERC20(token).approve(balancerVault, type(uint256).max);
    }

    // =============================================================
    // Fallback / Receive Functions
    // =============================================================

    receive() external payable {}
}
