// SPDX-License-Identifier: MIT
/* Copyright (c) wattsy */
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin/contracts/access/Ownable2Step.sol";

/* =============================================================================
 *  REGISTRYOWNABLE · two-step ownership with renouncing disabled
 * =============================================================================
 *
 * A single-owner access-control base. It adds one safety property to the
 * `Ownable2Step` contract of OpenZeppelin.
 *
 * Ownership changes in two steps. The owner calls `transferOwnership` to
 * nominate a successor. Nothing changes until the nominee calls
 * `acceptOwnership`. A mistyped or unreachable address cannot lock the
 * contract out: the owner stays in control until a working address accepts.
 *
 * Ownership cannot be renounced. `renounceOwnership` always reverts. Plain
 * `Ownable` lets the owner set the owner to the zero address, and then nobody
 * can administer the contract again. Every governance action on a contract
 * that uses this base is one-way or timelocked, so a dropped owner would
 * strand that governance with no path back.
 */
abstract contract RegistryOwnable is Ownable2Step {
    /// Thrown by `renounceOwnership`, always.
    error RenounceDisabled();

    /// @notice Deploys with `initialOwner` as the owner.
    /// @param initialOwner The first owner. The `Ownable` constructor
    ///                     reverts if this is the zero address.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Always reverts with `RenounceDisabled`.
    /// @dev A contract that must stop being administrable freezes its own
    ///      powers through its one-way locks. It does not discard its owner.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
