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
 *  PIECEPLAYERV2 · the tokenURI of a Kohi piece, as a page that renders itself
 * =============================================================================
 *
 * A marketplace needs a tokenURI to show a token. PiecePlayerV2 builds that
 * tokenURI for any contract that implements IKohiPiece. The tokenURI is a
 * `data:application/json;base64,` document. Its animation_url is a
 * `data:text/html,` page. The page carries the wasm render core, the
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
 * version is a new player contract. A piece chooses which player serves its
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
 * THE ENCODING. PiecePlayer, the first version of this contract, writes a
 * `data:application/json;utf8,` document with a base64 page in it.
 * Marketplaces do not decode the URI escapes of that document the same way.
 * This version writes the JSON document as base64. It writes the page in the
 * JSON as `data:text/html,` text with 7 bytes escaped.
 *
 * Some consumers do not accept a `data:text/html,` animation_url. For those
 * consumers, a page in base64 (`data:text/html;base64,`) works. This version
 * does not write that form.
 *
 * Every consumer decodes base64 the same way, so the JSON layer needs no URI
 * escape. The name and the description go into the JSON unchanged. A piece
 * that uses the Attributes library writes each "#" of its attributes as "%23"
 * and each "%" as "%25". The contract decodes these two sequences once, left
 * to right, so the JSON holds the text of the trait. It decodes no other
 * sequence. This decoding is the exact inverse of the escaping of the
 * Attributes library.
 *
 * The animation_url is a `data:text/html,` URI that holds the page as text,
 * not as base64. In this URI, the contract writes each of the 7 bytes "%",
 * "#", '"', "\", LF, CR and TAB as "%" and two upper-case hexadecimal
 * digits. These are the page escapes. Each one has a reason:
 *
 *   "#"           would start a URI fragment.
 *   LF, CR, TAB   are removed from a URI by a browser.
 *   '"' and "\"   would end or change the JSON string.
 *   "%"           starts an escape, so a literal "%" must be escaped.
 *
 * These bytes occur only in the template segments. The three base64
 * payloads, the seed, the params and the family contain none of them. A
 * browser decodes the URI and gets the page back byte for byte.
 *
 * THE NOISE MODULE. The page carries the noise module as its own wasm module.
 * The module derives from the noise function of p5.js. It is licensed under
 * the GNU Lesser General Public License 2.1
 * (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). The render core
 * imports the module when the page loads. The module is never compiled into
 * the render core. A viewer can replace it in the page.
 *
 * GAS. The memory cost of an eth_call is quadratic in its size. For this
 * reason the contract builds the JSON, with the page in it, in one buffer at
 * its exact final size. It then encodes that buffer directly into the ABI
 * return buffer and returns the tokenURI from assembly. The contract encodes
 * each payload in base64 once, and the JSON once, with the 12-bit pair table
 * of the Base64 library. The page goes into the JSON as text, so no byte is
 * encoded in base64 twice.
 *
 * TRUST BOUNDARY. The contract reads the piece and the artifact with view
 * calls and returns text. It holds no funds, writes no storage and calls no
 * contract that can change state.
 */
