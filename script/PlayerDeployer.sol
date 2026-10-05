// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BlobStore.sol";
import "../src/StreamStore.sol";
import "../src/IPlayerArtifact.sol";
import "../src/player/PieceArtifact.sol";
import "../src/player/PiecePlayer.sol";
import "./PieceTemplate.sol";

/*
 * Shared deploy steps for the piece player, used by DeployPlayer and by
 * DeployPiece when a piece brings its own player.
 *
 * BlobStore writes are content-addressed: the same bytes always land at the
 * same pointer. Each write checks pointerOf first and skips bytes the store
 * already holds, so a new player on an existing store (for example, a new
 * page template) sends only what is new.
 */
abstract contract PlayerDeployer is Script, PieceTemplate {
    string internal constant WASM = "assets/player-wasm.hex";
    string internal constant NOISE = "assets/player-noise-wasm.hex";
    // The same two modules, compressed with raw DEFLATE (RFC 1951, zlib
    // level 9). The page decompresses them to the exact modules above.
    string internal constant WASM_DEFLATE = "assets/player-wasm.deflate.hex";
    string internal constant NOISE_DEFLATE = "assets/player-noise-wasm.deflate.hex";

    /// Upload the page template and both wasm blobs, then deploy the artifact
    /// and the player. Call inside a broadcast.
    function _deployPlayer(BlobStore store, string memory imageBase)
        internal
        returns (PiecePlayer player, PieceArtifact artifact)
    {
        artifact = _deployArtifact(store);
        player = new PiecePlayer(IPlayerArtifact(address(artifact)), imageBase);
    }

    /// Upload the page template and both wasm blobs (only bytes the store
    /// does not hold yet), then deploy the artifact. Call inside a broadcast.
    function _deployArtifact(BlobStore store) internal returns (PieceArtifact artifact) {
        artifact = _deployArtifactFrom(store, WASM, NOISE);
    }

    /// @dev Upload the page template and the two wasm blobs from the given
    ///      asset files, then deploy the artifact. Only bytes that the store
    ///      does not hold yet are stored. Call inside a broadcast.
    /// @param store     The BlobStore that holds the bytes.
    /// @param wasmPath  The hex file of the render core (raw, or raw DEFLATE).
    /// @param noisePath The hex file of the noise module (raw, or raw DEFLATE).
    /// @return artifact The new PieceArtifact.
    function _deployArtifactFrom(BlobStore store, string memory wasmPath, string memory noisePath)
        internal
        returns (PieceArtifact artifact)
    {
        bytes[7] memory t = _pieceTemplate();
        address[] memory tmpl = new address[](7);
        for (uint256 i = 0; i < 7; i++) tmpl[i] = _write(store, t[i]);
        bytes memory wasm = _hex(wasmPath);
        bytes memory noise = _hex(noisePath);
        address[] memory wasmPtrs = _writeChunks(store, wasm);
        address[] memory noisePtrs = _writeChunks(store, noise);
        artifact = new PieceArtifact(tmpl, wasmPtrs, keccak256(wasm), noisePtrs, keccak256(noise));
    }

    function _writeChunks(BlobStore store, bytes memory data) internal returns (address[] memory ptrs) {
        uint256 cs = StreamStore.MAX_CHUNK;
        ptrs = new address[]((data.length + cs - 1) / cs);
        for (uint256 i = 0; i < ptrs.length; i++) {
            uint256 off = i * cs;
            ptrs[i] = _write(store, _slice(data, off, off + cs < data.length ? off + cs : data.length));
        }
    }

    /// Store `data` unless the store already holds it; either way, its pointer.
    function _write(BlobStore store, bytes memory data) internal returns (address) {
        (address pointer, bool written) = store.pointerOf(data);
        if (written) {
            console2.log("already stored", pointer, data.length);
            return pointer;
        }
        return store.write(data);
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) out[i - from] = b[i];
    }

    function _hex(string memory path) internal view returns (bytes memory) {
        bytes memory s = bytes(vm.readFile(path));
        uint256 n = s.length;
        while (n > 0 && (s[n - 1] == 0x0a || s[n - 1] == 0x0d || s[n - 1] == 0x20)) n--;
        return vm.parseBytes(string(_slice(s, 0, n)));
    }
}
