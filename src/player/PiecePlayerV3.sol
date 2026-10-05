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
 *  PIECEPLAYERV3 · the tokenURI of a Kohi piece, as a page that renders itself
 * =============================================================================
 *
 * A marketplace needs a tokenURI to show a token. PiecePlayerV3 builds that
 * tokenURI for any contract that implements IKohiPiece. The tokenURI is a
 * `data:application/json;base64,` document. Its animation_url is a
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
 * THE ENCODING. The tokenURI is a `data:application/json;base64,` document.
 * Its animation_url is `data:text/html;base64,`. Every byte after each prefix
 * is a base64 character. Thus every byte of the tokenURI is a legal URI
 * byte, and no consumer decodes a URI escape.
 *
 * PiecePlayer, the first version, writes a `data:application/json;utf8,`
 * document. Marketplaces do not decode its "%23" and "%25" escapes the same
 * way. PiecePlayerV2 writes the page as `data:text/html,` text. Some consumers
 * do not accept that form. This version writes the JSON as base64 and the page
 * in it as base64.
 *
 * The name and the description go into the JSON unchanged. The attributes of
 * a piece that uses the Attributes library arrive with each "#" written as
 * "%23" and each "%" written as "%25". The contract decodes these two
 * sequences once, left to right, so the JSON holds the text of the trait. It
 * decodes no other sequence. After "{", the JSON holds 0 to 2 spaces. The head
 * is the JSON text up to the page. These spaces make the length of the head a
 * multiple of 3 (see GAS).
 *
 * THE NOISE MODULE. The page carries the noise module as its own wasm module.
 * The module derives from the noise function of p5.js. It is licensed under
 * the GNU Lesser General Public License 2.1
 * (https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). The render core
 * imports the module when the page loads. The module is never compiled into
 * the render core. A viewer can replace it in the page.
 *
 * GAS. The page bytes are base64 inside the JSON, and the JSON is base64
 * again. Thus the page is encoded twice. The middle text is the page as
 * single base64. The contract does not build the middle text.
 *
 * Each pair of output characters depends on only 12 bits of the page. Three
 * page sextets s1, s2 and s3 give three middle characters A(s1), A(s2) and
 * A(s3), where A is the base64 alphabet. The first two output characters
 * depend only on A(s1) and the top 4 bits of A(s2), thus only on s1 and s2.
 * The last two output characters depend only on the low 4 bits of A(s2) and
 * on A(s3), thus only on s2 and s3.
 *
 * The contract uses two tables of 4096 entries. T1 is indexed by (s1, s2). T2
 * is indexed by (s2, s3). Each 18 page bytes become 32 output characters with
 * 16 lookups and one memory write. This is the same work as one ordinary
 * base64 pass. The length of the head is a multiple of 3, so the page starts
 * on a base64 group boundary. The contract encodes the last page bytes (fewer
 * than 18) the ordinary way. It also encodes the text after the page (the
 * tail) the ordinary way.
 *
 * The memory cost of an eth_call is quadratic in its size. For this reason,
 * the contract builds the page in one buffer at its exact final size. It never builds the
 * middle text. It encodes directly into the ABI return buffer, and it returns
 * the tokenURI from assembly. Everything that allocates memory runs before the
 * return buffer starts.
 *
 * TRUST BOUNDARY. The contract reads the piece and the artifact with view
 * calls and returns text. It holds no funds, writes no storage and calls no
 * contract that can change state.
 */
