## Foundry IndexFund Project

This project contains the IndexFund contract which facilitates minting and redeeming fund shares by swapping ETH for a set of index tokens via Uniswap and joining/exiting a Balancer pool.

---

## Foundry

**Foundry** is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat, and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts.
- **Anvil**: Local Ethereum node, akin to Ganache or Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose Solidity REPL.

---

## Documentation

For more details, visit the [Foundry Book](https://book.getfoundry.sh/).

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

Deploy the IndexFund contract with the following command:

```shell
$ forge script script/Deployer.s.sol:DeployIndexFund --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Ensure that your environment has the variables loaded (see below).

---

## Environment Variables

The deployment and scripts rely on the following environment variables. Refer to the `.env.example` file for details:

- `RPC_URL`: The RPC URL of your Ethereum node (e.g., from Infura or Alchemy).
- `PRIVATE_KEY`: The private key used for deployment.
- `ETHERSCAN_API_KEY`: The Etherscan API key for verifying contracts.

---

## Additional Commands

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
