// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {Id} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";

contract MockAdaptiveCurveIrm {
    address public immutable MORPHO;
    mapping(Id id => int256 rate) public rateAtTarget;

    constructor(address morpho) {
        MORPHO = morpho;
    }

    function setRateAtTarget(bytes32 id, int256 rate) external {
        rateAtTarget[Id.wrap(id)] = rate;
    }
}
