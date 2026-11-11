// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { PriceMath } from "src/lib/PriceMath.sol";
import { PendlePtPriceOracle } from "src/PendlePtPriceOracle.sol";
import { IPendleStandardizedYield, IPendleYieldToken } from "src/interfaces/IPendle.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract PendlePtPriceOracleForkTest is Test {
    using PriceMath for IPriceOracle.Price;

    function test_ethereum_pt_susds_quotes_nominal_in_usds() public {
        vm.skip(!vm.envExists("ETH_RPC_URL"), "ETH_RPC_URL is not set");
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envOr("PENDLE_ETH_FORK_BLOCK", uint256(26_385_207)));
        PendlePtPriceOracle oracle = new PendlePtPriceOracle(0xdC169AbE56461A2E0c034Da431Ac2a3ebf596094, address(0));
        assertEq(oracle.target(), 0xdC035D45d973E3EC169d2276DDab16f1e407384F);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e18), 12e18);
    }

    function test_monad_pt_reusd_handles_small_indices_and_18_decimal_sy() public {
        vm.skip(!vm.envExists("MONAD_RPC_URL"), "MONAD_RPC_URL is not set");
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"), 121_062_601);
        PendlePtPriceOracle oracle = new PendlePtPriceOracle(0xBb0dCdD5f0159C3D51D8BcE7d84F1b9fA390ef09, address(0));
        assertEq(oracle.target(), 0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
        assertEq(IERC20Metadata(oracle.source()).decimals(), 6);
        assertEq(IERC20Metadata(oracle.sy()).decimals(), 18);
        assertEq(IPendleStandardizedYield(oracle.sy()).exchangeRate(), 1_112_612);
        assertEq(IPendleYieldToken(oracle.yt()).pyIndexStored(), 1_112_612);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 12e6);
    }
}
