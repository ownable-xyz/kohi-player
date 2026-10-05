// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/BlobStore.sol";
import "../src/Base64.sol";
import "../src/StreamStore.sol";
import "../src/player/PieceArtifact.sol";
import "../src/player/PiecePlayer.sol";
import {IKohiPiece, KohiRenderPath} from "../src/player/IKohiPiece.sol";
import "./MockKohiPiece.sol";
import "../script/PieceTemplate.sol";

/// An artifact with the 6-segment page of an earlier player.
contract SixSegments {
    address[] internal t;
    address[] internal w;
    address[] internal n;

    constructor(address[] memory t_, address[] memory w_, address[] memory n_) {
        (t, w, n) = (t_, w_, n_);
    }

    function htmlTemplatePointers() external view returns (address[] memory) { return t; }
    function wasmPointers() external view returns (address[] memory) { return w; }
    function noisePointers() external view returns (address[] memory) { return n; }
}

/*
 * PiecePlayer at real blob scale: the full player wasm and noise module are
 * stored through BlobStore (content-addressed, permissionless SSTORE2), bound
 * by a PieceArtifact, and served for a mock piece carrying the stamp golden.
 *
 * The page check decodes animation_url back out of the returned tokenURI and
 * compares it byte for byte with the 7 template segments (PieceTemplate.sol,
 * generated from template-piece.html) joined with the expected payloads. The
 * page e2e test (player-piece-page.test.ts) proves that same template renders
 * the stamp golden identical to the on-chain StampRaster, so this file closes
 * the chain: contract output == template splice == proven page.
 */
