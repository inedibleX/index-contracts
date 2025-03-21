// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BalancerWeightedPoolDeployer} from "../src/Helpers.sol";
import {IndexFund} from "../src/IndexFund.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Test accounts
    address alice = address(0x1);
    address bob = address(0x2);

    // contract instance
    BalancerWeightedPoolDeployer balancerWeightedPoolDeployer;
    IndexFund indexFund;

    // Index tokens and weights - now using only 2 tokens
    address[] indexTokens;
    uint256[] tokenWeights;
    IndexTokens iTokens;

    function setUp() public {
        // Fork Base mainnet with a specific, reliable RPC URL
        vm.createSelectFork("https://mainnet.base.org");

        // Fund test accounts
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

        // tokens in sorted order
        indexTokens[0] = iTokens.tybg; // 0x0d97F261b1e88845184f678e2d1e7a98D9FD38dE
        indexTokens[1] = iTokens.degen; // 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed
        indexTokens[2] = iTokens.brett; // 0x532f27101965dd16442E59d40670FaF5eBB142E4
        indexTokens[3] = iTokens.doginme; // 0x6921B130D297cc43754afba22e5EAc0FBf8Db75b
        indexTokens[4] = iTokens.ski; // 0x768BE13e1680b5ebE0024C42c896E3dB59ec0149
        indexTokens[5] = iTokens.keycat; // 0x9a26F5433671751C3276a065f57e5a02D2817973
        indexTokens[6] = iTokens.toshi; // 0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4
        indexTokens[7] = iTokens.miggles; // 0xB1a03EdA10342529bBF8EB700a06C60441fEf25d

        // Weight distribution: 12.5% each
        tokenWeights[0] = 125e15;
        tokenWeights[1] = 125e15;
        tokenWeights[2] = 125e15;
        tokenWeights[3] = 125e15;
        tokenWeights[4] = 125e15;
        tokenWeights[5] = 125e15;
        tokenWeights[6] = 125e15;
        tokenWeights[7] = 125e15;

        balancerWeightedPoolDeployer = new BalancerWeightedPoolDeployer();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _createWeightedPoolAndIndexFund() internal returns (address pool, IndexFund fundInstance) {
        string memory name = "Muse Index";
        string memory symbol = "IMUSE";
        uint256 swapFee = 0.0001e18;
        // Generate a deterministic salt for testing
        bytes32 salt = keccak256(abi.encodePacked(name, symbol, "test_salt"));

        pool = balancerWeightedPoolDeployer.createWeightedPool(
            name, symbol, indexTokens, tokenWeights, swapFee, address(this), salt
        );

        // Create IndexFund with all required parameters
        fundInstance = new IndexFund(
            WETH_ADDRESS,
            UNISWAP_ROUTER,
            UNISWAP_FACTORY,
            BALANCER_VAULT,
            pool, // This is the balancer pool token
            indexTokens,
            tokenWeights
        );

        return (pool, fundInstance);
    }

    function test_createWeightedPool() public {
        (address pool, IndexFund fundInstance) = _createWeightedPoolAndIndexFund();
        require(pool != address(0), "Pool creation failed");
    }

    function test_mint() public {
        (address pool, IndexFund fundInstance) = _createWeightedPoolAndIndexFund();
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

        assertGt(fundInstance.userShares(alice), 0);
    }

    function test_redeem() public {
        (address pool, IndexFund fundInstance) = _createWeightedPoolAndIndexFund();
        require(pool != address(0), "Pool creation failed");
        require(address(fundInstance) != address(0), "IndexFund creation failed");
        vm.startPrank(bob);
        fundInstance.mint{value: 1 ether}();
        uint256 redeemAmount = fundInstance.userShares(bob);
        uint256 bobEthBalBeforeRedeem = address(bob).balance;
        fundInstance.redeem(redeemAmount);
        vm.stopPrank();
        uint256 bobEthBalAfterRedeem = address(bob).balance;

        uint256 diffExpected = 0.98e18;
        assertGe(bobEthBalAfterRedeem, bobEthBalBeforeRedeem + diffExpected);
    }

    function _logTokenBalance() internal {
        uint256 length = indexTokens.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenBalance = IERC20(indexTokens[i]).balanceOf(BALANCER_VAULT);
            console2.log("Token balance:", tokenBalance);
        }
    }
}
