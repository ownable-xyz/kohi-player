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

/* =============================================================================
 *  IKOHIPIECE · the interface of a piece whose artwork is a KVM program
 * =============================================================================
 *
 * THE PROBLEM. A token of generative art is only as durable as the way to
 * rebuild its image. Each collection could answer that question in its own
 * way. A player page, a command-line renderer and a marketplace would then
 * need custom code for each collection. This interface gives one answer for
 * every piece.
 *
 * HOW IT WORKS. A Kohi piece stores its artwork as a program for the KVM, a
 * bytecode virtual machine for generative art. A token is the program plus
 * the seed of that token. A seed is a number that makes one run of the
 * program differ from another. This interface tells a reader where these
 * inputs are and which contracts turn them into the image. Every reader gets
 * the same answers, so every reader renders the same artwork.
 *
 * THE RENDER PATH IS THE PROVENANCE STATEMENT. kohiRenderPath names the
 * contracts that make the image. The interpreter turns (program, params,
 * seed) into a draw stream. The renderer turns the draw stream into pixels.
 * The image of a token is what these contracts compute from these inputs. A
 * player page that shows the image in a browser is a convenience. It is
 * never part of this path.
 *
 * THE TRUST BOUNDARY. Every function is a view over chain state. Nothing
 * points off chain. The interface has no function that writes state. Each
 * implementation states what its owner can change and until when.
 *
 * ERC-165. A piece contract declares support through
 * supportsInterface(type(IKohiPiece).interfaceId), which returns true.
 */

/// @notice The contracts that render a piece, and the inputs that they need.
/// @dev The field order is part of the ABI. Do not change it.
struct KohiRenderPath {
    /// The rasterizer family: 0 GraphicsV1, 1 AGG (hard strokes),
    /// 2 AGG (blended strokes), 3 stamp, 4 mesh, 5 traced mesh.
    uint8 family;
    /// The noise kind the program uses: 0 NoiseV1, 1 GradNoise.
    uint8 noiseKind;
    /// The one-shot interpreter. execute(program, seed, params) returns the
    /// draw stream (the IKVMExec surface).
    address runner;
    /// The stepped interpreter. It runs a program that does not fit in one
    /// call, in chunks, and gives the same draw stream. It is address(0) if
    /// the piece always fits in one call.
    address stepRunner;
    /// The renderer of the family. It turns the draw stream into pixels.
    address renderer;
}

/// @title IKohiPiece
/// @notice The read interface of a piece whose artwork is a KVM program.
/// @dev Every function is a view. An implementation declares the interface
///      through ERC-165.
interface IKohiPiece {
    /// @notice The token does not exist.
    /// @param tokenId The token that was asked for.
    error KohiNoSuchToken(uint256 tokenId);

    /// @notice The KVM container (the program) of the piece.
    /// @dev The bytes are the same for every token. A piece that locks its
    ///      program returns the same bytes forever after the lock.
    /// @return program The container bytes.
    function kohiProgram() external view returns (bytes memory program);

    /// @notice The PARAM slot values that the program reads.
    /// @dev Slot i is params[i]. An empty array means that the program reads
    ///      no slot.
    /// @return params The raw 64-bit slot values.
    function kohiParams() external view returns (int64[] memory params);

    /// @notice The seed of a token.
    /// @dev Reverts KohiNoSuchToken for a token that does not exist.
    /// @param tokenId The token.
    /// @return seed The seed that the interpreter gets.
    function kohiSeed(uint256 tokenId) external view returns (int32 seed);

    /// @notice The contracts that render the piece.
    /// @return path The family, the noise kind, and the addresses of the
    ///         interpreters and the renderer.
    function kohiRenderPath() external view returns (KohiRenderPath memory path);

    /// @notice The display name of a token, for example "Rakel #42".
    /// @dev The text is JSON-safe: it has no quote, backslash or control byte.
    ///      Reverts KohiNoSuchToken for a token that does not exist.
    /// @param tokenId The token.
    /// @return name The name.
    function kohiName(uint256 tokenId) external view returns (string memory name);

    /// @notice The description of the piece.
    /// @dev The text is JSON-safe: it has no quote, backslash or control byte.
    /// @return description The description.
    function kohiDescription() external view returns (string memory description);

    /// @notice The attributes of a token, as a JSON array of
    ///         {"trait_type": ..., "value": ...} objects.
    /// @dev The text is JSON-safe. It is "[]" if the piece has no attributes.
    ///      Reverts KohiNoSuchToken for a token that does not exist.
    /// @param tokenId The token.
    /// @return attributes The JSON array.
    function kohiAttributes(uint256 tokenId) external view returns (string memory attributes);
}
