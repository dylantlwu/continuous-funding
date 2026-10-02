// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Testnet-only 6-decimal dollar with an open faucet. Has no value and is not a real stablecoin.
contract TestUSDC is ERC20 {
    uint256 public constant FAUCET_MAX = 100_000e6;

    error OverFaucetMax(uint256 amount);

    constructor() ERC20("Test USDC (no value)", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (amount > FAUCET_MAX) revert OverFaucetMax(amount);
        _mint(to, amount);
    }
}
