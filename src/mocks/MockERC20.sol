// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Generic ERC20 mock for testing and deployment scripts. Template fixture.
 * @dev Extends OpenZeppelin ERC20; mint() allows tests and scripts to create supply.
 */
contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    /// @notice Mint tokens to an account (for testing and initial deployment).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
