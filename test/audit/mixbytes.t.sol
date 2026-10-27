// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";
import { TestCreditPoolFactory } from "test/CreditPool/20_factory.t.sol";
import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolFactory } from "src/CreditPoolFactory.sol";
import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";
import { ICreditPool, ICreditPoolConstants, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolRolloverExtension } from "src/interfaces/ICreditPoolRolloverExtension.sol";
import { IUnderlyingPool, UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockToken } from "test/mocks/MockToken.sol";

/*
### H-01 - Delayed bad-debt recognition lets a lender exit before the write-down

**Reported severity:** High
**Status:** Accepted first-come claim tradeoff; the equal-recovery regression remains skipped.
**Attacker:** A lender; the strongest variant has the lender also act as liquidator, or places the lender and borrower under common control.
**Violated invariant:** An economic loss that has already occurred should be allocated pro rata across all lender shares before `claim`, `offset`, or another burn or exit.

#### Root cause

- [CreditPoolBase._liquidate](../../src/CreditPoolBase.sol#L1635) immediately adds each partial repayment to `loanPool.balance`.
- Bad debt is written down only when the remaining collateral is **exactly zero**.
- Before that write-down, [CreditPoolBase._claim](../../src/CreditPoolBase.sol#L1105) burns shares after maturity at the still-nominal `totalAssets` value and releases the cash already recovered.
- [CreditPoolBase._offset](../../src/CreditPoolBase.sol#L1537) also burns loan exposure against debt at nominal value before a later write-down.
- [CreditPool.multicall](../../src/CreditPool.sol#L488) can combine both partial liquidations and exits in one transaction.

#### Atomic exploit path

1. Two lenders have equal claims of `50`; the borrower owes `100` and has `200` collateral.
2. After maturity, the collateral price falls to `0.25`.
3. The attacker-lender executes one `multicall`:
   `liquidate(25) -> claim(25) -> liquidate(15) -> claim(max) -> withdraw(max)`.
4. The second liquidation exhausts the collateral and only then socializes the remaining `60` of bad debt.
5. The attacker receives all `200` collateral, worth `50`, for a repayment of `40`, plus a lender payout of `30`; the equally exposed passive lender receives `10`.
6. The control scenario without an intermediate exit pays the lenders `20/20`.

The `offset` variant does not require cash available at maturity: the lender transfers the claim to its own healthy debt account and offsets `50` debt before the write-down. If the write-down happens first, the offset covers only `30` and leaves `20` debt. Those `20` are shifted to the honest lender.

#### Feasibility and blast radius

- A flash loan is not required; the atomic path needs `40` asset units of liquidation capital and an existing lender claim of `50`.
- Both liquidation legs are profitable in collateral terms.
- No MEV race with another liquidator is required.
- The blast radius is limited to the market, but a fast lender can concentrate almost all of that market's latent shortfall on the other lenders.

#### Evidence

```shell
forge test --match-path test/audit/mixbytes.t.sol --match-test test_regression_claim_order_cannot_shift_bad_debt_between_equal_lenders -vv
```

The regression [test_regression_claim_order_cannot_shift_bad_debt_between_equal_lenders](mixbytes.t.sol#L78) checks equal `20/20` recovery. It is intentionally skipped because the first-come claim behavior is an accepted tradeoff; this command does not establish a passing equal-recovery guarantee.

#### Proposed remediation from the report

Loss checkpointing would need to precede every lender share exit. A minimal model would:

- mark or freeze the position or market when liquidation or default starts;
- calculate impairment or expected shortfall and update lender NAV before `claim`, `offset`, `reloan`, `transferLoan`, or a refinance-related burn;
- use one settlement snapshot for all exits;
- enforce the invariant that permissionless liquidation, claim, and offset ordering cannot change lenders' pro rata recovery.
*/
contract TestAudit1_h_01_delayed_bad_debt_recognition_allows_lender_exit_before_write_down is CreditPoolTestSuite {
    address internal liquidator = makeAddr("Regression liquidator");

    function test_regression_claim_order_cannot_shift_bad_debt_between_equal_lenders() public {
        // Accepted tradeoff: a lender may claim realized cash before the remaining bad debt is recognized.
        vm.skip(true, "accepted first-come claim tradeoff");

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 50e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 50e18);

        _deposit_collateral(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);
        _withdraw_and_burn(borrower_A, 100e18);

        skip(YEAR);
        priceOracle.setPrice(0.25e18);

        _mint(liquidator, 25e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 25e18, 0, type(uint256).max, "");

        _try_claim_and_withdraw(provider_A, 25e18);

        _mint(liquidator, 15e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 15e18, 0, type(uint256).max, "");

        _try_claim_and_withdraw(provider_A, type(uint128).max);
        _try_claim_and_withdraw(provider_B, type(uint128).max);

        assertEq(asset.balanceOf(provider_A), 20e18);
        assertEq(asset.balanceOf(provider_B), 20e18);
        assertEq(asset.balanceOf(provider_A) + asset.balanceOf(provider_B), 40e18);
    }

    function _try_claim_and_withdraw(address account, uint128 claimAmount) internal {
        _try_call(account, address(pool), abi.encodeCall(ICreditPool.claim, (account, markets[0], claimAmount)));
        _try_call(
            account,
            address(pool),
            abi.encodeCall(ICreditPool.withdraw, (account, account, type(uint128).max))
        );
    }

    function _try_call(address caller, address target, bytes memory data) internal returns (bool success) {
        vm.prank(caller); (success,) = target.call(data);
    }
}

