## Foundry IndexFund Project

This project contains the IndexFund contract which facilitates minting and redeeming fund shares by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.

---

## Codebase Overview

The core of this project is the `IndexFund` contract (located in `src/IndexFund.sol`). This contract enables minting and redeeming fund shares using ETH. It swaps ETH for index tokens through Uniswap (supporting both V2 and V3) and then joins a Balancer pool with the acquired tokens. Redemption allows users to exit the Balancer pool and swap the underlying tokens back to WETH, which is then unwrapped to ETH.

### Key Features

- **Dual Uniswap Integration**: Supports both Uniswap V2 and V3 for optimal liquidity routing
- **Configurable Swap Types**: Each token can be assigned a specific swap pool type:
  - `UniV2`: Uses Uniswap V2 pools for tokens with better liquidity there
  - `UniV3OnePercent`: Uses Uniswap V3 1% fee tier pools
  - `UniV3PointThreePercent`: Uses Uniswap V3 0.3% fee tier pools
- **Dynamic Fee Structure**: Customizable fee basis points for mint and redeem operations
- **Slippage Protection**: Configurable slippage tolerance for swap operations

Other important components include:

- **Interfaces**: Contains interfaces for Balancer, Uniswap V2/V3, and WETH
- **Testing**: The test suite (`test/IndexFundTest.t.sol`) covers minting, redeeming, and swap functionality
- **Deployment Script**: The deployment script (`script/Deployer.s.sol`) deploys the contract with the proper configuration

---

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

For specific tests:

```shell
$ forge test --match-test test_mint
$ forge test --match-test test_redeem
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

---

## Deployment

Before deploying, copy the provided `.env.example` file to `.env` and set the required environment variables.

Deploy the IndexFund contract using the following Makefile command:

```shell
make deploy_index_fund
```

Alternatively, if you want to check the deployment without broadcasting a transaction, run:

```shell
make check_index_fund
```

The deployment script:
1. Uses hardcoded addresses for WETH, Uniswap routers, and Balancer vault
2. Configures swap pool types for each token based on liquidity profiles
3. Sets up token weights (default is even distribution)
4. Uses an existing pool or creates a new one (configurable in the script)
5. Deploys the IndexFund with the specified parameters

Ensure that your environment has the variables loaded (see below).

---

## Environment Variables

The deployment and scripts rely on the following environment variables. Refer to the `.env.example` file for details:

- `RPC_URL`: The RPC URL of your Base 
- `PRIVATE_KEY`: The private key used for deployment.
- `ETHERSCAN_API_KEY`: The Etherscan API key for verifying contracts(BASE SCAN).

---
