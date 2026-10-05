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
 *  IKOHILIVING · the optional interface of a piece that changes with its age
 * =============================================================================
 *
 * THE PROBLEM. A piece that changes over time needs a time that nobody can
 * edit. The age of a token must come from chain state, so every reader sees
 * the same age.
 *
 * HOW IT WORKS. A living piece is a KVM program that reads the age of its
 * token. The program reads the mint time from PARAM slot 254. A player page
 * fills that slot with the value of kohiMintedAt, so the page shows the token
 * at its current age.
 *
 * THE TRUST BOUNDARY. kohiMintedAt is a view over chain state. The timestamp
 * is written once at mint and never changes.
 *
 * A piece that implements this interface also implements IKohiPiece. It
 * declares both through ERC-165.
 */
/// @title IKohiLiving
/// @notice The optional read interface of a piece that changes with the age
///         of its token.
/// @dev Implement it together with IKohiPiece.
interface IKohiLiving {
    /// @notice The block timestamp of the mint of a token.
    /// @dev The mint writes the value once. It never changes after that.
    ///      Reverts IKohiPiece.KohiNoSuchToken for a token that does not
    ///      exist.
    /// @param tokenId The token.
    /// @return mintedAt The mint time, in seconds since the Unix epoch.
    function kohiMintedAt(uint256 tokenId) external view returns (uint64 mintedAt);
}