/*
### H-02 - The first `createPool` exceeds the Ethereum mainnet transaction gas cap

**Reported severity:** High / deployment liveness
**Status:** Fixed by deploying facets in separate transactions before pool creation.
**Attacker:** None required; this was a deterministic launch failure.
**Violated invariant:** The documented factory deployment path must be executable on the target network.

[EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) limits a transaction to `16,777,216` gas.

In the reported baseline, the first `createPool()` lazily deployed four facets and the pool in one transaction. The historical gas measurements were:

- first pool: `24,118,410` gas;
- subsequent pool with cached facets: `5,273,138` gas.

`previousFactory` was only an indexer breadcrumb and did not enable facet reuse. The practically unlimited `gas_limit` in [foundry.toml](../../foundry.toml) allowed ordinary tests to hide the issue. The current factory separates [CreditPoolFactory.deployFacet](../../src/CreditPoolFactory.sol#L135), [CreditPoolFactory.freezeConfiguration](../../src/CreditPoolFactory.sol#L100), and [CreditPoolFactory.createPool](../../src/CreditPoolFactory.sol#L148).

#### Evidence

```shell
forge test --match-path test/audit/mixbytes.t.sol --match-test test_regression_first_pool_creation_fits_mainnet_transaction_gas_cap -vv
```

The regression [test_regression_first_pool_creation_fits_mainnet_transaction_gas_cap](mixbytes.t.sol#L160) deploys each facet, freezes the configuration, and creates the first pool through separate calls. Each call receives the execution gas remaining after intrinsic calldata gas is subtracted from the EIP-7825 cap and must succeed.

#### Remediation

- Separate facet deployment and pool deployment into different transactions.
- Alternatively, safely bind predeployed facets to an immutable expected code hash.
- Check the first deployment under the transaction gas cap, including `cast run --enable-tx-gas-limit` when replaying transactions.
- Do not address this by raising the block gas limit: EIP-7825 imposes a separate per-transaction limit.
*/
contract TestAudit1_h_02_first_create_pool_exceeds_ethereum_mainnet_transaction_gas_cap is TestCreditPoolFactory {
    uint256 internal constant OSAKA_TRANSACTION_GAS_LIMIT = 1 << 24;

    function test_regression_first_pool_creation_fits_mainnet_transaction_gas_cap() public {
        _cacheAllCreationCode(factory);

        for (uint8 codeId = 1; codeId <= 4; ++codeId) {
            bytes memory deployFacetCallData = abi.encodeCall(factory.deployFacet, (codeId));
            (bool facetSuccess,) = _callWithTransactionGasLimit(deployFacetCallData);
            assertEq(facetSuccess, true);
        }

        bytes memory freezeCallData = abi.encodeCall(factory.freezeConfiguration, ());
        (bool freezeSuccess,) = _callWithTransactionGasLimit(freezeCallData);
        assertEq(freezeSuccess, true);

        bytes memory createPoolCallData = abi.encodeCall(factory.createPool, (_params()));
        (bool poolSuccess, bytes memory result) = _callWithTransactionGasLimit(createPoolCallData);

        assertEq(poolSuccess, true);

        address deployed = abi.decode(result, (address));
        address[4] memory deployedFacets = factory.facets();
        assertEq(deployed.code.length > 10_000, true);
        assertEq(deployedFacets[0] != address(0), true);
        assertEq(deployedFacets[1] != address(0), true);
        assertEq(deployedFacets[2] != address(0), true);
        assertEq(deployedFacets[3] != address(0), true);
    }

    function _callWithTransactionGasLimit(bytes memory callData)
        internal
        returns (bool success, bytes memory result)
    {
        // EIP-7825 caps the whole transaction, so execution receives the cap minus intrinsic calldata gas.
        uint256 executionGasLimit = OSAKA_TRANSACTION_GAS_LIMIT - _intrinsic_gas(callData);
        vm.prank(factoryOwner); (success, result) = address(factory).call{ gas: executionGasLimit }(callData);
    }

    function _intrinsic_gas(bytes memory callData) internal pure returns (uint256 gasUsed) {
        gasUsed = 21_000;
        for (uint256 i = 0; i < callData.length; ++i) {
            gasUsed += callData[i] == bytes1(0) ? 4 : 16;
        }
    }
}

