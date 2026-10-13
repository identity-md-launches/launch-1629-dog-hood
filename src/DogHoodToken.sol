// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Dog hood (DOG)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer. There is no owner, no minter, no pause, no blocklist and no fee: every balance is
/// moved only by its holder (or an approved spender) through the standard ERC-20 functions.
/// @dev The deployer is the launch factory, which pays the supply out (swarm share, pool seed,
/// requester remainder). Nothing here can mint again and there is no burn function, and ERC-20
/// refuses transfers to the zero address, so `totalSupply()` is constant for the token's life.
contract DogHoodToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Dog hood";

    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "DOG";

    /// @notice Decimals returned by `decimals()`.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** TOKEN_DECIMALS;

    /// @notice Mints the whole supply to the deployer (`msg.sender`).
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
