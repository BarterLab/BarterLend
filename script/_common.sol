// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Strings } from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";

// underscores every 3 digits from the right
function humanize_gas(uint256 gas) pure returns (string memory) {
    string memory gasStr = Strings.toString(gas);
    bytes memory gasBytes = bytes(gasStr);
    uint256 len = gasBytes.length;

    uint256 underscoreCount = (len - 1) / 3;
    bytes memory result = new bytes(len + underscoreCount);

    uint256 j = 0;
    for (uint256 i = 0; i < len; i++) {
        if (i > 0 && (len - i) % 3 == 0) {
            result[j++] = "_";
        }
        result[j++] = gasBytes[i];
    }

    return string(result);
}
