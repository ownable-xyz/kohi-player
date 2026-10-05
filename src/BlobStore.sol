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
 *  BLOBSTORE · content-addressed data contracts, permissionless and idempotent
 * =============================================================================
 *
 * A factory for immutable on-chain byte blobs. The ADDRESS of a blob commits
 * to its CONTENT. The factory deploys each blob with CREATE2 and
 * `salt = keccak256(data)`. The address depends only on this factory and the
 * bytes:
 *
 *   creation = 0x61 ++ uint16(len(data) + 1) ++ 0x3d81600a3d39f3
 *              ++ 0x00 ++ data
 *   salt     = keccak256(data)
 *   pointer  = keccak256(0xff ++ address(this) ++ salt
 *              ++ keccak256(creation))[12:]
 *
 * This gives four properties:
 *
 *   - Anyone can compute the address of a blob off-chain before the blob
 *     exists. A consuming contract can use it in install calldata before that
 *     contract is deployed.
 *   - Anyone can write the bytes. There is no owner and no lock, so the data
 *     upload needs no privileged key.
 *   - A redeployed consumer points at the same blobs. It does not upload them
 *     again.
 *   - To check that the right bytes landed, recompute the address. Do not
 *     trust an event.
 *
 * The factory writes each blob in the SSTORE2 data-contract pattern (this
 * factory is a first-party implementation of that public pattern). The blob is
 * the runtime code of a contract with no constructor logic, no owner and no
 * SELFDESTRUCT:
 *
 *       0    1                                        1+len(data)
 *       +----+------------------------------------------------+
 *       |STOP| data                                           |
 *       |0x00|                                                |
 *       +----+------------------------------------------------+
 *
 * The 0x00 prefix is STOP, so a blob never executes as code. A deployed blob
 * is immutable and inert. Only EXTCODECOPY reads it. Readers skip the prefix
 * byte.
 *
 * `write` is IDEMPOTENT. If the blob exists, `write` returns its address and
 * deploys nothing. A repeated or parallel upload is safe. A transaction that
 * landed with a lost receipt costs a re-send, never a duplicate.
 *
 * Batching under EIP-7825 (Fusaka): a transaction is capped at 16,777,216 gas.
 * A full 24,575 B blob costs ~4.9M gas of code deposit plus ~0.4M of calldata.
 * Put TWO full blobs in one `writeMany` transaction (~11.1M gas, 66% of the
 * cap). Do not put three (~16.5M, 98.5%): there is no headroom, and an
 * out-of-gas revert still burns the gas.
 */
contract BlobStore {
    /// The EIP-170 runtime-code limit, minus the STOP prefix byte.
    uint256 internal constant MAX_BLOB = 24575;

    error DataTooLarge();
    error EmptyData();
    error DeploymentFailed();

    /// Emitted only on the FIRST write. A repeated `write` of the same bytes
    /// emits nothing and returns the existing pointer.
    event BlobWritten(bytes32 indexed dataHash, address pointer, uint256 length);

    // ---- write --------------------------------------------------------------

    /// @notice Deploy `data` as a content-addressed blob and return its
    ///         pointer.
    /// @dev Idempotent: if the blob exists, it returns the existing pointer
    ///      and deploys no code. Reverts EmptyData on empty input,
    ///      DataTooLarge above 24,575 B, and DeploymentFailed if CREATE2
    ///      fails.
    /// @param data The payload bytes.
    /// @return pointer The address of the blob (a pure function of the bytes).
    function write(bytes calldata data) external returns (address pointer) {
        return _write(data);
    }

    /// @notice Write many blobs. Each element deploys, or is found, as in
    ///         write.
    /// @dev Use at most two full blobs per transaction (see the EIP-7825 note
    ///      in the file header). Reverts for each element as write does.
    /// @param datas The payloads, in order.
    /// @return pointers The blob address of each payload, in the same order.
    function writeMany(bytes[] calldata datas) external returns (address[] memory pointers) {
        pointers = new address[](datas.length);
        for (uint256 i = 0; i < datas.length; i++) {
            pointers[i] = _write(datas[i]);
        }
    }

    function _write(bytes calldata data) private returns (address pointer) {
        uint256 len = data.length;
        if (len == 0) revert EmptyData();
        if (len > MAX_BLOB) revert DataTooLarge();

        bytes memory creation = _creationCode(data);
        bytes32 salt = keccak256(data);
        pointer = _create2Address(salt, keccak256(creation));

        uint256 cs;
        assembly {
            cs := extcodesize(pointer)
        }
        if (cs != 0) return pointer; // already written: idempotent

        address deployed;
        assembly {
            deployed := create2(0, add(creation, 0x20), mload(creation), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
        emit BlobWritten(salt, deployed, len);
        return deployed;
    }

    // ---- views --------------------------------------------------------------

    /// @notice The address that `data` occupies, and whether code is already
    ///         there.
    /// @dev This is the on-chain form of the off-chain derivation. A reader
    ///      can check a manifest against the deployed factory without trust
    ///      in the generator. It does not check the size: the address has
    ///      meaning only for data that write() accepts. Never reverts.
    /// @param data The payload bytes.
    /// @return pointer The address that the blob occupies or would occupy.
    /// @return written True when code is already deployed at that address.
    function pointerOf(bytes calldata data) external view returns (address pointer, bool written) {
        pointer = _create2Address(keccak256(data), keccak256(_creationCode(data)));
        uint256 cs;
        assembly {
            cs := extcodesize(pointer)
        }
        written = cs != 0;
    }

    /// @notice The payload length of a written blob.
    /// @dev Never reverts.
    /// @param pointer A blob address.
    /// @return size The code size minus the STOP prefix byte. It is 0 for an
    ///              address with no code.
    function sizeOf(address pointer) public view returns (uint256 size) {
        assembly {
            size := extcodesize(pointer)
        }
        if (size != 0) size -= 1; // the STOP prefix
    }

    /// @notice Read the payload of a blob.
    /// @dev A verifier can get the bytes with one eth_call and hash them.
    ///      Never reverts. An address with no code returns empty bytes.
    /// @param pointer A blob address.
    /// @return data The payload bytes (the runtime code after the STOP
    ///              prefix).
    function read(address pointer) external view returns (bytes memory data) {
        uint256 size = sizeOf(pointer);
        if (size == 0) return data;
        data = new bytes(size);
        assembly {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }

    // ---- internals ----------------------------------------------------------

    /// The creation code: a 10-byte prologue that returns the STOP byte and
    /// `data` as the runtime code.
    ///
    ///   61 XXXX  PUSH2 runtime length
    ///   3D       RETURNDATASIZE (0)
    ///   81       DUP2
    ///   60 0A    PUSH1 10 (runtime offset within the creation code)
    ///   3D       RETURNDATASIZE (0)
    ///   39       CODECOPY
    ///   F3       RETURN
    function _creationCode(bytes calldata data) private pure returns (bytes memory) {
        return abi.encodePacked(hex"61", uint16(data.length + 1), hex"3d81600a3d39f3", hex"00", data);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
        );
    }
}
