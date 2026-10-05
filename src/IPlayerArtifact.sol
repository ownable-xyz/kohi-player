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

/// @notice One version of the player page: an immutable bundle of HTML
///         template segments and two wasm blobs.
/// @dev The player depends on this interface, not on the concrete contract.
///
///      The bundle has two wasm modules: the render core, and a noise
///      module (LGPL-2.1) that the core imports at instantiation across a
///      shared linear memory. The noise module is never compiled into the
///      render core.
///
///      One artifact binds both blobs. A render core with the wrong noise
///      module renders different art, so the two never change apart: a new
///      version is a new artifact that names both.
interface IPlayerArtifact {
    /// @notice The ordered HTML template segments, one SSTORE2 pointer each.
    ///         The player splices the payloads between them to build the
    ///         page.
    /// @return The SSTORE2 pointers of the template segments, in order.
    function htmlTemplatePointers() external view returns (address[] memory);

    /// @notice The ordered SSTORE2 chunks of the wasm render-core blob.
    /// @return The SSTORE2 pointers of the render core, in order.
    function wasmPointers() external view returns (address[] memory);

    /// @notice The ordered SSTORE2 chunks of the wasm noise module that the
    ///         render core imports.
    /// @return The SSTORE2 pointers of the noise module, in order.
    function noisePointers() external view returns (address[] memory);

    /// @notice keccak256 of the reassembled render-core blob.
    /// @dev The constructor checks it against
    ///      `StreamStore.hashOf(wasmPointers)`. This ties the value to the
    ///      on-chain bytes.
    /// @return The render-core content hash.
    function blobHash() external view returns (bytes32);

    /// @notice keccak256 of the reassembled noise-module blob.
    /// @dev The constructor checks it against
    ///      `StreamStore.hashOf(noisePointers)`.
    /// @return The noise-module content hash.
    function noiseHash() external view returns (bytes32);

    /// @notice One hash that names everything this version serves.
    /// @dev It is keccak256 of the hash of each template segment, in order,
    ///      followed by `blobHash` and `noiseHash`. Each segment has its own
    ///      hash, so the value also pins the segment boundaries. The value
    ///      names exactly one (template, render core, noise module) triple.
    ///      A change to one blob changes the value.
    ///
    ///      It is a verification handle for the repoint timelock window.
    ///      It is not an on-chain admission test: no contract compares it
    ///      to anything. A reviewer derives it again from the build recipe
    ///      while a repoint is pending.
    /// @return The content hash of the version.
    function contentHash() external view returns (bytes32);
}
