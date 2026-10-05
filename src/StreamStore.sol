// SPDX-License-Identifier: MIT
/* Copyright (c) wattsy */

pragma solidity ^0.8.13;

import "./SSTORE2.sol";

/* =============================================================================
 *  STREAMSTORE · large payloads as chunked SSTORE2 pointers
 * =============================================================================
 *
 * StreamStore writes a large binary payload (an image, a wasm module) as a
 * sequence of SSTORE2 contracts. It reads back the exact original bytes.
 *
 * SSTORE2 deploys the data as the runtime code of a small contract. This is
 * cheaper to write than storage, and a read copies the code with EXTCODECOPY.
 * EIP-170 limits runtime code to 24,576 bytes. SSTORE2 puts one STOP guard
 * byte first, so a call to the contract does nothing. StreamStore keeps this
 * convention. A pointer holds at most 24,575 data bytes (`MAX_CHUNK`), and
 * the data starts at code offset 1.
 *
 * On write, StreamStore splits a payload across as many pointers as it needs.
 * On read, it joins the chunks into one buffer. The `extcodesize` of a chunk
 * is its data length plus one. `readChunks` copies from code offset 1 and
 * skips the guard byte of each chunk. An error of one byte here shifts every
 * byte after it.
 *
 * The reader copies each chunk with EXTCODECOPY straight into one
 * preallocated buffer. It makes no intermediate allocation per chunk. A chunk
 * boundary can fall inside a logical record. This is safe: the reader drops
 * only the guard byte of each chunk, so the output is byte-exact wherever a
 * boundary falls.
 */
library StreamStore {
    /// Maximum data bytes per chunk. The guard byte plus the data equal the
    /// 24,576-byte runtime cap. A payload of one chunk is written exactly as
    /// a bare SSTORE2.write writes it.
    uint256 internal constant MAX_CHUNK = 24575;

    /// Split `data` into the fewest pointers (chunk size `MAX_CHUNK`).
    function writeChunks(bytes memory data) internal returns (address[] memory ptrs) {
        return writeChunks(data, MAX_CHUNK);
    }

    /// Split `data` across SSTORE2 pointers of at most `chunkSize` data
    /// bytes. A `chunkSize` of 0 or above MAX_CHUNK becomes MAX_CHUNK.
    /// Empty input gives one empty pointer.
    function writeChunks(bytes memory data, uint256 chunkSize) internal returns (address[] memory ptrs) {
        if (chunkSize == 0 || chunkSize > MAX_CHUNK) chunkSize = MAX_CHUNK;
        uint256 len = data.length;
        uint256 n = len == 0 ? 1 : (len + chunkSize - 1) / chunkSize;
        ptrs = new address[](n);
        uint256 off = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 clen = len - off;
            if (clen > chunkSize) clen = chunkSize;
            ptrs[i] = SSTORE2.write(_slice(data, off, clen));
            off += clen;
        }
    }

    /// Join the data of a pointer set into one buffer. EXTCODECOPY copies
    /// each chunk from code offset 1 (after the STOP guard) into place.
    function readChunks(address[] memory ptrs) internal view returns (bytes memory out) {
        uint256 n = ptrs.length;
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) {
            address p = ptrs[i];
            uint256 sz;
            assembly {
                sz := extcodesize(p)
            }
            if (sz > 1) total += sz - 1;
        }
        out = new bytes(total);
        uint256 w;
        assembly {
            w := add(out, 0x20)
        }
        for (uint256 i = 0; i < n; i++) {
            address p = ptrs[i];
            uint256 sz;
            assembly {
                sz := extcodesize(p)
            }
            if (sz > 1) {
                uint256 dlen = sz - 1;
                assembly {
                    extcodecopy(p, w, 1, dlen)
                    w := add(w, dlen)
                }
            }
        }
    }

    /// keccak256 of the reassembled payload. Use it to check the bytes.
    function hashOf(address[] memory ptrs) internal view returns (bytes32) {
        return keccak256(readChunks(ptrs));
    }

    /// Total data bytes of a pointer set: the sum of `extcodesize` minus one
    /// guard byte per chunk.
    function sizeOf(address[] memory ptrs) internal view returns (uint256 total) {
        for (uint256 i = 0; i < ptrs.length; i++) {
            address p = ptrs[i];
            uint256 sz;
            assembly {
                sz := extcodesize(p)
            }
            if (sz > 1) total += sz - 1;
        }
    }

    /// Copy `len` bytes of `data` from `off` into a new buffer. The copy
    /// works in words. It can write up to 31 bytes into the padding of `out`
    /// (inside its allocation) and read past the end of `data` (a memory read
    /// never faults). SSTORE2.write packs exactly `len` bytes, so the padding
    /// is never deployed.
    function _slice(bytes memory data, uint256 off, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            let src := add(add(data, 0x20), off)
            let dst := add(out, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
    }
}
