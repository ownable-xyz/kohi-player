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
import "../src/player/PiecePlayerV3.sol";
import {IKohiPiece, KohiRenderPath} from "../src/player/IKohiPiece.sol";
import "./MockKohiPiece.sol";
import "../script/PieceTemplate.sol";

/*
 * PiecePlayerV3 at real blob scale, on the same artifact and mock piece as
 * PiecePlayer.t.sol. Each check decodes the tokenURI the way a consumer does:
 * base64 for the JSON document, then base64 for the animation_url. Every byte
 * after each prefix must be a base64 character. The decoded page must equal
 * the 7 template segments joined with the expected payloads, byte for byte,
 * and equal the page that PiecePlayer serves for the same token.
 */
contract PiecePlayerV3Test is Test, PieceTemplate {
    BlobStore internal store;
    PieceArtifact internal artifact;
    PiecePlayerV3 internal player;
    PiecePlayer internal v1;
    MockKohiPiece internal piece;
    bytes internal wasm;
    bytes internal noise;
    bytes internal prog;
    int32 internal seed;
    address[] internal tmplPtrs;
    address[] internal wasmPtrs;
    address[] internal noisePtrs;

    uint256 internal constant TOKEN = 7;
    string internal constant JSON_PREFIX = "data:application/json;base64,";
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
        player = new PiecePlayerV3(IPlayerArtifact(address(artifact)), "");
        v1 = new PiecePlayer(IPlayerArtifact(address(artifact)), "");
        prog = _hex("test/golden/stamp.prog.hex");
        seed = int32(vm.parseInt(_trim(vm.readFile("test/golden/stamp.seed.txt"))));
        KohiRenderPath memory p =
            KohiRenderPath({family: 3, noiseKind: 0, runner: address(0x1), stepRunner: address(0), renderer: address(0x2)});
        piece = new MockKohiPiece(prog, new int64[](0), p);
        piece.mint(TOKEN, seed);
    }

    // ---- the page ------------------------------------------------------------------

    function test_Page_IsTheTemplateSplice() public {
        piece.setLiving(false);
        bytes memory page = _pageOf(_jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        bytes[7] memory t = _pieceTemplate();
        bytes memory expected = abi.encodePacked(t[0], Base64.encode(wasm), t[1], Base64.encode(noise), t[2]);
        expected = abi.encodePacked(expected, Base64.encode(prog), t[3], vm.toString(int256(seed)), t[4]);
        expected = abi.encodePacked(expected, t[5], "3", t[6]);
        assertEq(page.length, expected.length, "page length");
        assertEq(keccak256(page), keccak256(expected), "page != template splice");
    }

    /// The same page as PiecePlayer, for a living piece too (params at slot 254).
    function test_Page_SameAsPiecePlayer() public {
        bytes memory a = _pageOf(_jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN)));
        bytes memory b = bytes(v1.tokenURI(IKohiPiece(address(piece)), TOKEN));
        bytes memory v1Page = _b64decode(_between(b, "data:text/html;base64,", '","attributes":'));
        assertEq(keccak256(a), keccak256(v1Page), "V3 page != PiecePlayer page");
    }

    /// Every byte after each prefix is a base64 character, so the whole
    /// tokenURI is legal URI text with nothing to escape.
    function test_AllBase64() public {
        bytes memory uri = bytes(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        _assertBase64(_from(uri, bytes(JSON_PREFIX).length));
        bytes memory url = _between(_jsonOf(string(uri)), '"animation_url":"', '","attributes":');
        assertEq(_prefix(url, bytes(HTML).length), HTML, "animation_url prefix");
        _assertBase64(_from(url, bytes(HTML).length));
    }

    /// The JSON is valid for every head padding (0, 1 or 2 spaces after "{"),
    /// and the page stays the same.
    function test_Json_EveryPaddingParses() public {
        bytes32 page;
        string[3] memory d = ["A test piece", "A test piece.", "A test piece.."];
        for (uint256 i = 0; i < 3; i++) {
            piece.setDescription(d[i]);
            bytes memory json = _jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
            assertEq(vm.parseJsonString(string(json), ".description"), d[i], "description");
            assertEq(vm.parseJsonString(string(json), ".name"), "Mock #7", "name");
            bytes32 h = keccak256(_pageOf(json));
            if (i > 0) assertEq(h, page, "same page");
            page = h;
        }
    }

    function test_Gas_TokenURI() public {
        uint256 g = gasleft();
        player.tokenURI(IKohiPiece(address(piece)), TOKEN);
        uint256 g2 = g - gasleft();
        g = gasleft();
        v1.tokenURI(IKohiPiece(address(piece)), TOKEN);
        emit log_named_uint("gas(V3 tokenURI, full wasm + stamp program, living)", g2);
        emit log_named_uint("gas(PiecePlayer tokenURI, same)", g - gasleft());
    }

    // ---- the JSON ------------------------------------------------------------------

    function test_Json_IsBase64AndCarriesTheTextUnchanged() public {
        piece.setDescription("100% ink, edition #1");
        string memory uri = player.tokenURI(IKohiPiece(address(piece)), TOKEN);
        assertEq(_prefix(bytes(uri), 29), JSON_PREFIX, "prefix");
        bytes memory json = _jsonOf(uri);
        assertEq(uint8(json[0]), uint8(bytes1("{")), "JSON opens");
        assertEq(uint8(json[json.length - 1]), uint8(bytes1("}")), "JSON closes");
        assertEq(string(_between(json, '"name":"', '"')), "Mock #7", "name unchanged");
        assertEq(string(_between(json, '"description":"', '"')), "100% ink, edition #1", "description unchanged");
        assertEq(string(_between(json, '"attributes":', "}]")), '[{"trait_type":"Ink","value":"100%"', "attributes");
    }

    /// The attributes escaping of the Attributes library is undone exactly
    /// once: "%23" -> "#", "%25" -> "%", and "%2523" (a literal "%23") -> "%23".
    function test_Json_DecodesAttributesHashPercentOnce() public {
        piece.setAttributes('[{"trait_type":"No. %23","value":"50%25 / %2523 / %41 / %2"}]');
        bytes memory json = _jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(
            string(_between(json, '"attributes":', "}")),
            '[{"trait_type":"No. #","value":"50% / %23 / %41 / %2"',
            "only %23 and %25 decode, once, left to right"
        );
    }

    function test_Json_NoImageByDefault() public {
        bytes memory json = _jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(_indexOf(json, bytes('"image"'), 0), -1, "no image field");
        assertEq(bytes(player.imageBase()).length, 0);
    }

    /// A player with an image base writes "image" before "animation_url";
    /// the page is unchanged.
    function test_Json_ImageFromBase() public {
        PiecePlayerV3 withImage = new PiecePlayerV3(IPlayerArtifact(address(artifact)), "ipfs://bafyexample/");
        bytes memory a = _jsonOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        bytes memory b = _jsonOf(withImage.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(string(_between(b, '"image":"', '"')), "ipfs://bafyexample/7.png");
        assertTrue(_indexOf(b, bytes('.png","animation_url":"data:text/html;base64,'), 0) >= 0, "image precedes animation_url");
        assertEq(keccak256(_pageOf(a)), keccak256(_pageOf(b)), "same page");
    }

    function test_ImageBase_Refused() public {
        string[5] memory bad = ['ipfs://a"b/', "ipfs://a\\b/", "ipfs://a%b/", "ipfs://a#b/", "ipfs://a\nb/"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(PiecePlayerV3.BadImageBase.selector);
            new PiecePlayerV3(IPlayerArtifact(address(artifact)), bad[i]);
        }
    }

    // ---- the living lane -----------------------------------------------------------

    function test_Living_MintTimeAtSlot254() public {
        bytes memory body = _paramsBodyOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
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
        bytes memory body = _paramsBodyOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(_prefix(body, 26), "-5n,9223372036854775807n,0", "artist params first, then zero padding");
    }

    function test_NotLiving_ParamsUntouched() public {
        piece.setLiving(false);
        bytes memory body = _paramsBodyOf(player.tokenURI(IKohiPiece(address(piece)), TOKEN));
        assertEq(body.length, 0, "no params, no epoch");
    }

    // ---- refusals ------------------------------------------------------------------

    function test_UnknownToken_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IKohiPiece.KohiNoSuchToken.selector, 99));
        player.tokenURI(IKohiPiece(address(piece)), 99);
    }

    function test_BadFamily_Reverts() public {
        piece.setFamily(6);
        vm.expectRevert(abi.encodeWithSelector(PiecePlayerV3.BadFamily.selector, uint8(6)));
        player.tokenURI(IKohiPiece(address(piece)), TOKEN);
    }

    function test_EmptySegment_Reverts() public {
        address[] memory t = new address[](7);
        for (uint256 i = 0; i < 7; i++) t[i] = tmplPtrs[i];
        t[3] = address(new EmptyCode());
        BareArtifact bare = new BareArtifact(t, wasmPtrs, noisePtrs);
        PiecePlayerV3 p = new PiecePlayerV3(IPlayerArtifact(address(bare)), "");
        vm.expectRevert(PiecePlayerV3.EmptySegment.selector);
        p.tokenURI(IKohiPiece(address(piece)), TOKEN);
    }

    function test_Player_RejectsSixSegmentArtifact() public {
        address[] memory six = new address[](6);
        for (uint256 i = 0; i < 6; i++) six[i] = tmplPtrs[i];
        BareArtifact old = new BareArtifact(six, wasmPtrs, noisePtrs);
        vm.expectRevert(PiecePlayerV3.BadTemplate.selector);
        new PiecePlayerV3(IPlayerArtifact(address(old)), "");
    }

    // ---- helpers -------------------------------------------------------------------

    function _jsonOf(string memory uri) internal pure returns (bytes memory) {
        bytes memory b = bytes(uri);
        uint256 n = bytes(JSON_PREFIX).length;
        bytes memory body = new bytes(b.length - n);
        for (uint256 i = 0; i < body.length; i++) body[i] = b[n + i];
        return _b64decode(body);
    }

    function _pageOf(bytes memory json) internal pure returns (bytes memory) {
        return _b64decode(_between(json, HTML, '","attributes":'));
    }

    function _from(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(b.length - n);
        for (uint256 i = 0; i < out.length; i++) out[i] = b[n + i];
    }

    function _assertBase64(bytes memory s) internal pure {
        require(s.length % 4 == 0, "base64 length");
        for (uint256 i = 0; i < s.length; i++) {
            bytes1 c = s[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "+" || c == "/"
                || (c == "=" && i + 2 >= s.length);
            require(ok, "non-base64 byte");
        }
    }

    function _paramsBodyOf(string memory uri) internal pure returns (bytes memory) {
        return _between(_pageOf(_jsonOf(uri)), "const PARAMS=[", "];");
    }

    function _isHex(bytes1 c) internal pure returns (bool) {
        return (c >= "0" && c <= "9") || (c >= "A" && c <= "F");
    }

    function _hexVal(bytes1 c) internal pure returns (uint8) {
        return c <= "9" ? uint8(c) - 48 : uint8(c) - 55;
    }

    function _percentDecode(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length);
        uint256 j;
        for (uint256 i = 0; i < s.length; i++) {
            if (s[i] == "%") {
                out[j++] = bytes1(_hexVal(s[i + 1]) * 16 + _hexVal(s[i + 2]));
                i += 2;
            } else {
                out[j++] = s[i];
            }
        }
        assembly {
            mstore(out, j)
        }
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

/// An artifact with any template list, for the shape and segment refusals.
contract BareArtifact {
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

/// A contract whose code is the single SSTORE2 STOP byte: a segment with no data.
contract EmptyCode {
    constructor() {
        assembly {
            mstore(0, 0)
            return(0, 1)
        }
    }
}
