// SPDX-License-Identifier: Apache-2.0
/* Copyright (c) wattsy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. */
pragma solidity ^0.8.13;

/// @notice The traits-only reader. It is the surface of KVMTraitsRunner, an
///         interpreter fork that reads a token's TRAIT records and draws
///         nothing.
/// @dev The interface is small and standalone. A contract can read traits
///      without importing the interpreter. KVMTraitsRunner enforces
///      the surface (`is IKVMTraitsRunner`).
interface IKVMTraitsRunner {
    /// @notice Read a token's (id, value) TRAIT records and stop when the
    ///         K-th record is written.
    /// @dev KVMTraitsRunner reverts with KVMError on a malformed container
    ///      or a faulting program.
    /// @param program A KVM1 container. KVMRunner.execute runs the same bytes.
    /// @param seed    The int32 run seed.
    /// @param params  Values for the program's PARAM ops. A missing index
    ///                reads 0.
    /// @param K       The piece's declared trait count (0 = run to HALT).
    ///                For K >= the true count, the trait values are
    ///                byte-exact. For a smaller K, the result holds only the
    ///                first K records.
    /// @return The canonical draw stream with all drawing removed: begin,
    ///         any background records, the TRAIT (0x02 | u8 id | i64 value)
    ///         records in order, then end. The 0x02 records are
    ///         byte-identical to those in a full KVMRunner.execute stream
    ///         for the same inputs.
    function traitsOf(bytes calldata program, int32 seed, int64[] calldata params, uint256 K)
        external
        view
        returns (bytes memory);
}
