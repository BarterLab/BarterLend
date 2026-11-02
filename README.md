# BarterLend

BarterLend is a non-custodial, overcollateralized fixed-rate, fixed-term lending protocol implemented for the Ethereum Virtual Machine. It features isolated credit markets with fully on-chain interest rate order books, allowing lenders and borrowers to place limit orders at their desired rates or execute market orders against available liquidity. Fixed-rate positions follow a zero-coupon bond model, while the same order book serves both primary debt origination and secondary trading, enabling premature exits from existing positions. Unmatched lending liquidity continues earning variable yield through modular adapters integrating with established lending protocols, improving capital efficiency. BarterLend provides an opt-in, permissionless debt rollover mechanism that allows borrowers to refinance debt from matured markets, protecting their positions against post-maturity liquidations. The protocol also features a flexible delegation system that allows users to grant granular permissions to delegates, opening up room for applications built on top of BarterLend.

## Architecture

| Contracts | Responsibility |
| --- | --- |
| [CreditPoolBase](src/CreditPoolBase.sol) | Core lending pool: manages order books, lender claims, borrower debt, collateral, liquidations and granular user delegation. |
| [CreditPool](src/CreditPool.sol), [CreditPoolFacet1–4](src/facets/) and [Delegator](src/Delegator.sol) | Split the pool's shared logic across four facets similar to [ERC-2535: Diamonds, Multi-Facet Proxy](https://eips.ethereum.org/EIPS/eip-2535). |
| [CreditPoolFactory](src/CreditPoolFactory.sol) | Controls pool deployment. Its configuration must be frozen before pools can be created. |
| [CreditPoolRolloverExtension](src/CreditPoolRolloverExtension.sol) | Provides opt-in permissionless debt refinancing mechanism for matured markets. |
| [AaveV3Adapter](src/adapters/AaveV3Adapter.sol) and [MorphoMarketV1AdaptiveCurveAdapter](src/adapters/MorphoMarketV1AdaptiveCurveAdapter.sol) | Deposit unmatched provide orders liquidity in external protocols and value the positions owned by the credit pool. |
| [ChainlinkPriceOracle](src/ChainlinkPriceOracle.sol) | Converts Chainlink price feeds into a collateral-to-loan-asset price oracle. |

## Getting started

Install [Foundry](https://getfoundry.sh/introduction/installation/):

```sh
foundryup --install v1.5.1
```

Clone the repository with dependencies:

```sh
git clone --recurse-submodules https://github.com/BarterLab/BarterLend.git
```

Build from the repository root:

```sh
forge build
```

## Testing

Run the test suite:

```sh
forge test
```

Mainnet fork tests are skipped when `ETH_RPC_URL` is unset. To include them, use an archive-capable Ethereum RPC endpoint:

```sh
ETH_RPC_URL="<ethereum_archive_rpc>" forge test
```

## Deployment

Deploy the underlying adapters and oracle, run the factory deployment script, then create pools through the frozen factory. The script caches creation code, deploys four shared facets, registers the selected adapters and irreversibly freezes the factory configuration.

Only the factory owner can create pools. Each pool has a separately assigned owner; its implementation facets and underlying adapter configuration remain fixed. A new implementation or adapter allowlist requires a new factory. `PREVIOUS_FACTORY` links factory generations for off-chain discovery, without upgrading existing pools.

See [Deployment](DEPLOYMENT.md) for commands, adapter configuration, pool parameters and the optional rollover extension.

## Licensing

Copyright (c) 2026 BARTERCRAFT PTE. LTD.

BarterLend's core protocol, factory, facets, internal delegator, implementation libraries and rollover implementation are licensed under [Business Source License 1.1](LICENSE.md). They automatically become GPL-2.0-or-later on October 15, 2030, or the earlier date required by BUSL.

Public interfaces, ABI types, protocol constants, delegation masks and the public market configuration declarations are open source and may be used, modified and redistributed under [GPL-2.0-or-later](LICENSE-GPL-2.0). Adapters, the Chainlink oracle, tests, scripts and other original first-party material outside the protected implementation use the same GPL license. The exact boundary is defined in `LICENSE.md`.

Independent applications and extensions may interact with Authorized Deployments under the Additional Use Grant, including creating, configuring and using contracts through authorized factories. Development, testing, auditing and security research in local development environments, blockchain forks or public testnets are non-production use. Before the applicable GPL transition, other production deployments of protected code require written authorization from BARTERCRAFT PTE. LTD. Third-party components retain their own licenses.
