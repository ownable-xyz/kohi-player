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
 *  BASE64 · RFC 4648 encoding for the data-URI pages
 * =============================================================================
 *
 * An RFC 4648 section 4 encoder (standard alphabet, `=` padding). It builds
 * the base64 data URIs of the token pages: the embedded
 * `data:text/html;base64,...` page and the wasm and program payloads inside
 * it. Several public Solidity base64 implementations exist. This encoder is an
 * independent, first-party implementation. It shares only the standard
 * alphabet with them.
 *
 * It is standalone. encodeTo writes into the buffer of the caller at a given
 * pointer. It needs no buffer or allocation abstraction. RFC 4648 test
 * vectors pin its output. Differential fuzzing checks it against a simple
 * mstore8-per-character reference.
 *
 * The common mstore8-per-character method costs about 76 gas per INPUT byte.
 * For a large wasm blob, encoded once into a page and again into the data URI
 * of that page, this transform alone can dominate the gas of a view call.
 * This encoder works as follows:
 *
 *   1. buildTable makes a 4096-entry PAIR table once per call chain (~8 KB of
 *      memory, a few thousand gas). Entry i holds the TWO ASCII chars of the
 *      12-bit value i, so one mload gives two output chars;
 *   2. each loop iteration reads 24 input bytes with one mload, extracts
 *      sixteen 12-bit slices, and writes 32 output chars with ONE mstore;
 *   3. encodeTo(data, dstPtr, tblPtr) encodes straight into the buffer at
 *      dstPtr, with no intermediate allocation, and returns the end pointer.
 *
 * The cost is about 34 gas per input byte, about 2.2x lower. The output is
 * BYTE-IDENTICAL: same alphabet, same '=' padding. Bits beyond the input are
 * masked to zero, as RFC 4648 pads.
 *
 * Write rule of encodeTo (for callers that embed the output in a larger
 * buffer): it writes exactly encodedLength(data.length) bytes at dstPtr. The
 * tail block can briefly write up to 28 bytes past that end. The function
 * saves the word at the end before the write and restores it after, so the
 * memory past the output stays byte-identical. It can also READ up to 8 bytes
 * past the end of `data`. It masks them before use, and EVM memory reads never
 * fault.
 */
