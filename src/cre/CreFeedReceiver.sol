// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IReceiver} from "../interfaces/IReceiver.sol";
import {ConsensusFeed} from "../ConsensusFeed.sol";

/// Lets a Chainlink CRE workflow be the relayer of a ConsensusFeed: several independent nodes read the five venues,
/// agree on each value, and the DON-signed report arrives here through Chainlink's forwarder. This contract only
/// checks who delivered it and hands the five values to the feed, which still computes the median and enforces
/// every bound; nothing in the feed is trusted to this contract. The feed's relayer must be set to this address.
contract CreFeedReceiver is IReceiver {
    ConsensusFeed public immutable feed;
    uint8 public immutable market;
    address public owner;
    address public forwarder; // MockKeystoneForwarder while simulating, KeystoneForwarder in production

    event ForwarderChanged(address forwarder);
    event Reported(uint64 observedAt, int256[5] venueRates);

    error NotForwarder(address sender);
    error NotOwner();
    error ZeroAddress();

    constructor(ConsensusFeed feed_, uint8 market_, address forwarder_) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        feed = feed_;
        market = market_;
        owner = msg.sender;
        forwarder = forwarder_;
        emit ForwarderChanged(forwarder_);
    }

    /// The report is abi.encode(uint64 observedAt, int256[5] venueRates), venues in the feed's order. A malformed
    /// report reverts in abi.decode, and a post the feed refuses reverts here too: the forwarder records the failure.
    function onReport(bytes calldata, bytes calldata report) external {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);
        (uint64 observedAt, int256[5] memory venueRates) = abi.decode(report, (uint64, int256[5]));
        feed.post(market, observedAt, venueRates);
        emit Reported(observedAt, venueRates);
    }

    /// Moving from simulation to production changes the forwarder; nothing else can be changed.
    function setForwarder(address forwarder_) external {
        if (msg.sender != owner) revert NotOwner();
        if (forwarder_ == address(0)) revert ZeroAddress();
        forwarder = forwarder_;
        emit ForwarderChanged(forwarder_);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
