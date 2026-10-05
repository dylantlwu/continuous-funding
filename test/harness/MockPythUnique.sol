// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";

/// MockPyth plus `parsePriceFeedUpdatesUnique` with the real contract's rule: an update is accepted for
/// [min, max] only if publishTime is in range AND prevPublishTime < min, i.e. it is the FIRST print at or
/// after min. Updates carry prevPublishTime after the PriceFeed, so MockPyth.updatePriceFeeds still reads
/// them. Never deployed.
contract MockPythUnique is MockPyth {
    constructor(uint256 validTimePeriod, uint256 fee) MockPyth(validTimePeriod, fee) {}

    function createUpdate(bytes32 id, int64 price, uint64 conf, uint64 publishTime, uint64 prevPublishTime)
        public
        pure
        returns (bytes memory)
    {
        PythStructs.PriceFeed memory f;
        f.id = id;
        f.price = PythStructs.Price(price, conf, -8, publishTime);
        f.emaPrice = f.price;
        return abi.encode(f, prevPublishTime);
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory feeds) {
        if (msg.value < getUpdateFee(updateData)) revert PythErrors.InsufficientFee();
        feeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            bool found;
            for (uint256 j = 0; j < updateData.length && !found; j++) {
                (PythStructs.PriceFeed memory f, uint64 prev) =
                    abi.decode(updateData[j], (PythStructs.PriceFeed, uint64));
                uint256 t = f.price.publishTime;
                if (f.id == priceIds[i] && t >= minPublishTime && t <= maxPublishTime && prev < minPublishTime) {
                    feeds[i] = f;
                    found = true;
                }
            }
            if (!found) revert PythErrors.PriceFeedNotFoundWithinRange();
        }
    }
}
