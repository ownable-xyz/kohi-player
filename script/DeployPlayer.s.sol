// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "./PlayerDeployer.sol";
import "../src/player/PiecePlayerV2.sol";
import "../src/player/PiecePlayerV3.sol";

/*
 * DeployPlayer: the piece player, once per chain. Every KohiPiece can then use
 * the same PiecePlayer as its tokenURI module.
 *
 *   1. BlobStore (or the one at BLOB_STORE, if set).
 *   2. The 7 page template segments and both wasm blobs, chunked.
 *   3. PieceArtifact (it re-checks both blob hashes), then PiecePlayer.
 *
 * IMAGE_BASE (optional) gives the player an image URI prefix, for example
 * "ipfs://<cid>/"; each token's image is then <prefix><id>.png. With
 * PIECE_ARTIFACT set, only a new PiecePlayer is deployed, on that artifact:
 * the way to add an image-carrying player beside an existing one.
 *
 * PLAYER_V2=true deploys a PiecePlayerV2 (the page in a base64 JSON document)
 * instead of a PiecePlayer. Without PIECE_ARTIFACT it first deploys a new
 * PieceArtifact from the current page template on the store, so a template
 * change and the new player go out together; only new bytes are stored.
 *
 * PLAYER_V3=true deploys a PiecePlayerV3. Its tokenURI is a base64 JSON
 * document with the page in it as base64. Without PIECE_ARTIFACT, the script
 * first deploys a new PieceArtifact. This artifact holds the current page
 * template and the two wasm modules compressed with raw DEFLATE. The page
 * decompresses the modules. The compression keeps the tokenURI small.
 *
 * A plain `forge script` only simulates; it broadcasts with --broadcast.
 */
contract DeployPlayer is PlayerDeployer {
    function run() external {
        string memory imageBase = vm.envOr("IMAGE_BASE", string(""));
        address artifactAt = vm.envOr("PIECE_ARTIFACT", address(0));
        if (artifactAt != address(0)) {
            if (vm.envOr("PLAYER_V3", false)) {
                vm.startBroadcast();
                PiecePlayerV3 v3 = new PiecePlayerV3(IPlayerArtifact(artifactAt), imageBase);
                vm.stopBroadcast();
                console2.log("PiecePlayerV3", address(v3));
                return;
            }
            if (vm.envOr("PLAYER_V2", false)) {
                vm.startBroadcast();
                PiecePlayerV2 v2 = new PiecePlayerV2(IPlayerArtifact(artifactAt), imageBase);
                vm.stopBroadcast();
                console2.log("PiecePlayerV2", address(v2));
                return;
            }
            vm.startBroadcast();
            PiecePlayer only = new PiecePlayer(IPlayerArtifact(artifactAt), imageBase);
            vm.stopBroadcast();
            console2.log("PiecePlayer", address(only));
            return;
        }
        address existing = vm.envOr("BLOB_STORE", address(0));
        if (vm.envOr("PLAYER_V3", false)) {
            vm.startBroadcast();
            BlobStore v3Store = existing == address(0) ? new BlobStore() : BlobStore(existing);
            PieceArtifact v3Artifact = _deployArtifactFrom(v3Store, WASM_DEFLATE, NOISE_DEFLATE);
            PiecePlayerV3 v3Player = new PiecePlayerV3(IPlayerArtifact(address(v3Artifact)), imageBase);
            vm.stopBroadcast();
            console2.log("BlobStore", address(v3Store));
            console2.log("PieceArtifact", address(v3Artifact));
            console2.log("PiecePlayerV3", address(v3Player));
            return;
        }
        if (vm.envOr("PLAYER_V2", false)) {
            vm.startBroadcast();
            BlobStore v2Store = existing == address(0) ? new BlobStore() : BlobStore(existing);
            PieceArtifact v2Artifact = _deployArtifact(v2Store);
            PiecePlayerV2 v2Player = new PiecePlayerV2(IPlayerArtifact(address(v2Artifact)), imageBase);
            vm.stopBroadcast();
            console2.log("BlobStore", address(v2Store));
            console2.log("PieceArtifact", address(v2Artifact));
            console2.log("PiecePlayerV2", address(v2Player));
            return;
        }
        vm.startBroadcast();
        BlobStore store = existing == address(0) ? new BlobStore() : BlobStore(existing);
        (PiecePlayer player, PieceArtifact artifact) = _deployPlayer(store, imageBase);
        vm.stopBroadcast();
        console2.log("BlobStore", address(store));
        console2.log("PieceArtifact", address(artifact));
        console2.log("PiecePlayer", address(player));
    }
}
