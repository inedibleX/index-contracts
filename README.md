## Foundry IndexFund Project

This project contains the IndexFund contract which facilitates minting and redeeming fund shares by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.

---

## Codebase Overview

The core of this project is the `IndexFund` contract (located in `src/IndexFund.sol`). This contract enables minting and redeeming fund shares using ETH. It swaps ETH for index tokens through Uniswap and then joins a Balancer pool with the acquired tokens. Redemption allows users to exit the Balancer pool and swap the underlying tokens back to ETH.

Other important components include:

- **Testing**: The test suite (`test/IndexFundTest.t.sol`) covers minting and redeeming functionalities and ensures proper interactions with external protocols.
- **Deployment Script**: The deployment script (`script/Deployer.s.sol`) deploys the contract and integrates with external services like Etherscan for contract verification.

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

Ensure that your environment has the variables loaded (see below).

---

## Environment Variables

The deployment and scripts rely on the following environment variables. Refer to the `.env.example` file for details:

- `RPC_URL`: The RPC URL of your Ethereum node (e.g., from Infura or Alchemy).
- `PRIVATE_KEY`: The private key used for deployment.
- `ETHERSCAN_API_KEY`: The Etherscan API key for verifying contracts.

---
