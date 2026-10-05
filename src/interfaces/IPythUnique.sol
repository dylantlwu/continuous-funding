// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// The one Pyth function this project needs that the pinned SDK (v2.2.0) does not declare. Present on the
/// Monad testnet Pyth contract (checked with eth_call against 0x2880aB15...7B43 on 2026-10-03).
interface IPythUnique {
    /// Returns the price feeds whose update is the FIRST one published at or after `minPublishTime`
    /// (publishTime >= min and prevPublishTime < min), no later than `maxPublishTime`; reverts otherwise.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds);
}
