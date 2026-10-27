# Deployment

Run commands from the repository root after completing [Getting started](README.md#getting-started).

## Prerequisites

Use an Osaka-compatible network with transient storage support. Prepare loan and collateral token addresses, price feeds, Permit2 and underlying protocol dependencies. Fee-on-transfer loan assets are not supported.

Set the deployment environment using a funded [Foundry keystore](https://getfoundry.sh/reference/cast/wallet/import) whose signer matches `FACTORY_OWNER`. `POOL_OWNER` may be a different address.

```sh
export RPC_URL="<target_network_rpc>"
export KEYSTORE_NAME="<foundry_keystore_name>"
export FACTORY_OWNER="<factory_owner_address>"
export POOL_OWNER="<pool_owner_address>"
export ASSET="<loan_token_address>"
export COLLATERAL="<collateral_token_address>"
export PERMIT2="<permit2_address>"
export PREVIOUS_FACTORY=0x0000000000000000000000000000000000000000
```

Use zero for `PREVIOUS_FACTORY` on the first deployment, or the preceding factory address for later generations. This link serves discovery only; deployment configuration is not inherited.

## 1. Deploy underlying adapters

Deploy the selected adapters before the factory. Implementations must be stateless and immutable; proxies and mutable routers are not supported.

For each `forge create` preflight, omit both `--broadcast` and `--gas-limit 12000000` so RPC gas estimation checks constructor execution.

### Aave V3

```sh
forge create src/adapters/AaveV3Adapter.sol:AaveV3Adapter \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_NAME" \
  --gas-limit 12000000 --broadcast

export AAVE_ADAPTER="<deployed_aave_adapter_address>"
export A_TOKEN="<aave_atoken_for_the_loan_asset>"
export UNDERLYING_POOL_ADAPTER="$AAVE_ADAPTER"
export UNDERLYING_POOL_CONFIG=$(cast abi-encode "config(address)" "$A_TOKEN")
```

Use the aToken for `ASSET`, encoded as a left-padded `bytes32` address.

### Morpho Market V1 with AdaptiveCurveIrm

Deploy one adapter per Morpho singleton and AdaptiveCurveIrm pair:

```sh
export MORPHO="<morpho_singleton_address>"
export ADAPTIVE_CURVE_IRM="<adaptive_curve_irm_address>"

forge create src/adapters/MorphoMarketV1AdaptiveCurveAdapter.sol:MorphoMarketV1AdaptiveCurveAdapter \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_NAME" \
  --gas-limit 12000000 --broadcast \
  --constructor-args "$MORPHO" "$ADAPTIVE_CURVE_IRM"

export MORPHO_ADAPTER="<deployed_morpho_adapter_address>"
export MORPHO_MARKET_ID="<morpho_market_id_bytes32>"
export UNDERLYING_POOL_ADAPTER="$MORPHO_ADAPTER"
export UNDERLYING_POOL_CONFIG="$MORPHO_MARKET_ID"
```

Use an initialized Morpho market with `ASSET` as its loan token and the configured AdaptiveCurveIrm. It must have a permanent deposit of at least **1e9 supply shares** at `0x000000000000000000000000000000000000dEaD`; see [Morpho's dead-deposit guidance](https://docs.morpho.org/curate/tutorials-market-v1/dead-deposit/).

Choose the Aave or Morpho configuration for the pool and list the factory's allowed adapters:

```sh
export UNDERLYING_POOL_ADAPTERS="$UNDERLYING_POOL_ADAPTER"
# If both implementations were deployed, use:
# export UNDERLYING_POOL_ADAPTERS="$AAVE_ADAPTER,$MORPHO_ADAPTER"
```

## 2. Deploy the oracle

The oracle's source is the collateral token and its target is the loan token. Both Chainlink feeds must use the same quote currency and have equal feed decimals.

```sh
export COLLATERAL_FEED="<collateral_price_feed_address>"
export ASSET_FEED="<loan_asset_price_feed_address>"

forge create src/ChainlinkPriceOracle.sol:ChainlinkPriceOracle \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_NAME" \
  --gas-limit 12000000 --broadcast \
  --constructor-args "$COLLATERAL" "$ASSET" "$COLLATERAL_FEED" "$ASSET_FEED"

export ORACLE="<deployed_oracle_address>"
```

Custom oracles must implement [IPriceOracle](src/interfaces/IPriceOracle.sol) with the same pricing direction.

## 3. Deploy and freeze the factory

The [factory script](script/DeployCreditPoolFactory.s.sol) deploys the factory and four shared facets, registers `UNDERLYING_POOL_ADAPTERS` and calls `freezeConfiguration()`. This irreversible freeze is required before pool creation; changing the adapter allowlist or implementation requires a new factory.

First simulate the complete sequence:

```sh
forge script script/DeployCreditPoolFactory.s.sol:DeployCreditPoolFactory \
  --rpc-url "$RPC_URL" --sender "$FACTORY_OWNER" \
  --gas-limit 12000000 -vvvv
```

After checking the simulation, broadcast with the same owner and adapter list:

```sh
forge script script/DeployCreditPoolFactory.s.sol:DeployCreditPoolFactory \
  --rpc-url "$RPC_URL" --sender "$FACTORY_OWNER" \
  --account "$KEYSTORE_NAME" --gas-limit 12000000 \
  --broadcast -vvvv

export FACTORY="<factory_address_printed_by_the_script>"
```

Confirm the deployed configuration:

```sh
cast call "$FACTORY" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$FACTORY" "configurationFrozen()(bool)" --rpc-url "$RPC_URL"
cast call "$FACTORY" "facets()(address[4])" --rpc-url "$RPC_URL"
cast call "$FACTORY" "isUnderlyingPoolAdapterApproved(address)(bool)" \
  "$UNDERLYING_POOL_ADAPTER" --rpc-url "$RPC_URL"
```

The owner must match `FACTORY_OWNER`, the freeze and approval checks must return `true`, and all four facets must be deployed contracts.

## 4. Create a credit pool

The factory owner calls `createPool`; `POOL_OWNER` becomes the owner of the new pool. Select an adapter from the frozen allowlist and use its corresponding `UNDERLYING_POOL_CONFIG`.

The example below uses a **6-decimal loan asset** and **18-decimal collateral**. Replace the example values with the intended pool configuration; token amounts use base units, time values use seconds, and ratios use `1e18 = 100%`.

```sh
export STALE_PRICE_WINDOW=86400
export PROTOCOL_FEE=0
export TOTAL_COLLATERAL_CAP=1000000000000000000000
export PROVIDE_MIN=1000000
export BORROW_MIN=1000000
export MAX_PROVIDE_ORDERS=8
export MAX_BORROW_ORDERS=1
export BORROW_LTV=750000000000000000
export LIQUIDATION_LTV=800000000000000000
export LIQUIDATION_DISCOUNT_MIN=10000000000000000
export LIQUIDATION_DISCOUNT_MAX=50000000000000000
export LIQUIDATION_GRACE_PERIOD=86400
export MIN_DEBT_REMAINING=10000000
export MARKET_DURATIONS='[2592000,2592000,2592000]'
export MARKET_ACTIVE='[3,3,3]'
export MARKET_EXTENSIONS='[0,0,0]'
```

The example sets a 1,000-token collateral cap, 1-token minimum orders, 10-token minimum residual debt, 75% borrow LTV, 80% liquidation LTV and 1%-5% liquidation discounts. `PROTOCOL_FEE` applies to fixed-loan interest; `STALE_PRICE_WINDOW` limits oracle age. The liquidation grace period applies only to maturity-driven liquidation, not unhealthy positions.

The market arrays define duration tiers, active-market counts and early opening extensions; this example exposes three 30-day maturities. Durations and active counts must be positive, successive durations must be nondecreasing multiples, and each extension must be shorter than its duration. The grace period must be shorter than the shortest duration, and `BORROW_LTV <= LIQUIDATION_LTV < 1e18`. See [MarketsConfig](src/lib/MarketsConfig.sol) and the [initialization checks](src/CreditPoolBase.sol) for other configurations.

Encode the parameters in the order defined by [InitializationParams](src/interfaces/ICreditPool.sol):

```sh
CREATE_POOL_SIG='createPool((address,address,address,(address,bytes32),address,address,uint64,uint256,uint128,uint128,uint128,uint8,uint8,uint256,uint256,uint256,uint256,uint64,uint128,(uint64[3],uint8[3],uint64[3])))'
POOL_PARAMS="($POOL_OWNER,$PERMIT2,$ASSET,($UNDERLYING_POOL_ADAPTER,$UNDERLYING_POOL_CONFIG),$ORACLE,$COLLATERAL,$STALE_PRICE_WINDOW,$PROTOCOL_FEE,$TOTAL_COLLATERAL_CAP,$PROVIDE_MIN,$BORROW_MIN,$MAX_PROVIDE_ORDERS,$MAX_BORROW_ORDERS,$BORROW_LTV,$LIQUIDATION_LTV,$LIQUIDATION_DISCOUNT_MIN,$LIQUIDATION_DISCOUNT_MAX,$LIQUIDATION_GRACE_PERIOD,$MIN_DEBT_REMAINING,($MARKET_DURATIONS,$MARKET_ACTIVE,$MARKET_EXTENSIONS))"

# Simulate pool creation without sending a transaction.
cast call "$FACTORY" "$CREATE_POOL_SIG" "$POOL_PARAMS" \
  --from "$FACTORY_OWNER" --rpc-url "$RPC_URL"

# Create the pool after the simulation succeeds.
cast send "$FACTORY" "$CREATE_POOL_SIG" "$POOL_PARAMS" \
  --rpc-url "$RPC_URL" --from "$FACTORY_OWNER" \
  --account "$KEYSTORE_NAME" --gas-limit 12000000
```

Read the pool address from the transaction's `PoolDeployed` event, then check the deployed configuration:

```sh
export POOL="<pool_address_from_PoolDeployed>"

cast call "$FACTORY" "isPool(address)(bool)" "$POOL" --rpc-url "$RPC_URL"
cast call "$POOL" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$POOL" "asset()(address)" --rpc-url "$RPC_URL"
cast call "$POOL" "collateral()(address)" --rpc-url "$RPC_URL"
cast call "$POOL" "priceOracle()(address)" --rpc-url "$RPC_URL"
cast call "$POOL" "underlyingPool()((address,bytes32))" --rpc-url "$RPC_URL"
cast call "$POOL" "getActiveMarkets()(uint64[])" --rpc-url "$RPC_URL"
```

Confirm the returned values match the intended configuration. Integrate using the `CreditPool` ABI at `POOL`.

## 5. Deploy the rollover extension (optional)

Deploy the extension against the factory that created the pools it will serve:

```sh
forge create src/CreditPoolRolloverExtension.sol:CreditPoolRolloverExtension \
  --rpc-url "$RPC_URL" --account "$KEYSTORE_NAME" \
  --gas-limit 12000000 --broadcast \
  --constructor-args "$PERMIT2" "$FACTORY"

export ROLLOVER_EXTENSION="<deployed_rollover_extension_address>"

cast call "$ROLLOVER_EXTENSION" "FACTORY()(address)" --rpc-url "$RPC_URL"
cast call "$ROLLOVER_EXTENSION" "PERMIT2()(address)" --rpc-url "$RPC_URL"
cast call "$ROLLOVER_EXTENSION" "requiredActions()(uint256)" --rpc-url "$RPC_URL"
```

Borrowers opt in by granting `requiredActions()` through the pool's `setDelegate` and setting `setRolloverConfig` for the source maturity, debt-increase limit and keeper fee. Wallet-funded repayment additionally requires token approval to Permit2 and a Permit2 allowance to the extension. Keeper execution depends on these limits, collateral and market liquidity. The extension serves only pools created by its configured `FACTORY`.

<details>
<summary>Local fork deployment</summary>

Start an Ethereum mainnet fork in another terminal:

```sh
export ETH_RPC_URL="<ethereum_archive_rpc>"
anvil --fork-url "$ETH_RPC_URL" --fork-block-number 25071151 \
  --host 127.0.0.1 --port 8545
```

Set `RPC_URL=http://127.0.0.1:8545` and use an Anvil account as `FACTORY_OWNER`. Follow the same deployment sequence, replacing `--account "$KEYSTORE_NAME"` with `--unlocked`. Add `--from "$FACTORY_OWNER"` for `forge create` and `cast send`; retain `--sender "$FACTORY_OWNER"` for `forge script` and `--broadcast` for deployments. The [factory fork test](test/CreditPool/21_factory_script_fork.t.sol) provides dependency addresses and a complete example.

</details>
