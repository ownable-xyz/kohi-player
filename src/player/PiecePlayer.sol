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

import "../Base64.sol";
import "../StreamStore.sol";
import "../IPlayerArtifact.sol";
import {IKohiPiece, KohiRenderPath} from "./IKohiPiece.sol";
import {IKohiLiving} from "./IKohiLiving.sol";
import {IKohiTokenURI} from "./IKohiTokenURI.sol";

/* =============================================================================
 *  PIECEPLAYER · the tokenURI of a Kohi piece, as a page that renders itself
 * =============================================================================
 *
 * A marketplace needs a tokenURI to show a token. PiecePlayer builds that
 * tokenURI for any contract that implements IKohiPiece. The tokenURI is a
 * `data:application/json;utf8,` document. Its animation_url is a
 * `data:text/html;base64,` page. The page carries the wasm render core, the
 * noise module, the piece's program, the token's seed, the piece's params and
 * its family. A marketplace frame renders the token from that page alone. No
 * server is involved.
 *
 * WHAT THIS CONTRACT IS FOR. The artwork is the piece's program plus the
 * token's seed. The contracts that the piece names in kohiRenderPath render
 * it. The page is a viewer of that artwork. This contract is not in the
 * render path. No version of it can change a pixel of any artwork.
 *
 * NO OWNER, NO SETTER. This contract has no owner and no setter. It stores
 * only two values, and the constructor sets both: the PieceArtifact (the
 * page and the two wasm blobs) and the optional image base. A new page
 * version is a new PiecePlayer. A piece chooses which PiecePlayer serves its
 * tokens.
 *
 * THE PAGE. The page is the 7 template segments with the 6 payloads between
 * them, in this order:
 *
 *   segment 0  base64(render core)  segment 1  base64(noise module)
 *   segment 2  base64(program)      segment 3  seed (decimal)
 *   segment 4  params               segment 5  family (decimal)   segment 6
 *
 * The family is a number from 0 to 5 (MAX_FAMILY). It selects the rasterizer
 * that the page uses.
 *
 * THE PARAMS. The params are decimal BigInt literals, joined with commas
 * ("429496729600n,0n"). The full 64-bit range reaches the browser exactly. A
 * piece can also implement IKohiLiving. For such a piece, the params run
 * through slot 253, with zeros where the piece has no value. The mint time of
 * the token fills slot 254. If the params of the piece already reach slot
 * 254, they stay as they are. The contract never overwrites a value that the
 * artist set at slot 254.
 *
 * THE JSON. The document has the fields "name", "description",
 * "animation_url" and "attributes". The piece supplies the text. The piece
 * must supply JSON-safe text: no quote, no backslash and no control byte. A
 * player that has an image base also writes the field "image". Its value is
 * the image base, the token id in decimal and ".png". Some marketplaces show
 * only still images in their grids. The image is a picture of the work. The
 * animation_url page is the work.
 *
 * THE DATA URI ESCAPING. In a `data:` URI, "#" starts a fragment and "%"
 * starts an escape. The contract writes each "%" as "%25" and each "#" as
 * "%23" in the name, the description and the attributes. A consumer that
 * decodes the URI gets the text of the piece back unchanged.
 *
 * THE NOISE MODULE. The page carries the noise module as its own wasm module.
 * The module derives from the noise function of p5.js. It is licensed under
 * the GNU Lesser General Public License 2.1
 * (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). The render core
 * imports the module when the page loads. The module is never compiled into
 * the render core. A viewer can replace it in the page.
 *
 * GAS. The memory cost of an eth_call is quadratic in its size. For this
 * reason the contract builds the page in one buffer, at its exact final size.
 * It writes the tokenURI straight into the ABI return buffer. It returns the
 * tokenURI from assembly.
 *
 * TRUST BOUNDARY. The contract reads the piece and the artifact with view
 * calls and returns text. It holds no funds, writes no storage and calls no
 * contract that can change state.
 */