contract PiecePlayerV3 is IKohiTokenURI {
    /// @notice The number of template segments that the page needs.
    /// @return The number 7.
    uint256 public constant TEMPLATE_SEGMENTS = 7;
    /// @notice The highest rasterizer family that the page renders. The family range is 0 to 5.
    /// @return The number 5.
    uint8 public constant MAX_FAMILY = 5;

    /// @dev The start of the tokenURI, before the base64 JSON.
    bytes internal constant JSON_PREFIX = "data:application/json;base64,";
    /// @dev The start of the animation_url value, before the base64 page.
    bytes internal constant HTML_URI_PREFIX = "data:text/html;base64,";
    /// @dev The gas for the ERC-165 query that detects IKohiLiving (30,000).
    ///      A piece that uses more gas is treated as not living.
    uint256 internal constant ERC165_GAS = 30_000;

    /// @notice The page and wasm version that this player serves.
    /// @return The PieceArtifact that the constructor set.
    IPlayerArtifact public immutable artifact;
    /// @notice The image URI prefix. The empty string means that the JSON has no image field. Fixed at deployment.
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
    /// @return The tokenURI, as a data URI.
    function tokenURI(IKohiPiece piece, uint256 tokenId) external view returns (string memory) {
        _tokenURI(piece, tokenId);
        return ""; // Not reached. _tokenURI returns from assembly.
    }

    // ---- assembly of the response -------------------------------------------

    /// @dev The six payloads of the page, in page order. The page needs more
    ///      values than the legacy compiler pipeline can keep on the stack.
    ///      For this reason, the values are in a struct. The fields are:
    ///        wasm     the bytes of the render core;
    ///        noise    the bytes of the noise module;
    ///        program  the program of the piece;
    ///        seed     the decimal text of the seed of the token;
    ///        params   the BigInt literals, joined with commas;
    ///        family   the decimal text of the family.
    struct Payload {
        bytes wasm;
        bytes noise;
        bytes program;
        bytes seed;
        bytes params;
        bytes family;
    }

    /// @dev Builds the head, the page and the tail, then returns the tokenURI
    ///      from assembly. This function does not return to its caller.
    /// @param piece The piece contract.
    /// @param tokenId The token.
    function _tokenURI(IKohiPiece piece, uint256 tokenId) internal view {
        Payload memory pl = _payload(piece, tokenId);
        bytes memory image = bytes(imageBase).length == 0
            ? bytes("")
            : abi.encodePacked('"image":"', imageBase, _toDecimal(int256(tokenId)), '.png",');
        bytes memory body = abi.encodePacked(
            '"name":"', piece.kohiName(tokenId), '","description":"', piece.kohiDescription(), '",', image,
            '"animation_url":"', HTML_URI_PREFIX
        );
        // "{", then 0 to 2 spaces, so the head length is a multiple of 3.
        uint256 pad = (3 - ((1 + body.length) % 3)) % 3;
        bytes memory head = abi.encodePacked(pad == 0 ? "{" : pad == 1 ? "{ " : "{  ", body);
        bytes memory tail =
            abi.encodePacked('","attributes":', _decodeHashPercent(bytes(piece.kohiAttributes(tokenId))), "}");
        uint256 tbl = Base64.buildTable();
        bytes memory page = _page(pl, tbl);
        _returnURI(head, page, tail, tbl);
    }

    /// @dev Reads every payload from the piece and the artifact.
    ///      Reverts BadFamily if the family of the piece is above MAX_FAMILY.
    /// @param piece The piece contract.
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

    /// @dev Builds the page at its exact final size in one buffer. The buffer
    ///      holds the template segments with the payloads between them. Each
    ///      base64 payload is encoded directly into its place.
    /// @param pl The six payloads of the page.
    /// @param tbl The memory pointer of the pair table of the Base64 library.
    /// @return page The page bytes.
    function _page(Payload memory pl, uint256 tbl) internal view returns (bytes memory page) {
        bytes[TEMPLATE_SEGMENTS] memory t = _segments();
        uint256 len = Base64.encodedLength(pl.wasm.length) + Base64.encodedLength(pl.noise.length)
            + Base64.encodedLength(pl.program.length) + pl.seed.length + pl.params.length + pl.family.length;
        for (uint256 i = 0; i < TEMPLATE_SEGMENTS; i++) {
            len += t[i].length;
        }
        page = new bytes(len);
        uint256 p;
        assembly {
            p := add(page, 0x20)
        }
        p = _append(p, t[0]);
        p = Base64.encodeTo(pl.wasm, p, tbl);
        p = _append(p, t[1]);
        p = Base64.encodeTo(pl.noise, p, tbl);
        p = _append(p, t[2]);
        p = Base64.encodeTo(pl.program, p, tbl);
        p = _append(p, t[3]);
        p = _append(p, pl.seed);
        p = _append(p, t[4]);
        p = _append(p, pl.params);
        p = _append(p, t[5]);
        p = _append(p, pl.family);
        _append(p, t[6]);
    }

    /// @dev Writes the tokenURI directly into the ABI return buffer at the
    ///      free memory pointer, then returns it. The tokenURI is the JSON
    ///      prefix plus base64(head || base64(page) || tail). The length of the
    ///      head is a multiple of 3. The whole 18-byte blocks of the page go
    ///      through T1 and T2 (see GAS). The rest of the page, as ordinary
    ///      base64, and the tail form the last part. The contract encodes the
    ///      last part the ordinary way. It writes a zero word after the string
    ///      before the return. Everything that allocates memory runs before
    ///      the return buffer starts. This function does not return to its
    ///      caller.
    /// @param head The JSON text up to the page.
    /// @param page The page bytes.
    /// @param tail The JSON text after the page.
    /// @param tbl The memory pointer of the pair table of the Base64 library.
    function _returnURI(bytes memory head, bytes memory page, bytes memory tail, uint256 tbl) internal pure {
        bytes memory prefix = JSON_PREFIX;
        (uint256 t1, uint256 t2) = _doubleTables(tbl);
        uint256 blocks = page.length / 18;
        bytes memory rest = abi.encodePacked(Base64.encode(_slice(page, blocks * 18, page.length)), tail);
        uint256 uriLen =
            prefix.length + Base64.encodedLength(head.length) + blocks * 32 + Base64.encodedLength(rest.length);
        uint256 start;
        uint256 p;
        assembly {
            start := mload(0x40)
            mstore(start, 0x20)
            mstore(add(start, 0x20), uriLen)
            p := add(start, 0x40)
        }
        p = _append(p, prefix);
        p = Base64.encodeTo(head, p, tbl);
        assembly {
            let src := add(page, 0x20)
            let end := add(src, mul(blocks, 18))
            for {} lt(src, end) {} {
                let w := mload(src)
                src := add(src, 18)
                // For triple k, the T1 index is bits [18k, 18k+12) of w.
                // The T2 index is bits [18k+6, 18k+18) of w. Bits count from
                // the top. Each index shifts left by 1 (2-byte entries).
                let acc := shr(240, mload(add(t1, and(shr(243, w), 0x1FFE))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(237, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(225, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(219, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(207, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(201, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(189, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(183, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(171, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(165, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(153, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(147, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(135, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(129, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t1, and(shr(117, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(t2, and(shr(111, w), 0x1FFE)))))
                mstore(p, acc)
                p := add(p, 32)
            }
        }
        p = Base64.encodeTo(rest, p, tbl);
        assembly {
            mstore(p, 0)
            return(start, add(0x40, and(add(uriLen, 31), not(31))))
        }
    }

    /// @dev Builds T1 and T2 from the pair table of the Base64 library. Entry
    ///      i at tbl + 2i holds the two characters of the 12-bit value i. A(s)
    ///      is the second character of entry s. Let a1 = A(s1), a2 = A(s2) and
    ///      a3 = A(s3). Then:
    ///
    ///        T1[s1 << 6 | s2] = pair[a1 << 4 | a2 >> 4]
    ///        T2[s2 << 6 | s3] = pair[(a2 & 15) << 8 | a3]
    ///
    ///      Each table has 4096 entries of 2 bytes (8192 bytes). T2 starts 8192
    ///      bytes after T1. The free memory pointer moves 32 bytes past the end
    ///      of T2 (8224 bytes after the start of T2), as slack. Each 32-byte
    ///      write covers its 2-byte entry and the 30 bytes after it. The
    ///      function writes the entries in increasing order, T1 completely and
    ///      then T2. Thus a write past an entry touches only entries that the
    ///      same pass writes later, or the slack after T2.
    /// @param tbl The memory pointer of the pair table of the Base64 library.
    /// @return t1 The memory pointer of T1.
    /// @return t2 The memory pointer of T2.
    function _doubleTables(uint256 tbl) internal pure returns (uint256 t1, uint256 t2) {
        assembly {
            t1 := mload(0x40)
            t2 := add(t1, 8192)
            mstore(0x40, add(t2, 8224))
            // The loops write T1 first, then T2. A write goes 30 bytes past
            // its entry, into entries that the same pass writes later.
            for { let x := 0 } lt(x, 64) { x := add(x, 1) } {
                let row := add(t1, shl(7, x))
                let hi := shl(4, byte(1, mload(add(tbl, shl(1, x)))))
                for { let y := 0 } lt(y, 64) { y := add(y, 1) } {
                    let ay := byte(1, mload(add(tbl, shl(1, y))))
                    mstore(add(row, shl(1, y)), mload(add(tbl, shl(1, or(hi, shr(4, ay))))))
                }
            }
            for { let x := 0 } lt(x, 64) { x := add(x, 1) } {
                let row := add(t2, shl(7, x))
                let hi := shl(8, and(byte(1, mload(add(tbl, shl(1, x)))), 15))
                for { let y := 0 } lt(y, 64) { y := add(y, 1) } {
                    let ay := byte(1, mload(add(tbl, shl(1, y))))
                    mstore(add(row, shl(1, y)), mload(add(tbl, shl(1, or(hi, ay)))))
                }
            }
        }
    }

    /// @dev Copies the bytes of `b` from `from` to `to` into a new array. It uses MCOPY.
    /// @param b The source bytes.
    /// @param from The start offset in `b`.
    /// @param to The end offset in `b`. It is not included.
    /// @return out The copied bytes.
    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly {
            mcopy(add(out, 0x20), add(add(b, 0x20), from), sub(to, from))
        }
    }

    // ---- params -------------------------------------------------------------

    /// @dev Builds the params as the body of a JS array of BigInt literals. A
    ///      living piece gets its params through slot 253, padded with zeros.
    ///      The mint time of the token fills slot 254. If the params of a
    ///      living piece already reach slot 254, they stay as they are. The
    ///      contract never overwrites the value of the piece.
    /// @param piece The piece contract.
    /// @param tokenId The token.
    /// @return out The decimal BigInt literals, joined with commas.
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

    /// @dev Returns true if the piece answers supportsInterface(IKohiLiving)
    ///      with true within ERC165_GAS. Any other result gives false.
    /// @param piece The piece address.
    /// @return True if the piece is a living piece.
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
    /// @param s The escaped text.
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

    /// @dev Copies `b` to the memory pointer `p` with MCOPY (EIP-5656).
    /// @param p The destination memory pointer.
    /// @param b The source bytes.
    /// @return The advanced pointer, `p` plus the length of `b`.
    function _append(uint256 p, bytes memory b) internal pure returns (uint256) {
        uint256 len = b.length;
        assembly {
            mcopy(p, add(b, 0x20), len)
        }
        return p + len;
    }

    /// @dev Reads the data of every template segment. The data starts at
    ///      offset 1 of the code of each SSTORE2 contract, after the STOP byte.
    ///      Reverts EmptySegment if a segment has no data (code size 1 or less).
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

    /// @dev Returns the signed base-10 text of `v`, for example -2147483648.
    /// @param v The value.
    /// @return The decimal text of `v`.
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