contract PiecePlayerV2 is IKohiTokenURI {
    /// @notice The number of template segments that the page needs.
    /// @return The number 7.
    uint256 public constant TEMPLATE_SEGMENTS = 7;
    /// @notice The highest rasterizer family that the page renders. The family range is 0 to 5.
    /// @return The number 5.
    uint8 public constant MAX_FAMILY = 5;

    /// @dev The start of the tokenURI, before the base64 text of the JSON.
    bytes internal constant JSON_PREFIX = "data:application/json;base64,";
    /// @dev The start of the animation_url value, before the page text.
    bytes internal constant HTML_URI_PREFIX = "data:text/html,";
    /// @dev A bit set of the bytes that the page escapes write as "%XX": "%"
    ///      (0x25), "#" (0x23), '"' (0x22), "\" (0x5c), LF (0x0a), CR (0x0d)
    ///      and TAB (0x09). Bit b is set for byte value b. All seven values are
    ///      below 0x60.
    uint256 internal constant PAGE_ESCAPES =
        (1 << 0x25) | (1 << 0x23) | (1 << 0x22) | (1 << 0x5c) | (1 << 0x0a) | (1 << 0x0d) | (1 << 0x09);
    /// @dev The gas for the ERC-165 query that detects IKohiLiving (30,000).
    ///      A piece that needs more gas is not living.
    uint256 internal constant ERC165_GAS = 30_000;

    /// @notice The page and wasm version that this player serves.
    /// @return The PieceArtifact that the constructor set.
    IPlayerArtifact public immutable artifact;
    /// @notice The image URI prefix. The empty string means that the JSON has no image field. The constructor sets it.
    /// @return The image URI prefix.
    string public imageBase;

    /// @notice The artifact does not have exactly 7 template segments.
    /// @dev The constructor reverts with this error.
    error BadTemplate();
    /// @notice A wasm chunk set of the artifact is empty.
    /// @dev The constructor reverts with this error.
    error EmptyBlob();
    /// @notice A template segment holds no data.
    /// @dev tokenURI reverts with this error.
    error EmptySegment();
    /// @notice The piece declares a family that the page does not render.
    /// @dev tokenURI reverts with this error.
    /// @param family The family that the piece declared.
    error BadFamily(uint8 family);
    /// @notice The image base holds a quote, a backslash, "%", "#" or a control byte.
    /// @dev The constructor reverts with this error.
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
    /// @return The tokenURI, as a data URI. The function returns it from assembly.
    function tokenURI(IKohiPiece piece, uint256 tokenId) external view returns (string memory) {
        _tokenURI(piece, tokenId);
        return ""; // Not reached. _tokenURI returns from assembly.
    }

    // ---- assembly of the response -------------------------------------------

    /// @dev The six payloads of the page. The page needs more values than the
    ///      legacy compiler pipeline can keep on the stack, so they live in a
    ///      struct. The fields are:
    ///      wasm, the render core bytes;
    ///      noise, the noise module bytes;
    ///      program, the program bytes of the piece;
    ///      seed, the decimal text of the seed;
    ///      params, the BigInt literals of the params, joined with commas;
    ///      family, the decimal text of the family.
    struct Payload {
        bytes wasm;
        bytes noise;
        bytes program;
        bytes seed;
        bytes params;
        bytes family;
    }

    /// @dev Builds the tokenURI and returns it from assembly. The function
    ///      does not return to its caller.
    /// @param piece   The piece contract.
    /// @param tokenId The token.
    function _tokenURI(IKohiPiece piece, uint256 tokenId) internal view {
        Payload memory pl = _payload(piece, tokenId);
        bytes memory image = bytes(imageBase).length == 0
            ? bytes("")
            : abi.encodePacked('"image":"', imageBase, _toDecimal(int256(tokenId)), '.png",');
        bytes memory head = abi.encodePacked(
            '{"name":"', piece.kohiName(tokenId), '","description":"', piece.kohiDescription(), '",', image,
            '"animation_url":"', HTML_URI_PREFIX
        );
        bytes memory tail =
            abi.encodePacked('","attributes":', _decodeHashPercent(bytes(piece.kohiAttributes(tokenId))), "}");
        uint256 tbl = Base64.buildTable();
        _returnURI(_json(pl, head, tail, tbl), tbl);
    }

    /// @dev Reads every payload from the piece and the artifact. Reverts
    ///      BadFamily if the family of the piece is above MAX_FAMILY.
    /// @param piece   The piece contract.
    /// @param tokenId The token.
    /// @return pl The six payloads of the page.
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

    /// @dev Builds the JSON at its exact final size in one buffer: the head,
    ///      the page and the tail. The page is the template segments, with the
    ///      page escapes applied, and the payloads between them. The function
    ///      encodes each base64 payload directly into place.
    /// @param pl   The six payloads of the page.
    /// @param head The JSON text before the page text.
    /// @param tail The JSON text after the page text.
    /// @param tbl  The 12-bit pair table of the Base64 library.
    /// @return json The JSON document.
    function _json(Payload memory pl, bytes memory head, bytes memory tail, uint256 tbl)
        internal
        view
        returns (bytes memory json)
    {
        bytes[TEMPLATE_SEGMENTS] memory t = _segments();
        uint256 len = head.length + tail.length + Base64.encodedLength(pl.wasm.length)
            + Base64.encodedLength(pl.noise.length) + Base64.encodedLength(pl.program.length) + pl.seed.length
            + pl.params.length + pl.family.length;
        for (uint256 i = 0; i < TEMPLATE_SEGMENTS; i++) {
            len += _escapedLength(t[i]);
        }
        json = new bytes(len);
        uint256 p;
        assembly {
            p := add(json, 0x20)
        }
        p = _append(p, head);
        p = _appendEscaped(p, t[0]);
        p = Base64.encodeTo(pl.wasm, p, tbl);
        p = _appendEscaped(p, t[1]);
        p = Base64.encodeTo(pl.noise, p, tbl);
        p = _appendEscaped(p, t[2]);
        p = Base64.encodeTo(pl.program, p, tbl);
        p = _appendEscaped(p, t[3]);
        p = _append(p, pl.seed);
        p = _appendEscaped(p, t[4]);
        p = _append(p, pl.params);
        p = _appendEscaped(p, t[5]);
        p = _append(p, pl.family);
        p = _appendEscaped(p, t[6]);
        _append(p, tail);
    }

    /// @dev Writes the tokenURI directly into the ABI return buffer at the
    ///      free memory pointer, then returns it. The buffer holds the offset,
    ///      the length, the JSON prefix and base64(json), in this order. The
    ///      function reads the prefix into memory before the buffer starts,
    ///      because the read of a bytes constant allocates memory. Nothing
    ///      allocates memory after the buffer starts. Base64.encodeTo restores
    ///      any bytes that it writes past its output. The function sets the
    ///      word after the string to zero.
    /// @param json The JSON document.
    /// @param tbl  The 12-bit pair table of the Base64 library.
    function _returnURI(bytes memory json, uint256 tbl) internal pure {
        bytes memory prefix = JSON_PREFIX;
        uint256 uriLen = prefix.length + Base64.encodedLength(json.length);
        uint256 start;
        uint256 p;
        assembly {
            start := mload(0x40)
            mstore(start, 0x20)
            mstore(add(start, 0x20), uriLen)
            p := add(start, 0x40)
        }
        p = _append(p, prefix);
        p = Base64.encodeTo(json, p, tbl);
        assembly {
            mstore(p, 0)
            return(start, add(0x40, and(add(uriLen, 31), not(31))))
        }
    }

    // ---- params -------------------------------------------------------------

    /// @dev Returns the params as the body of a JS array of BigInt literals.
    ///      A living piece gets its params through slot 253, padded with
    ///      zeros, and the mint time of the token at slot 254. If the params
    ///      of a living piece already reach slot 254, they stay as they are.
    ///      The contract never overwrites a value that the artist set at slot
    ///      254.
    /// @param piece   The piece contract.
    /// @param tokenId The token.
    /// @return out The literals, joined with commas, for example "429496729600n,0n".
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

    /// @dev Returns true when the piece answers supportsInterface(IKohiLiving)
    ///      with true within ERC165_GAS. Any other result is false.
    /// @param piece The piece address.
    /// @return True if the piece is living.
    function _isLiving(address piece) internal view returns (bool) {
        (bool ok, bytes memory ret) = piece.staticcall{gas: ERC165_GAS}(
            abi.encodeWithSelector(0x01ffc9a7, type(IKohiLiving).interfaceId)
        );
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ---- byte helpers -------------------------------------------------------

    /// @dev Decodes "%23" to "#" and "%25" to "%", once, left to right. This
    ///      is the exact inverse of the escaping of the Attributes library.
    ///      Every other byte stays as it is.
    /// @param s The text that the Attributes library escaped.
    /// @return out The decoded text.
    function _decodeHashPercent(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length);
        uint256 j;
        uint256 i;
        while (i < s.length) {
            bytes1 c = s[i];
            if (c == "%" && i + 2 < s.length && s[i + 1] == "2" && (s[i + 2] == "3" || s[i + 2] == "5")) {
                out[j++] = s[i + 2] == "3" ? bytes1("#") : bytes1("%");
                i += 3;
            } else {
                out[j++] = c;
                i++;
            }
        }
        assembly {
            mstore(out, j)
        }
    }

    /// @dev Copies `b` to memory pointer `p` with MCOPY (EIP-5656).
    /// @param p The memory pointer to write to.
    /// @param b The bytes to copy.
    /// @return The pointer after the last byte written.
    function _append(uint256 p, bytes memory b) internal pure returns (uint256) {
        uint256 len = b.length;
        assembly {
            mcopy(p, add(b, 0x20), len)
        }
        return p + len;
    }

    /// @dev Reads the data of every template segment. The data starts at
    ///      offset 1 of the contract code, after the SSTORE2 STOP byte.
    ///      Reverts EmptySegment if a segment has no data.
    /// @return t The 7 template segments.
    function _segments() internal view returns (bytes[TEMPLATE_SEGMENTS] memory t) {
        address[] memory ptrs = artifact.htmlTemplatePointers();
        for (uint256 i = 0; i < TEMPLATE_SEGMENTS; i++) {
            address seg = ptrs[i];
            uint256 sz;
            assembly {
                sz := extcodesize(seg)
            }
            if (sz <= 1) revert EmptySegment();
            bytes memory b = new bytes(sz - 1);
            assembly {
                extcodecopy(seg, add(b, 0x20), 1, sub(sz, 1))
            }
            t[i] = b;
        }
    }

    /// @dev Returns the length of `b` after the page escapes: 2 more bytes
    ///      for each byte in PAGE_ESCAPES.
    /// @param b The bytes to measure.
    /// @return n The escaped length.
    function _escapedLength(bytes memory b) internal pure returns (uint256 n) {
        assembly {
            let q := add(b, 0x20)
            let e := add(q, mload(b))
            n := mload(b)
            for {} lt(q, e) { q := add(q, 1) } {
                n := add(n, shl(1, and(shr(byte(0, mload(q)), PAGE_ESCAPES), 1)))
            }
        }
    }

    /// @dev Copies `b` to memory pointer `p` with the page escapes applied.
    ///      Each byte in PAGE_ESCAPES becomes "%" and two upper-case
    ///      hexadecimal digits.
    /// @param p The memory pointer to write to.
    /// @param b The bytes to copy.
    /// @return The pointer after the last byte written.
    function _appendEscaped(uint256 p, bytes memory b) internal pure returns (uint256) {
        assembly {
            let digits := "0123456789ABCDEF"
            let q := add(b, 0x20)
            let e := add(q, mload(b))
            for {} lt(q, e) { q := add(q, 1) } {
                let c := byte(0, mload(q))
                switch and(shr(c, PAGE_ESCAPES), 1)
                case 0 {
                    mstore8(p, c)
                    p := add(p, 1)
                }
                default {
                    mstore8(p, 0x25)
                    mstore8(add(p, 1), byte(shr(4, c), digits))
                    mstore8(add(p, 2), byte(and(c, 15), digits))
                    p := add(p, 3)
                }
            }
        }
        return p;
    }

    /// @dev Returns the signed base-10 text of `v` (for example -2147483648).
    /// @param v The number.
    /// @return The decimal text of the number.
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