contract PiecePlayer is IKohiTokenURI {
    /// @notice The number of template segments that the page needs.
    uint256 public constant TEMPLATE_SEGMENTS = 7;
    /// @notice The highest rasterizer family that the page renders. The family range is 0 to 5.
    uint8 public constant MAX_FAMILY = 5;

    // The start of the tokenURI, up to the JSON text.
    bytes internal constant JSON_PREFIX = "data:application/json;utf8,";
    // The start of the animation_url value, before the base64 page.
    bytes internal constant HTML_URI_PREFIX = "data:text/html;base64,";
    // Gas for the ERC-165 query that detects IKohiLiving (30,000). A piece
    // that uses more gas is treated as not living.
    uint256 internal constant ERC165_GAS = 30_000;

    /// @notice The page and wasm version that this player serves.
    IPlayerArtifact public immutable artifact;
    /// @notice The image URI prefix. The empty string means that the JSON has no image field. Fixed at deployment.
    string public imageBase;

    /// @notice The artifact does not have exactly 7 template segments.
    error BadTemplate();
    /// @notice A wasm chunk set of the artifact is empty.
    error EmptyBlob();
    /// @notice A template segment holds no data.
    error EmptySegment();
    /// @notice The piece declares a family that the page does not render.
    /// @param family The family that the piece declared.
    error BadFamily(uint8 family);
    /// @notice The image base holds a quote, a backslash, "%", "#" or a control byte.
    error BadImageBase();

    /// @notice Binds the player to one artifact and sets the image base.
    /// @dev Reverts BadTemplate if the artifact does not have exactly 7
    ///      template segments. Reverts EmptyBlob if the render core chunk set
    ///      or the noise module chunk set is empty. Reverts BadImageBase if
    ///      the image base holds a byte below 0x20, the byte 0x7f, a quote, a
    ///      backslash, "%" or "#".
    /// @param artifact_  The PieceArtifact that this player serves.
    /// @param imageBase_ The image URI prefix, for example "ipfs://<cid>/", or
    ///                   "" for no image field.
    constructor(IPlayerArtifact artifact_, string memory imageBase_) {
        if (artifact_.htmlTemplatePointers().length != TEMPLATE_SEGMENTS) revert BadTemplate();
        if (artifact_.wasmPointers().length == 0 || artifact_.noisePointers().length == 0) revert EmptyBlob();
        bytes memory b = bytes(imageBase_);
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c < 0x20 || c == 0x7f || c == '"' || c == "\\" || c == "%" || c == "#") revert BadImageBase();
        }
        artifact = artifact_;
        imageBase = imageBase_;
    }

    /// @notice Returns the tokenURI of a token of a Kohi piece.
    /// @dev A piece calls this function from its own tokenURI, as
    ///      player.tokenURI(this, tokenId). Reverts with the error of the
    ///      piece (IKohiPiece.KohiNoSuchToken) if the token does not exist.
    ///      Reverts BadFamily if the family of the piece is above MAX_FAMILY.
    ///      Reverts EmptySegment if a template segment holds no data.
    /// @param piece   The piece contract.
    /// @param tokenId The token.
    /// @return The tokenURI, as a data URI.
    function tokenURI(IKohiPiece piece, uint256 tokenId) external view returns (string memory) {
        _tokenURI(piece, tokenId);
        return ""; // Not reached. _tokenURI returns from assembly.
    }

    // ---- assembly of the response -------------------------------------------

    // The six payloads of the page. The page needs more values than the
    // legacy compiler pipeline can keep on the stack, so they live in a struct.
    struct Payload {
        bytes wasm;
        bytes noise;
        bytes program;
        bytes seed;
        bytes params;
        bytes family;
    }

    function _tokenURI(IKohiPiece piece, uint256 tokenId) internal view {
        Payload memory pl = _payload(piece, tokenId);
        bytes memory name = _uriSafe(bytes(piece.kohiName(tokenId)));
        bytes memory description = _uriSafe(bytes(piece.kohiDescription()));
        bytes memory attributes = _uriSafe(bytes(piece.kohiAttributes(tokenId)));
        uint256 tbl = Base64.buildTable();
        bytes memory page = _page(pl, tbl);
        bytes memory image = bytes(imageBase).length == 0
            ? bytes("")
            : abi.encodePacked('"image":"', imageBase, _toDecimal(int256(tokenId)), '.png",');
        _returnURI(name, description, image, attributes, page, tbl);
    }

    // Read every payload from the piece and the artifact.
    function _payload(IKohiPiece piece, uint256 tokenId) internal view returns (Payload memory pl) {
        int32 seed = piece.kohiSeed(tokenId);
        uint8 family = piece.kohiRenderPath().family;
        if (family > MAX_FAMILY) revert BadFamily(family);
        pl.wasm = StreamStore.readChunks(artifact.wasmPointers());
        pl.noise = StreamStore.readChunks(artifact.noisePointers());
        pl.program = piece.kohiProgram();
        pl.seed = bytes(_toDecimal(int256(seed)));
        pl.params = _paramsBody(piece, tokenId);
        pl.family = bytes(_toDecimal(int256(uint256(family))));
    }

    // Build the page at its exact final size in one buffer. Each segment is
    // copied straight from its SSTORE2 contract. The three base64 payloads
    // are encoded straight into place.
    function _page(Payload memory pl, uint256 tbl) internal view returns (bytes memory page) {
        address[] memory t = artifact.htmlTemplatePointers();
        page = new bytes(
            _segsLen(t) + Base64.encodedLength(pl.wasm.length) + Base64.encodedLength(pl.noise.length)
                + Base64.encodedLength(pl.program.length) + pl.seed.length + pl.params.length + pl.family.length
        );
        uint256 p;
        assembly {
            p := add(page, 0x20)
        }
        p = _appendSeg(p, t[0]);
        p = Base64.encodeTo(pl.wasm, p, tbl);
        p = _appendSeg(p, t[1]);
        p = Base64.encodeTo(pl.noise, p, tbl);
        p = _appendSeg(p, t[2]);
        p = Base64.encodeTo(pl.program, p, tbl);
        p = _appendSeg(p, t[3]);
        p = _append(p, pl.seed);
        p = _appendSeg(p, t[4]);
        p = _append(p, pl.params);
        p = _appendSeg(p, t[5]);
        p = _append(p, pl.family);
        _appendSeg(p, t[6]);
    }

    // Write the tokenURI straight into the ABI return buffer at the free
    // memory pointer, then return it. The buffer holds the offset, the
    // length, the JSON head, base64(page) and the JSON tail, in this order.
    // Nothing allocates memory after this point, so the padding after the
    // string stays zero. Base64.encodeTo restores any bytes that it writes
    // past its output.
    function _returnURI(
        bytes memory name,
        bytes memory description,
        bytes memory image,
        bytes memory attributes,
        bytes memory page,
        uint256 tbl
    ) internal pure {
        bytes memory head = abi.encodePacked(
            JSON_PREFIX, '{"name":"', name, '","description":"', description, '",', image, '"animation_url":"', HTML_URI_PREFIX
        );
        bytes memory tail = abi.encodePacked('","attributes":', attributes, "}");
        uint256 uriLen = head.length + Base64.encodedLength(page.length) + tail.length;
        uint256 p;
        assembly {
            p := mload(0x40)
            mstore(p, 0x20)
            mstore(add(p, 0x20), uriLen)
            p := add(p, 0x40)
        }
        p = _append(p, head);
        p = Base64.encodeTo(page, p, tbl);
        p = _append(p, tail);
        assembly {
            let fp := mload(0x40)
            return(fp, add(0x40, and(add(uriLen, 31), not(31))))
        }
    }

    // ---- params -------------------------------------------------------------

    // The params as the body of a JS array of BigInt literals. A living piece
    // gets its params through slot 253, padded with zeros, and the mint time
    // of the token at slot 254. If the params of a living piece already
    // reach slot 254, they stay as they are. The contract never overwrites
    // the value of the piece.
    function _paramsBody(IKohiPiece piece, uint256 tokenId) internal view returns (bytes memory out) {
        int64[] memory params = piece.kohiParams();
        for (uint256 i = 0; i < params.length; i++) {
            out = abi.encodePacked(out, i == 0 ? "" : ",", _toDecimal(params[i]), "n");
        }
        if (params.length > 254 || !_isLiving(address(piece))) return out;
        uint64 mintedAt = IKohiLiving(address(piece)).kohiMintedAt(tokenId);
        for (uint256 i = params.length; i < 254; i++) {
            out = abi.encodePacked(out, out.length == 0 ? "" : ",", "0n");
        }
        out = abi.encodePacked(out, ",", _toDecimal(int256(uint256(mintedAt))), "n");
    }

    // True when the piece answers supportsInterface(IKohiLiving) with true
    // within ERC165_GAS. Any other result is false.
    function _isLiving(address piece) internal view returns (bool) {
        (bool ok, bytes memory ret) = piece.staticcall{gas: ERC165_GAS}(
            abi.encodeWithSelector(0x01ffc9a7, type(IKohiLiving).interfaceId)
        );
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ---- byte helpers -------------------------------------------------------

    // The bytes with each "%" written as "%25" and each "#" as "%23".
    function _uriSafe(bytes memory s) internal pure returns (bytes memory out) {
        uint256 extra;
        for (uint256 i = 0; i < s.length; i++) {
            if (s[i] == "%" || s[i] == "#") extra += 2;
        }
        if (extra == 0) return s;
        out = new bytes(s.length + extra);
        uint256 j;
        for (uint256 i = 0; i < s.length; i++) {
            bytes1 c = s[i];
            if (c == "%" || c == "#") {
                out[j++] = "%";
                out[j++] = "2";
                out[j++] = c == "%" ? bytes1("5") : bytes1("3");
            } else {
                out[j++] = c;
            }
        }
    }

    // Copy `b` to memory pointer `p` with MCOPY (EIP-5656). Return the
    // advanced pointer.
    function _append(uint256 p, bytes memory b) internal pure returns (uint256) {
        uint256 len = b.length;
        assembly {
            mcopy(p, add(b, 0x20), len)
        }
        return p + len;
    }

    // Copy the data of a template segment to memory pointer `p`. The data
    // starts at offset 1 of the contract code, after the SSTORE2 STOP byte.
    // Return the advanced pointer. Revert EmptySegment if the segment has no
    // data.
    function _appendSeg(uint256 p, address seg) internal view returns (uint256) {
        uint256 sz;
        assembly {
            sz := extcodesize(seg)
        }
        if (sz <= 1) revert EmptySegment();
        unchecked {
            sz -= 1;
        }
        assembly {
            extcodecopy(seg, p, 1, sz)
        }
        return p + sz;
    }

    // The total data length of the template segments.
    function _segsLen(address[] memory t) internal view returns (uint256 total) {
        for (uint256 i = 0; i < t.length; i++) {
            address seg = t[i];
            uint256 sz;
            assembly {
                sz := extcodesize(seg)
            }
            if (sz > 1) total += sz - 1;
        }
    }

    // The signed base-10 text of `v` (for example -2147483648).
    function _toDecimal(int256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bool neg = v < 0;
        uint256 u = neg ? uint256(-v) : uint256(v);
        bytes memory tmp = new bytes(78);
        uint256 n;
        while (u != 0) {
            tmp[n++] = bytes1(uint8(48 + (u % 10)));
            u /= 10;
        }
        bytes memory out = new bytes(n + (neg ? 1 : 0));
        uint256 j;
        if (neg) out[j++] = "-";
        for (uint256 k = 0; k < n; k++) out[j++] = tmp[n - 1 - k];
        return string(out);
    }
}
