// SPDX-License-Identifier: MIT
// Copyright (c) Solady authors (https://github.com/Vectorized/solady), MIT.
// Adapted from Solady's SSTORE2 (src/utils/SSTORE2.sol): shares the same
// 10-byte PUSH2 creation prologue, the RETURNDATASIZE-as-zero trick, the 0x0A
// runtime offset, and the DeploymentFailed() error name; the opcodes are
// reordered and the API is narrowed.
pragma solidity ^0.8.13;

/*
 * SSTORE2: minimal contract-code-as-storage. Writes `data` as the runtime
 * code of a fresh contract prefixed with a STOP (0x00) byte so it can never
 * be executed, and reads it back with EXTCODECOPY.
 *
 * Creation code layout (10 bytes) followed by the runtime:
 *   61 XXXX  PUSH2 runtime length
 *   3D       RETURNDATASIZE (0)
 *   81       DUP2
 *   60 0A    PUSH1 10 (offset of runtime within creation code)
 *   3D       RETURNDATASIZE (0)
 *   39       CODECOPY
 *   F3       RETURN
 */
library SSTORE2 {
    error DataTooLarge();
    error DeploymentFailed();

    function write(bytes memory data) internal returns (address pointer) {
        // 1 byte STOP prefix + data must fit in the EIP-170 runtime limit.
        if (data.length + 1 > 24576) revert DataTooLarge();

        // creation code | STOP prefix | data
        bytes memory creation = abi.encodePacked(
            hex"61",
            uint16(data.length + 1),
            hex"3d81600a3d39f3",
            hex"00",
            data
        );

        assembly {
            pointer := create(0, add(creation, 0x20), mload(creation))
        }
        if (pointer == address(0)) revert DeploymentFailed();
    }

    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size;
        assembly {
            size := extcodesize(pointer)
        }
        if (size == 0) return data = new bytes(0);
        unchecked {
            size -= 1; // skip the STOP prefix
        }
        data = new bytes(size);
        assembly {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }
}
