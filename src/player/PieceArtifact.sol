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

import "../SSTORE2.sol";
import "../StreamStore.sol";
import "../IPlayerArtifact.sol";

/* =============================================================================
 *  PIECEARTIFACT · one immutable version of the piece player's page and wasm
 * =============================================================================
 *
 * PiecePlayer builds a player page for each token. The page needs a fixed set
 * of parts. PieceArtifact stores the addresses of those parts, so that one
 * version of the page is one contract at one address. The parts are:
 *  - the HTML template, as 7 ordered template segments (SSTORE2 contracts);
 *  - the wasm render core, as an ordered set of SSTORE2 chunks;
 *  - the wasm noise module, as a second ordered set of SSTORE2 chunks;
 *  - the keccak256 hash of each wasm blob.
 *
 * A segment is one piece of the HTML template. A chunk is one SSTORE2
 * contract that holds a slice of a wasm module. A blob is a whole wasm
 * module, that is, all the chunks of one set in order.
 *
 * WHAT THIS CONTRACT IS FOR. The page is a viewer. The artwork is the
 * program of a piece plus the seed of a token. The piece names its own
 * render path (IKohiPiece.kohiRenderPath). No version of this contract can
 * change a pixel of any artwork.
 *
 * THE TEMPLATE. The page is the 7 segments with 6 payloads between them:
 *
 *   segment 0  base64(render core)  segment 1  base64(noise module)
 *   segment 2  base64(program)      segment 3  seed (decimal)
 *   segment 4  params               segment 5  family (decimal)   segment 6
 *
 * THE NOISE MODULE. The render core imports the noise module when the page
 * loads. The noise module derives from the noise function of p5.js. It is
 * licensed under the GNU Lesser General Public License 2.1
 * (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). It is a
 * separate module. It is never compiled into the render core. The noise
 * instruction of the render core draws with it, so the two blobs are one
 * unit. This contract binds both blobs, and one content hash covers both.
 *
 * IMMUTABLE, NO OWNER. The constructor sets every field once. The contract
 * has no setter and no owner. A new version is a new deployment.
 *
 * WHAT THE CONSTRUCTOR CHECKS. The constructor refuses a manifest that
 * cannot serve a working page:
 *  - the template has exactly 7 segments;
 *  - neither chunk set is empty;
 *  - the chunks of each set, read in order, hash to the declared keccak256.
 * The constructor does not read the template segments. The content hash
 * (below) lets a reader check them.
 *
 * CONTENT HASH. contentHash() returns one number for everything that this
 * version serves:
 *
 *   keccak256( keccak256(segment 0) .. keccak256(segment 6)
 *              blobHash  noiseHash )
 *
 * The hash of each segment is taken separately. This pins the segment
 * boundaries, which are part of the page. Anyone can rebuild both blobs from
 * source, hash them and compare the result.
 */
contract PieceArtifact is IPlayerArtifact {
    /// @notice The number of template segments: 7, around 6 payloads.
    uint256 public constant TEMPLATE_SEGMENTS = 7;

    /// @notice The keccak256 hash of the reassembled render core.
    bytes32 public immutable blobHash;
    /// @notice The keccak256 hash of the reassembled noise module.
    bytes32 public immutable noiseHash;

    // The 7 template segments, in page order.
    address[] internal _htmlTemplatePointers;
    // The render core chunks, in order.
    address[] internal _wasmPointers;
    // The noise module chunks, in order.
    address[] internal _noisePointers;

    /// @notice The render core chunks do not reassemble to blobHash.
    error BadHash();
    /// @notice The noise module chunks do not reassemble to noiseHash.
    error BadNoiseHash();
    /// @notice The template does not have exactly 7 segments.
    error BadTemplate();
    /// @notice A chunk set is empty.
    error EmptyBlob();

    /// @notice Binds one version of the page and its two wasm blobs.
    /// @dev Reverts BadTemplate if the template does not have exactly 7
    ///      segments. Reverts EmptyBlob if a chunk set is empty. Reverts
    ///      BadHash if the render core chunks do not hash to blobHash_.
    ///      Reverts BadNoiseHash if the noise module chunks do not hash to
    ///      noiseHash_.
    /// @param htmlTemplatePointers_ The 7 template segments, in page order.
    /// @param wasmPointers_         The render core chunks, in order.
    /// @param blobHash_             The keccak256 hash of the reassembled render core.
    /// @param noisePointers_        The noise module chunks, in order.
    /// @param noiseHash_            The keccak256 hash of the reassembled noise module.
    constructor(
        address[] memory htmlTemplatePointers_,
        address[] memory wasmPointers_,
        bytes32 blobHash_,
        address[] memory noisePointers_,
        bytes32 noiseHash_
    ) {
        if (htmlTemplatePointers_.length != TEMPLATE_SEGMENTS) revert BadTemplate();
        if (wasmPointers_.length == 0 || noisePointers_.length == 0) revert EmptyBlob();
        if (StreamStore.hashOf(wasmPointers_) != blobHash_) revert BadHash();
        if (StreamStore.hashOf(noisePointers_) != noiseHash_) revert BadNoiseHash();
        for (uint256 i = 0; i < htmlTemplatePointers_.length; i++) _htmlTemplatePointers.push(htmlTemplatePointers_[i]);
        for (uint256 i = 0; i < wasmPointers_.length; i++) _wasmPointers.push(wasmPointers_[i]);
        for (uint256 i = 0; i < noisePointers_.length; i++) _noisePointers.push(noisePointers_[i]);
        blobHash = blobHash_;
        noiseHash = noiseHash_;
    }

    /// @notice Returns the 7 template segments, in page order.
    /// @return The segment pointers.
    function htmlTemplatePointers() external view returns (address[] memory) {
        return _htmlTemplatePointers;
    }

    /// @notice Returns the render core chunks, in order.
    /// @return The chunk pointers.
    function wasmPointers() external view returns (address[] memory) {
        return _wasmPointers;
    }

    /// @notice Returns the noise module chunks, in order.
    /// @return The chunk pointers.
    function noisePointers() external view returns (address[] memory) {
        return _noisePointers;
    }

    /// @notice Returns one hash over every segment and both blobs.
    /// @dev The hash is keccak256 of the keccak256 hash of each segment, in
    ///      page order, followed by blobHash and noiseHash. See the header.
    /// @return The content hash.
    function contentHash() external view returns (bytes32) {
        bytes memory acc;
        for (uint256 i = 0; i < _htmlTemplatePointers.length; i++) {
            acc = abi.encodePacked(acc, keccak256(SSTORE2.read(_htmlTemplatePointers[i])));
        }
        return keccak256(abi.encodePacked(acc, blobHash, noiseHash));
    }
}