library Base64 {
    /// The RFC 4648 section 4 standard alphabet (index 0..63).
    bytes internal constant TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /// @notice Encoded length for `n` input bytes.
    /// @param n Input length in bytes.
    /// @return 4 chars for each 3 input bytes, rounded up (padding included).
    function encodedLength(uint256 n) internal pure returns (uint256) {
        return 4 * ((n + 2) / 3);
    }

    /// @notice Build the 12-bit pair table shared by encodeTo calls.
    /// @dev Allocates 8,320 bytes at the free-memory pointer: 128 B of
    ///      spread scratch, then the 8,192 B table. The table has 4096
    ///      entries of 2 bytes. Entry i (i = hi6<<6 | lo6) is alphabet[hi6]
    ///      then alphabet[lo6]. Build one table and share it between encodeTo
    ///      calls.
    /// @return tblPtr The memory pointer to the first entry of the table.
    function buildTable() internal pure returns (uint256 tblPtr) {
        bytes memory alphabet = TABLE;
        assembly {
            let a := add(alphabet, 0x20)
            let spread := mload(0x40)
            tblPtr := add(spread, 128)
            mstore(0x40, add(tblPtr, 8192))

            // Put the 64 alphabet chars in the ODD bytes of the 128-byte
            // scratch (even bytes zero): four words S0..S3, with 16 "lo"
            // chars each.
            mstore(spread, 0)
            mstore(add(spread, 32), 0)
            mstore(add(spread, 64), 0)
            mstore(add(spread, 96), 0)
            for { let k := 0 } lt(k, 64) { k := add(k, 1) } {
                mstore8(add(add(spread, 1), shl(1, k)), byte(0, mload(add(a, k))))
            }
            let s0 := mload(spread)
            let s1 := mload(add(spread, 32))
            let s2 := mload(add(spread, 64))
            let s3 := mload(add(spread, 96))

            // Row hi (128 bytes = 64 entries): the "hi" char in the EVEN
            // bytes (mul by the 0x0100-repeated constant), OR the "lo" chars.
            let rep := 0x0100010001000100010001000100010001000100010001000100010001000100
            for { let hi := 0 } lt(hi, 64) { hi := add(hi, 1) } {
                let row := add(tblPtr, shl(7, hi))
                let r := mul(byte(0, mload(add(a, hi))), rep)
                mstore(row, or(r, s0))
                mstore(add(row, 32), or(r, s1))
                mstore(add(row, 64), or(r, s2))
                mstore(add(row, 96), or(r, s3))
            }
        }
    }

    /// @notice Base64-encode `data` into memory at `dstPtr` with a pair
    ///         table from buildTable().
    /// @dev Writes exactly encodedLength(data.length) bytes. The file header
    ///      describes the write and restore rule for the memory past the end.
    ///      Never reverts.
    /// @param data   The bytes to encode.
    /// @param dstPtr The destination memory pointer (allocated by the caller).
    /// @param tblPtr A pair table from buildTable().
    /// @return The pointer to the byte after the output.
    function encodeTo(bytes memory data, uint256 dstPtr, uint256 tblPtr) internal pure returns (uint256) {
        uint256 len = data.length;
        if (len == 0) return dstPtr;

        assembly {
            let src := add(data, 0x20)
            let dst := dstPtr

            // Full 24-byte blocks: one input mload, sixteen 12-bit pair
            // lookups, one 32-char output mstore.
            let srcEnd := add(src, mul(div(len, 24), 24))
            for {} lt(src, srcEnd) {} {
                let w := mload(src)
                src := add(src, 24)
                // Pair k = input bits [12k, 12k+12) from the top. The lookup
                // index is shifted left by 1 (entries are 2 bytes wide).
                let acc := shr(240, mload(add(tblPtr, and(shr(243, w), 0x1FFE))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(231, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(219, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(207, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(195, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(183, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(171, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(159, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(147, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(135, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(123, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(111, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(99, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(87, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(75, w), 0x1FFE)))))
                acc := or(shl(16, acc), shr(240, mload(add(tblPtr, and(shr(63, w), 0x1FFE)))))
                mstore(dst, acc)
                dst := add(dst, 32)
            }

            // Tail: r = len % 24 bytes gives ceil(r/3) units of 4 chars. Each
            // unit is a full mstore, so save the word after the end and
            // restore it.
            let r := mod(len, 24)
            if r {
                let afterPtr := add(dst, shl(2, div(add(r, 2), 3)))
                let afterCache := mload(afterPtr)

                // Full 3-byte groups.
                for { let gEnd := add(src, mul(div(r, 3), 3)) } lt(src, gEnd) {} {
                    let v := shr(232, mload(src))
                    src := add(src, 3)
                    let quad := shr(240, mload(add(tblPtr, and(shr(11, v), 0x1FFE))))
                    quad := or(shl(16, quad), shr(240, mload(add(tblPtr, and(shl(1, v), 0x1FFE)))))
                    mstore(dst, shl(224, quad))
                    dst := add(dst, 4)
                }

                // Partial group: set the extra bytes to ZERO (RFC 4648 pads
                // with zero bits), then write '=' over the unused chars.
                let rem := mod(r, 3)
                if rem {
                    let v := shr(232, mload(src))
                    switch rem
                    case 1 { v := and(v, 0xFF0000) }
                    default { v := and(v, 0xFFFF00) }
                    let quad := shr(240, mload(add(tblPtr, and(shr(11, v), 0x1FFE))))
                    quad := or(shl(16, quad), shr(240, mload(add(tblPtr, and(shl(1, v), 0x1FFE)))))
                    switch rem
                    case 1 { quad := or(and(quad, 0xFFFF0000), 0x3D3D) }
                    default { quad := or(and(quad, 0xFFFFFF00), 0x3D) }
                    mstore(dst, shl(224, quad))
                    dst := add(dst, 4)
                }

                mstore(afterPtr, afterCache)
            }
        }
        return dstPtr + encodedLength(len);
    }

    /// @notice Base64-encode `data` into a fresh string.
    /// @dev A wrapper for buildTable and encodeTo. Never reverts.
    /// @param data The bytes to encode.
    /// @return result Standard-alphabet base64, padded to a multiple of 4.
    function encode(bytes memory data) internal pure returns (string memory result) {
        if (data.length == 0) return "";
        uint256 tbl = buildTable();
        result = new string(encodedLength(data.length));
        uint256 p;
        assembly {
            p := add(result, 0x20)
        }
        encodeTo(data, p, tbl);
    }
}
