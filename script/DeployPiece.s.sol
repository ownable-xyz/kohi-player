// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "./PlayerDeployer.sol";
import "../src/Base64.sol";
import "../src/player/KohiPiece.sol";
import {IKohiTokenURI} from "../src/player/IKohiTokenURI.sol";
import {KohiRenderPath} from "../src/player/IKohiPiece.sol";

/*
 * DeployPiece: one KohiPiece, from a JSON config, against the live Kohi engine
 * of this chain (mainnet or Sepolia).
 *
 *   PIECE_CONFIG=pieces/<piece>/piece.json forge script script/DeployPiece.s.sol:DeployPiece
 *
 * In order:
 *   1. The player at config.player, or a new one if that is zero.
 *   2. KohiPiece with the name, symbol, supply, family and noise kind.
 *   3. The art: the program (one tx per SSTORE2 chunk), the params, the traits
 *      (from a p5c trait manifest), the description; then lockArt.
 *   4. The seeds (the `seeds` array of the seeds file), then lockSeeds.
 *   5. The mint, in token order: mintCount[i] tokens to mintTo[i].
 *   6. The default royalty (ERC-2981), if royaltyBps is non-zero.
 *   7. The player as the tokenURI module, and the collection metadata
 *      (ERC-7572) as a base64 JSON data URI. Neither is locked.
 *
 * The sale is a separate step (DeploySale), so the piece can be checked on
 * marketplaces before any sale contract exists.
 *
 * Not here: the creator attribution (ERC-7015). The creator signs over the
 * piece's address, so it follows the deploy.
 *
 * Config keys: name, symbol, maxSupply, family, noiseKind, program, params,
 * traits, seeds, description, player, mintTo, mintCount, royaltyReceiver,
 * royaltyBps, and optionally contractImage, contractBannerImage,
 * contractFeaturedImage and externalLink for the collection metadata (and, for
 * DeploySale, saleSeller, salePrice in wei as a string,
 * saleStart in unix seconds, saleCollections); renderer is optional for family 3 (the StampRenderer) and
 * required otherwise. Paths are relative to the project root.
 *
 * A plain `forge script` only simulates; it broadcasts with --broadcast.
 */
