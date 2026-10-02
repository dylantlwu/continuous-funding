// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

/// Returns whatever the test sets, including bad data the engine must reject. Never deployed.
contract MockPriceSource is IPriceSource {
    uint256 public price;
    uint256 public conf;
    uint64 public publishTime;

    function set(uint256 p, uint256 c, uint64 t) external {
        price = p;
        conf = c;
        publishTime = t;
    }

    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function update(bytes[] calldata) external payable returns (uint256, uint256, uint64) {
        return (price, conf, publishTime);
    }
}
