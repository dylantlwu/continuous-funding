// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// Chainlink CRE consumer interface, as published in the CRE docs ("Building Consumer Contracts"): the
/// KeystoneForwarder calls onReport after verifying the DON's signatures.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
