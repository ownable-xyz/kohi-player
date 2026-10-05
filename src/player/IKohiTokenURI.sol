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

import {IKohiPiece} from "./IKohiPiece.sol";

/* =============================================================================
 *  IKOHITOKENURI · a module that writes the tokenURI of a Kohi piece
 * =============================================================================
 *
 * THE PROBLEM. Marketplaces want metadata in many shapes: a page, an image, a
 * hosted copy. The artwork must stay the same in all of them.
 *
 * HOW IT WORKS. A piece contract does not build its own metadata. It holds
 * the address of a module and calls it. The module reads everything that it
 * needs from the piece through IKohiPiece, so one module serves any number of
 * pieces.
 *
 * THE TRUST BOUNDARY. The module decides how the metadata looks: which
 * fields, which page, which image. It does not decide what the artwork is.
 * The artwork is the program of the piece and the seed of the token, rendered
 * by the contracts that the piece names in kohiRenderPath. The piece owner
 * can replace the module until the piece locks it. After the lock, the module
 * is fixed.
 *
 * PiecePlayer is one module. It writes an animation_url page that renders the
 * token in the browser. Other modules can add an image, or a hosted copy of
 * the page, without any change to the piece.
 */
/// @title IKohiTokenURI
/// @notice The interface of a module that writes the tokenURI of a token of a
///         Kohi piece.
/// @dev One module can serve many pieces. It reads the piece through
///      IKohiPiece.
interface IKohiTokenURI {
    /// @notice The tokenURI of a token of a piece.
    /// @dev Reverts for a token that the piece does not have.
    /// @param piece   The piece contract.
    /// @param tokenId The token.
    /// @return The metadata URI of the token.
    function tokenURI(IKohiPiece piece, uint256 tokenId) external view returns (string memory);
}