contract PiecePlayerTest is Test, PieceTemplate {
    BlobStore internal store;
    PieceArtifact internal artifact;
    PiecePlayer internal player;
    MockKohiPiece internal piece;
    bytes internal wasm;
    bytes internal noise;
    bytes internal prog;
    int32 internal seed;
    address[] internal tmplPtrs;
    address[] internal wasmPtrs;
    address[] internal noisePtrs;

    uint256 internal constant TOKEN = 7;
    string internal constant HTML = "data:text/html;base64,";

    function setUp() public {
        vm.warp(1_790_000_000);
        store = new BlobStore();
        bytes[7] memory t = _pieceTemplate();
        for (uint256 i = 0; i < 7; i++) tmplPtrs.push(store.write(t[i]));
        wasm = _hex("assets/player-wasm.hex");
        noise = _hex("assets/player-noise-wasm.hex");
        wasmPtrs = _chunks(wasm);
        noisePtrs = _chunks(noise);
        artifact = new PieceArtifact(tmplPtrs, wasmPtrs, keccak256(wasm), noisePtrs, keccak256(noise));
        player = new PiecePlayer(IPlayerArtifact(address(artifact)), "");
        prog = _hex("test/golden/stamp.prog.hex");
        seed = int32(vm.parseInt(_trim(vm.readFile("test/golden/stamp.seed.txt"))));
        KohiRenderPath memory p =
            KohiRenderPath({family: 3, noiseKind: 0, runner: address(0x1), stepRunner: address(0), renderer: address(0x2)});
        piece = new MockKohiPiece(prog, new int64[](0), p);
        piece.mint(TOKEN, seed);
    }

    // ---- the page is exactly the template splice ---------------------------------

    function test_Page_IsTheTemplateSplice() public {
        piece.setLiving(false);
        bytes memory json = bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        bytes memory page = _b64decode(_between(json, HTML, '","attributes":'));
        bytes[7] memory t = _pieceTemplate();
        bytes memory expected = abi.encodePacked(t[0], Base64.encode(wasm), t[1], Base64.encode(noise), t[2]);
        expected = abi.encodePacked(expected, Base64.encode(prog), t[3], vm.toString(int256(seed)), t[4]);
        expected = abi.encodePacked(expected, t[5], "3", t[6]);
        assertEq(page.length, expected.length, "page length");
        assertEq(keccak256(page), keccak256(expected), "page != template splice");
    }

    function test_Gas_TokenURI() public {
        uint256 g = gasleft();
        player.tokenURI(IKohiPiece(address(piece)), TOKEN);
        emit log_named_uint("gas(tokenURI, full wasm + stamp program, living)", g - gasleft());
    }

    // ---- the JSON ----------------------------------------------------------------

    function test_Json_EscapesHashAndPercent() public {
        piece.setDescription("100% ink, edition #1");
        bytes memory json = bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(_prefix(json, 27), "data:application/json;utf8,", "prefix");
        assertEq(string(_between(json, '"name":"', '"')), "Mock %237", "name: # -> %23");
        assertEq(string(_between(json, '"description":"', '"')), "100%25 ink, edition %231", "description: % -> %25, # -> %23");
        assertEq(string(_between(json, '"attributes":', "}]")), '[{"trait_type":"Ink","value":"100%25"', "attributes escaped");
        assertEq(uint8(json[json.length - 1]), uint8(bytes1("}")), "JSON closes");
    }

    function test_Json_NoImageByDefault() public {
        bytes memory json = bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(_indexOf(json, bytes('"image"'), 0), -1, "no image field");
        assertEq(bytes(player.imageBase()).length, 0);
    }

    /// A player with an image base writes "image" before "animation_url";
    /// the page is unchanged.
    function test_Json_ImageFromBase() public {
        PiecePlayer withImage = new PiecePlayer(IPlayerArtifact(address(artifact)), "ipfs://bafyexample/");
        bytes memory a = bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        bytes memory b = bytes(withImage.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(string(_between(b, '"image":"', '"')), "ipfs://bafyexample/7.png");
        assertTrue(_indexOf(b, bytes('.png","animation_url":"data:text/html;base64,'), 0) >= 0, "image precedes animation_url");
        assertEq(
            keccak256(_between(a, HTML, '","attributes":')), keccak256(_between(b, HTML, '","attributes":')), "same page"
        );
    }

    function test_ImageBase_Refused() public {
        string[5] memory bad = ['ipfs://a"b/', "ipfs://a\\b/", "ipfs://a%b/", "ipfs://a#b/", "ipfs://a\nb/"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(PiecePlayer.BadImageBase.selector);
            new PiecePlayer(IPlayerArtifact(address(artifact)), bad[i]);
        }
    }

    // ---- the living lane ---------------------------------------------------------

    function test_Living_MintTimeAtSlot254() public {
        bytes memory body = _paramsBodyOf(bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        bytes memory expected;
        for (uint256 i = 0; i < 254; i++) expected = abi.encodePacked(expected, i == 0 ? "" : ",", "0n");
        expected = abi.encodePacked(expected, ",", vm.toString(block.timestamp), "n");
        assertEq(string(body), string(expected), "254 zero slots, then the mint time");
    }

    function test_Living_KeepsArtistParams() public {
        int64[] memory p = new int64[](2);
        p[0] = -5;
        p[1] = type(int64).max;
        piece.setParams(p);
        bytes memory body = _paramsBodyOf(bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        assertEq(_prefix(body, 26), "-5n,9223372036854775807n,0", "artist params first, then zero padding");
    }

    function test_Living_NeverOverwritesSlot254() public {
        int64[] memory p = new int64[](255);
        p[254] = 42;
        piece.setParams(p);
        bytes memory body = _paramsBodyOf(bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        assertEq(uint8(body[body.length - 3]), uint8(bytes1("4")), "slot 254 keeps the artist value 42");
        assertEq(uint8(body[body.length - 2]), uint8(bytes1("2")));
    }

    function test_NotLiving_ParamsUntouched() public {
        piece.setLiving(false);
        bytes memory body = _paramsBodyOf(bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        assertEq(body.length, 0, "no params, no epoch");
    }

    // ---- refusals ------------------------------------------------------------------

    function test_UnknownToken_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IKohiPiece.KohiNoSuchToken.selector, 99));
        player.tokenURI(IKohiPiece(address(piece)), 99);
    }

    function test_BadFamily_Reverts() public {
        piece.setFamily(6);
        vm.expectRevert(abi.encodeWithSelector(PiecePlayer.BadFamily.selector, uint8(6)));
        player.tokenURI(IKohiPiece(address(piece)), TOKEN);
    }

    function test_Player_RejectsSixSegmentArtifact() public {
        address[] memory six = new address[](6);
        for (uint256 i = 0; i < 6; i++) six[i] = tmplPtrs[i];
        SixSegments old = new SixSegments(six, wasmPtrs, noisePtrs);
        vm.expectRevert(PiecePlayer.BadTemplate.selector);
        new PiecePlayer(IPlayerArtifact(address(old)), "");
    }

    function test_Artifact_RejectsBadShape() public {
        address[] memory six = new address[](6);
        for (uint256 i = 0; i < 6; i++) six[i] = tmplPtrs[i];
        vm.expectRevert(PieceArtifact.BadTemplate.selector);
        new PieceArtifact(six, wasmPtrs, keccak256(wasm), noisePtrs, keccak256(noise));
        vm.expectRevert(PieceArtifact.BadHash.selector);
        new PieceArtifact(tmplPtrs, wasmPtrs, keccak256("wrong"), noisePtrs, keccak256(noise));
        vm.expectRevert(PieceArtifact.EmptyBlob.selector);
        new PieceArtifact(tmplPtrs, new address[](0), keccak256(""), noisePtrs, keccak256(noise));
    }

    function test_Artifact_ContentHashCoversEverySegment() public {
        bytes memory acc;
        bytes[7] memory t = _pieceTemplate();
        for (uint256 i = 0; i < 7; i++) acc = abi.encodePacked(acc, keccak256(t[i]));
        assertEq(artifact.contentHash(), keccak256(abi.encodePacked(acc, keccak256(wasm), keccak256(noise))));
    }

    // ---- helpers -------------------------------------------------------------------

    function _paramsBodyOf(bytes memory json) internal pure returns (bytes memory) {
        bytes memory page = _b64decode(_between(json, HTML, '","attributes":'));
        return _between(page, "const PARAMS=[", "];");
    }

    function _chunks(bytes memory data) internal returns (address[] memory ptrs) {
        uint256 cs = StreamStore.MAX_CHUNK;
        uint256 n = (data.length + cs - 1) / cs;
        ptrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 off = i * cs;
            uint256 len = data.length - off < cs ? data.length - off : cs;
            bytes memory c = new bytes(len);
            for (uint256 j = 0; j < len; j++) c[j] = data[off + j];
            ptrs[i] = store.write(c);
        }
    }

    function _hex(string memory path) internal view returns (bytes memory) {
        return vm.parseBytes(_trim(vm.readFile(path)));
    }

    function _prefix(bytes memory b, uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[i];
        return string(out);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == 0x0a || b[n - 1] == 0x0d || b[n - 1] == 0x20)) n--;
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[i];
        return string(out);
    }

    function _between(bytes memory hay, string memory open, string memory close) internal pure returns (bytes memory out) {
        int256 s = _indexOf(hay, bytes(open), 0);
        require(s >= 0, "open marker not found");
        uint256 start = uint256(s) + bytes(open).length;
        int256 e = _indexOf(hay, bytes(close), start);
        require(e >= 0, "close marker not found");
        uint256 len = uint256(e) - start;
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) out[i] = hay[start + i];
    }

    function _indexOf(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (int256) {
        if (needle.length == 0 || hay.length < needle.length) return -1;
        uint256 end = hay.length - needle.length;
        for (uint256 i = from; i <= end; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return int256(i);
        }
        return -1;
    }

    function _b64decode(bytes memory s) internal pure returns (bytes memory out) {
        uint256 len = s.length;
        if (len == 0) return new bytes(0);
        require(len % 4 == 0, "b64 length");
        uint256 pad = 0;
        if (s[len - 1] == "=") pad++;
        if (s[len - 2] == "=") pad++;
        uint256 outLen = (len / 4) * 3 - pad;
        out = new bytes(outLen);
        bytes memory alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory rev = new bytes(256);
        for (uint256 i = 0; i < 64; i++) rev[uint8(alpha[i])] = bytes1(uint8(i));
        uint256 o = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (uint256(uint8(rev[uint8(s[i])])) << 18) | (uint256(uint8(rev[uint8(s[i + 1])])) << 12)
                | (uint256(uint8(rev[uint8(s[i + 2])])) << 6) | uint256(uint8(rev[uint8(s[i + 3])]));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 16));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 8));
            if (o < outLen) out[o++] = bytes1(uint8(n));
        }
    }
}