/*
### H-04 - An arbitrary fake pool steals the rollover extension's fee escrow

**Reported severity:** High / permissionless direct theft
**Status:** Fixed by validating pool provenance and checking exact token receipts.
**Attacker:** Any external user; no owner or keeper role, flash loan, or initial token capital is required.
**Violated invariant:** `_collectedFee[token][recipient]` may increase only by tokens actually received by the extension from a verified CreditPool.

In the reported baseline, `setRolloverConfig` and `rollover` considered a pool valid if its address was nonzero and `code.length > 0`. They did not check factory provenance, a pool registry, runtime code hash, or even `version()`. After an arbitrary `creditPool.withdraw` call, `_withdrawAndCollectFee` credited the nominal fee without measuring the balance delta. The current checks are in [CreditPoolRolloverExtension._requirePool](../../src/CreditPoolRolloverExtension.sol#L323), [CreditPoolRolloverExtension._withdrawAndCollectFee](../../src/CreditPoolRolloverExtension.sol#L312), and [CreditPoolRolloverExtension._requireTokenReceipt](../../src/CreditPoolRolloverExtension.sol#L327).

Atomic exploit path from the report:

1. The extension already holds `10 TOKEN` credited to an honest keeper.
2. The attacker deploys a fake pool that returns the target token from `asset()`, debt `10`, loan `20`, and market balance `10`, while `offset`, `claim`, and `withdraw` do nothing.
3. The attacker enables a configuration for `market = 0` and `keeperFee = 100%`, the allowed maximum.
4. `rollover` treats the debt as covered, calls the fake methods, and credits the attacker `10 TOKEN` even though the extension received no tokens.
5. `withdrawFee` transfers the real `10 TOKEN` to the attacker. The honest keeper's accounting balance remains `10`, but the physical balance is zero.

The blast radius is the entire accumulated, unwithdrawn balance of each ERC-20 in the shared extension escrow, regardless of pool or fee recipient. It does not grant direct access to all CreditPool TVL, which is why the report rated it High rather than Critical. The attack requires only gas and can be repeated for each token balance.

Evidence:

```shell
forge test --match-path test/audit/mixbytes.t.sol --match-test 'test_(regression_fake_pool_cannot_withdraw_unbacked_rollover_fee|fuzz_regression_rollover_fee_never_exceeds_received_assets)' --fuzz-runs 10000 -vv
```

- [test_regression_fake_pool_cannot_withdraw_unbacked_rollover_fee](mixbytes.t.sol#L277)
- [test_fuzz_regression_rollover_fee_never_exceeds_received_assets](mixbytes.t.sol#L286)

Both tests require zero payout to the attacker, preserved escrow, and no unbacked fee liability.

**Remediation:** Bind the extension to an immutable factory or registry with a verifiable pool identity. As defense in depth, compare `asset.balanceOf(address(this))` before and after `creditPool.withdraw`, and credit the fee only when the actual delta equals the expected amount. Preserve `sum(collectedFee[token][*]) <= token.balanceOf(extension)` and the adversarial fake-pool regression.
*/
contract RegressionFakeRolloverPool {
    address internal immutable _asset;
    uint128 internal immutable _debt;

    constructor(address asset_, uint128 debt_) {
        _asset = asset_;
        _debt = debt_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function debtOf(uint64, address) external view returns (uint128) {
        return _debt;
    }

    function loanOf(uint64, address) external view returns (uint128) {
        return _debt * 2;
    }

    function getMarketBalance(uint64) external view returns (uint128) {
        return _debt;
    }

    function balanceOf(address) external pure returns (uint128) {
        return 0;
    }

    function offset(address, uint64, uint128) external pure {}

    function claim(address, uint64, uint128) external pure {}

    function withdraw(address, address, uint128) external pure {}
}

contract TestAudit1_h_04_arbitrary_fake_pool_steals_rollover_extension_fee_escrow is CreditPoolTestSuite {
    address internal honestFunder = makeAddr("Honest escrow funder");
    address internal attacker = makeAddr("Regression attacker");

    function test_regression_fake_pool_cannot_withdraw_unbacked_rollover_fee() public {
        _seed_extension_balance(10e18);
        _attempt_fake_pool_withdrawal(10e18);

        assertEq(asset.balanceOf(attacker), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), attacker), 0);
    }

    function test_fuzz_regression_rollover_fee_never_exceeds_received_assets(uint128 rawForgedFee) public {
        uint128 forgedFee = uint128(bound(rawForgedFee, 1, 10e18));

        _seed_extension_balance(10e18);
        _attempt_fake_pool_withdrawal(forgedFee);

        assertEq(asset.balanceOf(attacker), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), attacker), 0);
    }

    function _seed_extension_balance(uint128 amount) internal {
        vm.prank(honestFunder); asset.mint(amount);
        vm.prank(honestFunder); asset.transfer(address(rolloverExtension), amount);
    }

    function _attempt_fake_pool_withdrawal(uint128 forgedFee) internal {
        RegressionFakeRolloverPool fakePool = new RegressionFakeRolloverPool(address(asset), forgedFee);

        _try_call(
            attacker,
            address(rolloverExtension),
            abi.encodeCall(
                ICreditPoolRolloverExtension.setRolloverConfig,
                (address(fakePool), uint64(0), true, 0, UNIT)
            )
        );

        ICreditPoolRolloverExtension.RolloverSolution memory solution;
        _try_call(
            attacker,
            address(rolloverExtension),
            abi.encodeCall(
                ICreditPoolRolloverExtension.rollover,
                (address(fakePool), uint64(0), attacker, attacker, UNIT, solution)
            )
        );
        _try_call(
            attacker,
            address(rolloverExtension),
            abi.encodeCall(
                ICreditPoolRolloverExtension.withdrawFee,
                (address(asset), attacker, forgedFee)
            )
        );
    }

    function _try_call(address caller, address target, bytes memory data) internal returns (bool success) {
        vm.prank(caller); (success,) = target.call(data);
    }
}