contract DeployPiece is PlayerDeployer {
    struct Engine {
        address runner;
        address stepRunner;
        address renderer;
        address traitsRunner;
    }

    function run() external {
        string memory json = vm.readFile(vm.envString("PIECE_CONFIG"));
        Engine memory e = _engine(uint8(vm.parseJsonUint(json, ".noiseKind")));
        // The renderer belongs to the family. Stamps (family 3) default to the
        // engine's StampRenderer; any other family names its renderer.
        if (vm.keyExists(json, ".renderer")) e.renderer = vm.parseJsonAddress(json, ".renderer");
        else require(vm.parseJsonUint(json, ".family") == 3, "set renderer for this family");

        vm.startBroadcast();
        address player = vm.parseJsonAddress(json, ".player");
        if (player == address(0)) {
            (PiecePlayer p,) = _deployPlayer(new BlobStore(), "");
            player = address(p);
        }
        KohiPiece piece = _deploy(json, e);
        _art(piece, json);
        piece.setSeeds(_seeds(json));
        piece.lockSeeds();
        _mint(piece, json);
        uint256 bps = vm.parseJsonUint(json, ".royaltyBps");
        if (bps != 0) piece.setDefaultRoyalty(vm.parseJsonAddress(json, ".royaltyReceiver"), uint96(bps));
        piece.setTokenURIModule(IKohiTokenURI(player));
        piece.setContractURI(_contractURI(json));
        vm.stopBroadcast();

        console2.log("PiecePlayer", player);
        console2.log("KohiPiece", address(piece));
    }

    function _deploy(string memory json, Engine memory e) internal returns (KohiPiece) {
        KohiRenderPath memory path = KohiRenderPath({
            family: uint8(vm.parseJsonUint(json, ".family")),
            noiseKind: uint8(vm.parseJsonUint(json, ".noiseKind")),
            runner: e.runner,
            stepRunner: e.stepRunner,
            renderer: e.renderer
        });
        return new KohiPiece(
            msg.sender,
            vm.parseJsonString(json, ".name"),
            vm.parseJsonString(json, ".symbol"),
            vm.parseJsonUint(json, ".maxSupply"),
            path,
            e.traitsRunner
        );
    }

    function _art(KohiPiece piece, string memory json) internal {
        bytes memory program = _hex(vm.parseJsonString(json, ".program"));
        uint256 cs = StreamStore.MAX_CHUNK;
        for (uint256 off = 0; off < program.length; off += cs) {
            piece.appendProgram(_slice(program, off, off + cs < program.length ? off + cs : program.length));
        }
        int256[] memory raw = vm.parseJsonIntArray(json, ".params");
        if (raw.length != 0) {
            int64[] memory params = new int64[](raw.length);
            for (uint256 i = 0; i < raw.length; i++) params[i] = int64(raw[i]);
            piece.setParams(params);
        }
        string memory manifest = vm.readFile(vm.parseJsonString(json, ".traits"));
        for (uint256 i = 0; vm.keyExists(manifest, string.concat("[", vm.toString(i), "]")); i++) {
            string memory at = string.concat("[", vm.toString(i), "]");
            string[] memory labels = vm.keyExists(manifest, string.concat(at, ".labels"))
                ? vm.parseJsonStringArray(manifest, string.concat(at, ".labels"))
                : new string[](0);
            piece.addTrait(
                uint8(vm.parseJsonUint(manifest, string.concat(at, ".id"))),
                _kind(vm.parseJsonString(manifest, string.concat(at, ".kind"))),
                false,
                0,
                vm.parseJsonString(manifest, string.concat(at, ".name")),
                labels
            );
        }
        piece.setDescription(vm.parseJsonString(json, ".description"));
        piece.lockArt();
    }

    function _mint(KohiPiece piece, string memory json) internal {
        address[] memory to = vm.parseJsonAddressArray(json, ".mintTo");
        uint256[] memory count = vm.parseJsonUintArray(json, ".mintCount");
        require(to.length == count.length, "mintTo and mintCount differ in length");
        for (uint256 i = 0; i < to.length; i++) piece.mintTo(to[i], count[i]);
    }


    function _seeds(string memory json) internal view returns (int32[] memory s) {
        int256[] memory raw = vm.parseJsonIntArray(vm.readFile(vm.parseJsonString(json, ".seeds")), ".seeds");
        s = new int32[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) s[i] = int32(raw[i]);
    }

    function _contractURI(string memory json) internal view returns (string memory) {
        bytes memory body = abi.encodePacked(
            '{"name":"', vm.parseJsonString(json, ".name"),
            '","symbol":"', vm.parseJsonString(json, ".symbol"),
            '","description":"', vm.parseJsonString(json, ".description"), '"'
        );
        body = abi.encodePacked(body, _opt(json, "contractImage", "image"), _opt(json, "contractBannerImage", "banner_image"));
        body = abi.encodePacked(body, _opt(json, "contractFeaturedImage", "featured_image"), _opt(json, "externalLink", "external_link"));
        return string.concat("data:application/json;base64,", Base64.encode(abi.encodePacked(body, "}")));
    }

    /// `,"<field>":"<value>"` when the config has `key`, else nothing.
    function _opt(string memory json, string memory key, string memory field) internal view returns (bytes memory) {
        string memory path = string.concat(".", key);
        if (!vm.keyExists(json, path)) return "";
        return abi.encodePacked(',"', field, '":"', vm.parseJsonString(json, path), '"');
    }

    /// The p5c manifest names a trait kind; Attributes numbers them.
    function _kind(string memory k) internal pure returns (uint8) {
        bytes32 h = keccak256(bytes(k));
        if (h == keccak256("number")) return 0;
        if (h == keccak256("choice")) return 1;
        if (h == keccak256("flag")) return 2;
        if (h == keccak256("value")) return 3;
        revert("unknown trait kind");
    }

    /// The live Kohi engine on mainnet and Sepolia. Noise kind 1 pieces step
    /// through KVMStepRunner2.
    function _engine(uint8 noiseKind) internal view returns (Engine memory e) {
        if (block.chainid == 1) {
            e = Engine(
                0x334A2E292Da5499cf955280E4DAef48852E330C6,
                noiseKind == 1 ? 0xEF4f749cFC45d7B3dACEBf8B825F55BD400f5B58 : 0x1d8a97a40DFc234578cb6F4aa13a99826B67e228,
                0x454ead37E6254101f9abe416a4Ff25CAF75cbaa1,
                0xB4fdc3e8ad6fDb68D9deBcB6c4be497BBbd46218
            );
        } else if (block.chainid == 11155111) {
            e = Engine(
                0x2B021f769DdC74ea8a313C4D6333eE61a95269b5,
                noiseKind == 1 ? 0xa26C083A0De581dF8310b40e6057C19B7E78A801 : 0x6833d1d81695Ea7Fa6B99158F187d17264A164dd,
                0x9F1268a62528e0F2BE1A08789320D9C15999b00D,
                0xDF375c8948E2d6bb499b85CCb735d2A8542ce17E
            );
        } else {
            revert("no Kohi engine on this chain");
        }
        require(e.runner.code.length != 0 && e.renderer.code.length != 0, "engine absent on this chain");
    }
}
