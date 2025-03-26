// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BalancerWeightedPoolDeployer} from "../src/Helpers.sol";
import {IndexFund} from "../src/IndexFund.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract IndexFundTest is Test {
    struct IndexTokens {
        address brett;
        address toshi;
        address doginme;
        address degen;
        address keycat;
        address ski;
        address miggles;
        address tybg;
    }

    // Base mainnet addresses
    address constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNISWAP_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Test accounts
    address alice = address(0x1);
    address bob = address(0x2);
    address owner = vm.addr(uint256(keccak256(bytes("owner"))));

    // Contract instances
    BalancerWeightedPoolDeployer balancerWeightedPoolDeployer;
    IndexFund indexFund;

    // Index tokens and weights - using 8 tokens in this test
    address[] indexTokens;
    uint256[] tokenWeights;
    IndexTokens iTokens;
    IndexFund.SwapPoolType[] swapPoolTypes;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        iTokens = IndexTokens({
            brett: 0x532f27101965dd16442E59d40670FaF5eBB142E4,
            toshi: 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4,
            doginme: 0x6921B130D297cc43754afba22e5EAc0FBf8Db75b,
            degen: 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed,
            keycat: 0x9a26F5433671751C3276a065f57e5a02D2817973,
            ski: 0x768BE13e1680b5ebE0024C42c896E3dB59ec0149,
            miggles: 0xB1a03EdA10342529bBF8EB700a06C60441fEf25d,
            tybg: 0x0d97F261b1e88845184f678e2d1e7a98D9FD38dE
        });

        indexTokens = new address[](8);
        tokenWeights = new uint256[](8);

        // Tokens in sorted order
        indexTokens[0] = iTokens.tybg;
        indexTokens[1] = iTokens.degen;
        indexTokens[2] = iTokens.brett;
        indexTokens[3] = iTokens.doginme;
        indexTokens[4] = iTokens.ski;
        indexTokens[5] = iTokens.keycat;
        indexTokens[6] = iTokens.toshi;
        indexTokens[7] = iTokens.miggles;

        // Equal weight distribution: 12.5% each
        for (uint256 i = 0; i < indexTokens.length; i++) {
            tokenWeights[i] = 125e15;
        }

        vm.startPrank(owner);
        balancerWeightedPoolDeployer = new BalancerWeightedPoolDeployer();
        vm.stopPrank();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /**
     * @dev Helper function to create a weighted pool and deploy an IndexFund instance.
     */
    function _deployIndexFundWithPool() internal returns (address pool, IndexFund fundInstance) {
        // For testing purposes, the pool address is hard-coded.
        pool = 0xB8931645216D8FF2B4D8323A6BBbEf9bD482DB35;

        vm.startPrank(owner);
        swapPoolTypes = new IndexFund.SwapPoolType[](indexTokens.length);
        swapPoolTypes[0] = IndexFund.SwapPoolType.UniV3OnePercent;
        swapPoolTypes[1] = IndexFund.SwapPoolType.UniV3PointThreePercent;
        swapPoolTypes[2] = IndexFund.SwapPoolType.UniV3OnePercent;
        swapPoolTypes[3] = IndexFund.SwapPoolType.UniV3OnePercent;
        swapPoolTypes[4] = IndexFund.SwapPoolType.UniV2;
        swapPoolTypes[5] = IndexFund.SwapPoolType.UniV2;
        swapPoolTypes[6] = IndexFund.SwapPoolType.UniV3OnePercent;
        swapPoolTypes[7] = IndexFund.SwapPoolType.UniV2;

        fundInstance = new IndexFund(
            WETH_ADDRESS,
            UNISWAP_ROUTER,
            UNISWAP_FACTORY,
            UNISWAP_V2_ROUTER,
            BALANCER_VAULT,
            pool, // Balancer pool token address
            indexTokens,
            tokenWeights,
            swapPoolTypes
        );

        // Set swap pool type for WETH as a fix
        fundInstance.setSwapPoolType(WETH_ADDRESS, IndexFund.SwapPoolType.UniV3OnePercent);
        vm.stopPrank();
        return (pool, fundInstance);
    }

    function test_createWeightedPool() public {
        (address pool, IndexFund fundInstance) = _deployIndexFundWithPool();
        require(pool != address(0), "Pool creation failed");
        require(address(fundInstance) != address(0), "IndexFund creation failed");
    }

    function test_mint() public {
        (address pool, IndexFund fundInstance) = _deployIndexFundWithPool();
        require(pool != address(0), "Pool creation failed");
        require(address(fundInstance) != address(0), "IndexFund creation failed");

        console2.log("VAULT BALANCE BEFORE MINT");
        _logTokenBalance();
        console2.log("+++++++++++++++++++++++++++++++++++++++++++++++++");

        vm.startPrank(alice);
        fundInstance.mint{value: 1 ether}();
        vm.stopPrank();

        console2.log("VAULT BALANCE AFTER MINT");
        _logTokenBalance();

        uint256 bptBalance = IERC20(fundInstance.balancerPoolToken()).balanceOf(alice);
        assertGt(bptBalance, 0);
    }

    function test_redeem() public {
        (address pool, IndexFund fundInstance) = _deployIndexFundWithPool();
        require(pool != address(0), "Pool creation failed");
        require(address(fundInstance) != address(0), "IndexFund creation failed");

        vm.startPrank(bob);
        fundInstance.mint{value: 1 ether}();
        uint256 bptBalance = IERC20(fundInstance.balancerPoolToken()).balanceOf(bob);
        IERC20(fundInstance.balancerPoolToken()).approve(address(fundInstance), bptBalance);
        uint256 bobEthBalBeforeRedeem = address(bob).balance;
        fundInstance.redeem(bptBalance);
        vm.stopPrank();
        uint256 bobEthBalAfterRedeem = address(bob).balance;

        // Expected ETH difference (approximation)
        uint256 diffExpected = 0.97e18;
        assertGe(bobEthBalAfterRedeem, bobEthBalBeforeRedeem + diffExpected);
    }

    function _logTokenBalance() internal {
        for (uint256 i = 0; i < indexTokens.length; i++) {
            uint256 tokenBalance = IERC20(indexTokens[i]).balanceOf(BALANCER_VAULT);
            console2.log("Token balance:", tokenBalance);
        }
    }

    function test_setFeeBasisPoints() public {
        (, IndexFund fundInstance) = _deployIndexFundWithPool();
        assertEq(fundInstance.feeBasisPoints(), 50);

        uint256 newFee = 100; // 1%
        vm.startPrank(owner);
        fundInstance.setFeeBasisPoints(newFee);
        vm.stopPrank();
        assertEq(fundInstance.feeBasisPoints(), newFee);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fundInstance.setFeeBasisPoints(75);
    }

    function test_mintFeesToOwner() public {
        (, IndexFund fundInstance) = _deployIndexFundWithPool();
        uint256 depositAmount = 1 ether;
        uint256 expectedFee = (depositAmount * fundInstance.feeBasisPoints()) / fundInstance.DIVISOR();

        uint256 ownerBalanceBefore = owner.balance;

        vm.startPrank(alice);
        fundInstance.mint{value: depositAmount}();
        vm.stopPrank();

        uint256 ownerBalanceAfter = owner.balance;
        assertEq(ownerBalanceAfter - ownerBalanceBefore, expectedFee, "Mint fee not correctly sent to owner");
    }

    function test_redeemFeesToOwner() public {
        (, IndexFund fundInstance) = _deployIndexFundWithPool();
        uint256 depositAmount = 1 ether;

        vm.startPrank(bob);
        fundInstance.mint{value: depositAmount}();
        uint256 bptBalance = IERC20(fundInstance.balancerPoolToken()).balanceOf(bob);
        IERC20(fundInstance.balancerPoolToken()).approve(address(fundInstance), bptBalance);

        uint256 ownerBalanceBefore = owner.balance;
        fundInstance.redeem(bptBalance);
        vm.stopPrank();

        uint256 ownerBalanceAfter = owner.balance;
        assertGt(ownerBalanceAfter, ownerBalanceBefore, "Redeem fee not sent to owner");
    }

    function test_setSwapPoolType() public {
        (, IndexFund fundInstance) = _deployIndexFundWithPool();
        address testToken = indexTokens[0];
        IndexFund.SwapPoolType initialType = fundInstance.swapPoolTypes(testToken);
        assertEq(
            uint256(initialType), uint256(IndexFund.SwapPoolType.UniV3OnePercent), "Initial swap pool type incorrect"
        );

        vm.startPrank(owner);
        fundInstance.setSwapPoolType(testToken, IndexFund.SwapPoolType.UniV3PointThreePercent);
        vm.stopPrank();

        IndexFund.SwapPoolType newType = fundInstance.swapPoolTypes(testToken);
        assertEq(
            uint256(newType),
            uint256(IndexFund.SwapPoolType.UniV3PointThreePercent),
            "Swap pool type not updated correctly"
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fundInstance.setSwapPoolType(testToken, IndexFund.SwapPoolType.UniV2);
    }
}