contract ToggleableFeeToken is ERC20 {
    address public immutable CONTROLLER;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable FEE_BPS;

    bool public feeEnabled;

    error UnauthorizedController(address account);

    constructor(address controller, address feeRecipient, uint256 feeBps) ERC20("Toggleable Fee Token", "TFT") {
        CONTROLLER = controller;
        FEE_RECIPIENT = feeRecipient;
        FEE_BPS = feeBps;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setFeeEnabled(bool enabled) external {
        if (msg.sender != CONTROLLER) revert UnauthorizedController(msg.sender);
        feeEnabled = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (!feeEnabled || from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * FEE_BPS / 10_000;
        super._update(from, FEE_RECIPIENT, fee);
        super._update(from, to, amount - fee);
    }
}

contract NoopUnderlyingPoolAdapter is IUnderlyingPool {
    function validate(address, bytes32) external pure override {}

    function totalAssets(address, bytes32) external pure override returns (uint256) {
        return 0;
    }

    function deposit(address, bytes32, uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function withdraw(address, bytes32, uint256, address) external pure override returns (uint256) {
        return 0;
    }
}

abstract contract CH01RegressionBase is Test, ICreditPoolTypes, ICreditPoolConstants {
    uint64 internal constant TERM = 365 days;

    function _deployPool(
        address owner,
        address asset,
        address collateral,
        address adapter,
        bytes32 adapterConfig,
        address priceOracle
    ) internal returns (CreditPool) {
        return new CreditPool(
            _params(owner, asset, collateral, adapter, adapterConfig, priceOracle),
            _facets()
        );
    }

    function _params(
        address owner,
        address asset,
        address collateral,
        address adapter,
        bytes32 adapterConfig,
        address priceOracle
    ) internal pure returns (InitializationParams memory) {
        return InitializationParams({
            owner: owner,
            permit2: address(1),
            asset: asset,
            underlyingPool: UnderlyingPoolConfig({ adapter: adapter, config: adapterConfig }),
            collateral: collateral,
            priceOracle: priceOracle,
            stalePriceWindow: 24 hours,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1,
            borrowOrderMinAmount: 1,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: UNIT * 50 / 100,
            liquidationLTV: UNIT * 50 / 100,
            liquidationDiscountMin: UNIT * 5 / 100,
            liquidationDiscountMax: UNIT * 20 / 100,
            minDebtRemainingAfterLiquidation: 1,
            liquidationGracePeriod: 1 days,
            marketsConfig: MarketsConfigParams({
                durations: [TERM, TERM, TERM],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });
    }

    function _facets() internal returns (address[] memory facets) {
        facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());
    }

    function _try_call(address caller, address target, bytes memory data)
        internal
        returns (bool success, bytes memory result)
    {
        vm.prank(caller); (success, result) = target.call(data);
    }
}

/*
### CH-01 - Nominal asset over-credit for a fee-on-transfer or toggleable token

[CreditPoolBase._deposit](../../src/CreditPoolBase.sol#L470) credits the requested `amount` after `safeTransferFrom` without measuring the balance delta.

PoC: the token controller enables a 50% fee; the attacker deposits `100`, the pool receives `50`, but the internal balance becomes `100`. After disabling the fee, the attacker withdraws `100`, taking `50` of the victim's backing. The victim's `100` claim is then backed by only `50`.

**Prerequisite:** The listed asset charges a fee, burns, or rebases on transfer, or an upgrade or controller can enable that behavior. An ordinary EOA cannot reproduce this exploit with an immutable standard ERC-20. The original report also noted that upgradeable tokens such as USDC require an explicit, monitored assumption about future token behavior.

**Accepted policy:** Fee-on-transfer assets are unsupported; the regression [test_regression_asset_liabilities_never_exceed_received_tokens](mixbytes.t.sol#L476) remains skipped for that reason.

**Proposed remediation:** Credit only `balanceAfter - balanceBefore`; a pool that requires exact accounting should instead revert if the delta differs from the requested amount. Exclude mutable or fee-on-transfer asset behavior through the listing policy.
*/
contract TestAudit1_ch_01_nominal_asset_over_credit_for_fee_on_transfer_token is CH01RegressionBase {
    address internal victim = makeAddr("Regression asset victim");
    address internal attacker = makeAddr("Regression asset attacker");

    function test_regression_asset_liabilities_never_exceed_received_tokens() public {
        vm.skip(true, "FoT are not allowed");
        vm.warp(1);

        ToggleableFeeToken asset = new ToggleableFeeToken(attacker, attacker, 5_000);
        MockToken collateral = new MockToken();
        MockPriceOracle priceOracle = new MockPriceOracle(address(collateral), address(asset));
        NoopUnderlyingPoolAdapter adapter = new NoopUnderlyingPoolAdapter();
        CreditPool pool = _deployPool(
            address(this),
            address(asset),
            address(collateral),
            address(adapter),
            bytes32(0),
            address(priceOracle)
        );

        asset.mint(victim, 100e18);
        vm.prank(victim); asset.approve(address(pool), 100e18);
        vm.prank(victim); pool.deposit(victim, 100e18);

        asset.mint(attacker, 100e18);
        vm.prank(attacker); asset.approve(address(pool), 100e18);
        vm.prank(attacker); asset.setFeeEnabled(true);
        _try_call(attacker, address(pool), abi.encodeCall(ICreditPool.deposit, (attacker, 100e18)));

        uint256 totalLiabilities = uint256(pool.balanceOf(victim)) + pool.balanceOf(attacker);
        assertEq(totalLiabilities <= asset.balanceOf(address(pool)), true);
        assertEq(pool.balanceOf(victim), 100e18);

        vm.prank(attacker); asset.setFeeEnabled(false);
        _try_call(
            attacker,
            address(pool),
            abi.encodeCall(ICreditPool.withdraw, (attacker, attacker, type(uint128).max))
        );
        vm.prank(victim); pool.withdraw(victim, victim, 100e18);

        assertEq(asset.balanceOf(victim), 100e18);
    }
}

/*
### CH-02 - Nominal collateral over-credit creates debt that cannot be liquidated

[CreditPoolBase._depositCollateral](../../src/CreditPoolBase.sol#L1566) also credits the requested amount without measuring the received amount.

PoC:

- nominal credit is `220`, while actual receipt is `55`;
- the borrower withdraws `100` of the lender's asset;
- at a price of `0.9`, liquidation tries to transfer `118.2033096926713948` collateral, but the pool holds only `55` and reverts;
- the debt and lender loan both remain `100`.

**Prerequisite:** Mutable or fee-on-transfer collateral.
**Accepted policy:** Fee-on-transfer collateral is unsupported; the regression [test_regression_collateral_credit_never_exceeds_received_tokens](mixbytes.t.sol#L537) remains skipped for that reason.
**Proposed remediation:** Validate exact token receipts and make the token listing assumptions explicit.
*/
contract TestAudit1_ch_02_nominal_collateral_over_credit_creates_unliquidatable_debt is CH01RegressionBase {
    address internal borrower = makeAddr("Regression collateral borrower");

    function test_regression_collateral_credit_never_exceeds_received_tokens() public {
        vm.skip(true, "FoT are not allowed");
        vm.warp(1);

        MockToken asset = new MockToken();
        ToggleableFeeToken collateral = new ToggleableFeeToken(borrower, borrower, 7_500);
        NoopUnderlyingPoolAdapter adapter = new NoopUnderlyingPoolAdapter();
        MockPriceOracle priceOracle = new MockPriceOracle(address(collateral), address(asset));
        CreditPool pool = _deployPool(
            address(this),
            address(asset),
            address(collateral),
            address(adapter),
            bytes32(0),
            address(priceOracle)
        );
        uint64 market = uint64(block.timestamp + TERM);

        collateral.mint(borrower, 220e18);
        vm.prank(borrower); collateral.approve(address(pool), 220e18);
        vm.prank(borrower); collateral.setFeeEnabled(true);
        _try_call(
            borrower,
            address(pool),
            abi.encodeCall(ICreditPool.depositCollateral, (borrower, market, 220e18))
        );

        assertEq(
            uint256(pool.collateralOf(market, borrower)) <= collateral.balanceOf(address(pool)),
            true
        );
    }
}

contract AdapterBeacon {
    address public immutable OWNER;
    address public implementation;

    error UnauthorizedBeaconOwner(address account);

    constructor(address owner, address initialImplementation) {
        OWNER = owner;
        implementation = initialImplementation;
    }

    function upgradeTo(address newImplementation) external {
        if (msg.sender != OWNER) revert UnauthorizedBeaconOwner(msg.sender);
        implementation = newImplementation;
    }
}

contract BeaconAdapterProxy {
    AdapterBeacon public immutable BEACON;

    constructor(AdapterBeacon beacon) {
        BEACON = beacon;
    }

    fallback() external {
        address implementation = BEACON.implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract BenignAdapterImplementation is IUnderlyingPool {
    function validate(address, bytes32) external pure override {}

    function totalAssets(address, bytes32) external pure override returns (uint256) {
        return 0;
    }

    function deposit(address, bytes32, uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function withdraw(address, bytes32, uint256, address) external pure override returns (uint256) {
        return 0;
    }
}

contract DrainingAdapterImplementation is IUnderlyingPool {
    using SafeERC20 for IERC20;

    address public immutable RECEIVER;

    constructor(address receiver) {
        RECEIVER = receiver;
    }

    function validate(address, bytes32) external pure override {}

    function totalAssets(address, bytes32) external pure override returns (uint256) {
        return 0;
    }

    function deposit(address asset, bytes32, uint256 assets) external override returns (uint256) {
        IERC20 token = IERC20(asset);
        token.safeTransfer(RECEIVER, token.balanceOf(address(this)));
        return assets;
    }

    function withdraw(address, bytes32, uint256, address) external pure override returns (uint256) {
        return 0;
    }
}

abstract contract CH03RegressionBase is CH01RegressionBase {
    uint256 internal constant CHUNK_SIZE = 24_000;

    function _cacheLegitimateCreationCode(CreditPoolFactory factory, address factoryOwner) internal {
        _cacheCreationCode(factory, factoryOwner, 0, type(CreditPool).creationCode);
        _cacheCreationCode(factory, factoryOwner, 1, type(CreditPoolFacet1).creationCode);
        _cacheCreationCode(factory, factoryOwner, 2, type(CreditPoolFacet2).creationCode);
        _cacheCreationCode(factory, factoryOwner, 3, type(CreditPoolFacet3).creationCode);
        _cacheCreationCode(factory, factoryOwner, 4, type(CreditPoolFacet4).creationCode);
    }

    function _deployLegitimateFacets(CreditPoolFactory factory, address factoryOwner) internal {
        for (uint8 codeId = 1; codeId <= 4; ++codeId) {
            vm.prank(factoryOwner); factory.deployFacet(codeId);
        }
    }

    function _cacheCreationCode(
        CreditPoolFactory factory,
        address factoryOwner,
        uint8 codeId,
        bytes memory creationCode
    ) internal {
        vm.prank(factoryOwner); factory.cacheCreationCode(codeId, _chunks(creationCode));
    }

    function _chunks(bytes memory creationCode) internal pure returns (bytes[] memory chunks) {
        uint256 count = (creationCode.length + CHUNK_SIZE - 1) / CHUNK_SIZE;
        chunks = new bytes[](count);

        for (uint256 i = 0; i < count; ++i) {
            uint256 offset = i * CHUNK_SIZE;
            uint256 chunkSize = CHUNK_SIZE;
            if (offset + chunkSize > creationCode.length) chunkSize = creationCode.length - offset;

            bytes memory chunk = new bytes(chunkSize);
            for (uint256 j = 0; j < chunkSize; ++j) {
                chunk[j] = creationCode[offset + j];
            }
            chunks[i] = chunk;
        }
    }
}

/*
### CH-03 - A mutable approved adapter gains full control of storage and custody

In the reported baseline, the factory checked only `code.length` when approving an adapter. The current approval path is [CreditPoolFactory.setUnderlyingPoolAdapter](../../src/CreditPoolFactory.sol#L81), which also records the runtime code hash. Adapter `validate` runs during [CreditPoolBase._initialize](../../src/CreditPoolBase.sol#L250), and state-changing adapter calls use [CreditPoolBase._delegateUnderlyingPool](../../src/CreditPoolBase.sol#L1909). An unchanged proxy runtime hash cannot reveal a change to its implementation.

The PoC approves a benign beacon adapter, after which an independent beacon admin replaces the implementation. The next `placeProvideOrder` for `1` token transfers all `101` idle assets, including the victim's funds, to the attacker.

**Prerequisite:** The factory approved a proxy, beacon, metamorphic adapter, or another mutable code path. The repository's Aave and Morpho adapters use immutable self-checks; the original report did not include final production addresses.

**Proposed remediation:** Allow only immutable implementations; record the runtime hash and proxy or beacon topology at approval and pool creation; exclude independent upgrade admins; revalidate the code hash before launch and monitor it on-chain. If a mutable adapter is part of the intended deployment, the report's severity rises to Critical because the adapter can take over all custody and storage.

**Accepted policy:** The factory remains adapter-agnostic and does not prove the topology of arbitrary adapters. The owner must select immutable adapters before [CreditPoolFactory.freezeConfiguration](../../src/CreditPoolFactory.sol#L100); mutable adapters are unsupported. After the freeze, adapters, facets, and cached deployment code cannot change, and pools cannot be created before the freeze. The regression [test_regression_factory_trust_set_cannot_change_after_freeze](mixbytes.t.sol#L713) checks the freeze, while the regression [test_regression_adapter_upgrade_cannot_drain_pool_custody](mixbytes.t.sol#L762) remains skipped under the immutable-adapter policy.
*/
contract TestAudit1_ch_03_mutable_approved_adapter_gets_full_storage_and_custody_control is CH03RegressionBase {
    address internal factoryOwner = makeAddr("Regression adapter factory owner");
    address internal poolOwner = makeAddr("Regression adapter pool owner");
    address internal victim = makeAddr("Regression adapter victim");
    address internal attacker = makeAddr("Regression adapter attacker");

    function test_regression_factory_trust_set_cannot_change_after_freeze() public {
        vm.warp(1);

        MockToken asset = new MockToken();
        MockToken collateral = new MockToken();
        MockPriceOracle priceOracle = new MockPriceOracle(address(collateral), address(asset));
        BenignAdapterImplementation selectedAdapter = new BenignAdapterImplementation();
        BenignAdapterImplementation benignImplementation = new BenignAdapterImplementation();
        AdapterBeacon beacon = new AdapterBeacon(attacker, address(benignImplementation));
        BeaconAdapterProxy adapterProxy = new BeaconAdapterProxy(beacon);
        CreditPoolFactory factory = new CreditPoolFactory(factoryOwner, address(0));

        _cacheLegitimateCreationCode(factory, factoryOwner);
        _deployLegitimateFacets(factory, factoryOwner);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(selectedAdapter), true);
        vm.prank(factoryOwner); factory.freezeConfiguration();

        InitializationParams memory selectedParams = _params(
            poolOwner,
            address(asset),
            address(collateral),
            address(selectedAdapter),
            bytes32(0),
            address(priceOracle)
        );
        vm.prank(factoryOwner); address deployed = factory.createPool(selectedParams);
        assertEq(factory.isPool(deployed), true);

        vm.expectRevert(CreditPoolFactory.ConfigurationAlreadyFrozen.selector);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(adapterProxy), true);
        assertEq(factory.isUnderlyingPoolAdapterApproved(address(adapterProxy)), false);

        InitializationParams memory proxyParams = _params(
            poolOwner,
            address(asset),
            address(collateral),
            address(adapterProxy),
            bytes32(0),
            address(priceOracle)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditPoolFactory.UnderlyingPoolAdapterNotApproved.selector,
                address(adapterProxy)
            )
        );
        vm.prank(factoryOwner); factory.createPool(proxyParams);
    }

    function test_regression_adapter_upgrade_cannot_drain_pool_custody() public {
        vm.skip(true, "Mutable adapters are not allowed");
        vm.warp(1);

        MockToken asset = new MockToken();
        MockToken collateral = new MockToken();
        MockPriceOracle priceOracle = new MockPriceOracle(address(collateral), address(asset));
        BenignAdapterImplementation benignImplementation = new BenignAdapterImplementation();
        AdapterBeacon beacon = new AdapterBeacon(attacker, address(benignImplementation));
        BeaconAdapterProxy adapterProxy = new BeaconAdapterProxy(beacon);
        CreditPoolFactory factory = new CreditPoolFactory(factoryOwner, address(0));

        _cacheLegitimateCreationCode(factory, factoryOwner);
        (bool approvalSucceeded,) = _try_call(
            factoryOwner,
            address(factory),
            abi.encodeCall(CreditPoolFactory.setUnderlyingPoolAdapter, (address(adapterProxy), true))
        );
        if (!approvalSucceeded) {
            assertEq(factory.isUnderlyingPoolAdapterApproved(address(adapterProxy)), false);
            return;
        }

        _deployLegitimateFacets(factory, factoryOwner);
        InitializationParams memory params = _params(
            poolOwner,
            address(asset),
            address(collateral),
            address(adapterProxy),
            bytes32(0),
            address(priceOracle)
        );
        bytes memory createCall = abi.encodeCall(CreditPoolFactory.createPool, (params));
        (bool deploymentSucceeded, bytes memory result) =
            _try_call(factoryOwner, address(factory), createCall);
        if (!deploymentSucceeded) return;

        CreditPool pool = CreditPool(abi.decode(result, (address)));
        uint64 market = uint64(block.timestamp + TERM);

        vm.prank(victim); asset.mint(100e18);
        vm.prank(victim); asset.approve(address(pool), 100e18);
        vm.prank(victim); pool.deposit(victim, 100e18);

        vm.prank(attacker); asset.mint(1e18);
        vm.prank(attacker); asset.approve(address(pool), 1e18);
        vm.prank(attacker); pool.deposit(attacker, 1e18);

        DrainingAdapterImplementation maliciousImplementation = new DrainingAdapterImplementation(attacker);
        vm.prank(attacker); beacon.upgradeTo(address(maliciousImplementation));
        _try_call(
            attacker,
            address(pool),
            abi.encodeCall(ICreditPool.placeProvideOrder, (attacker, market, 0, 1e18))
        );

        assertEq(asset.balanceOf(attacker), 0);
        assertEq(asset.balanceOf(address(pool)), 101e18);

        vm.prank(victim); pool.withdraw(victim, victim, 100e18);
        assertEq(asset.balanceOf(victim), 100e18);
    }
}
