// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/player/KohiPiece.sol";
import "../src/player/PiecePlayer.sol";
import "../src/player/PiecePlayerV3.sol";
import "../src/player/PieceArtifact.sol";
import "../src/BlobStore.sol";
import "../src/Base64.sol";
import "../src/StreamStore.sol";
import "../script/PieceTemplate.sol";

/*
 * Mainnet-fork check of PiecePlayerV3 against the live Rakel (read-only fork;
 * nothing is sent anywhere). Builds the artifact that `deploy.mjs
 * image-player --v3` builds: the current page template and the two wasm
 * modules compressed with raw DEFLATE, on the live BlobStore. Deploys
 * PiecePlayerV3 on it with the live image base, points the fork's Rakel at
 * it, and for tokens 1, 33 and 64 checks:
 *   - Rakel.tokenURI, the call a marketplace makes, fits a 50M-gas eth_call;
 *   - every byte after "data:application/json;base64," is a base64 character;
 *   - the JSON decodes to the same name, description, image and attributes as
 *     the live PiecePlayer serves, and its animation_url is
 *     "data:text/html;base64," with every byte after it a base64 character;
 *   - the page decodes to the current template with the compressed modules,
 *     the piece's program, the token's seed, the live page's params and the
 *     family. (The page decompresses each module to the exact live module;
 *     the page test of the template proves the pixels.)
 *
 *   MAINNET_RPC_URL=... FORK_BLOCK=n forge test --match-contract PiecePlayerV3ForkTest -vv
 */
contract PiecePlayerV3ForkTest is Test, PieceTemplate {
    KohiPiece internal constant RAKEL = KohiPiece(0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18);
    address internal constant OWNER = 0xAFA08732b9A1D334686B0ca5f6D9B9C6953993B0;
    address internal constant IMAGE_PLAYER = 0x5B01D7BD6f13506da108A5224d3D3Ff1DF80685B;
    address internal constant BLOB_STORE = 0x3f89D4cc734f90BE2dAd9d8A2e92681761607192;
    uint256 internal constant GAS_CAP = 50_000_000;

    PiecePlayerV3 internal v3;
    PiecePlayer internal live;
    bytes internal zWasm;
    bytes internal zNoise;

    function setUp() public {
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.rpcUrl("mainnet"));
        else vm.createSelectFork(vm.rpcUrl("mainnet"), blk);
        live = PiecePlayer(IMAGE_PLAYER);
        zWasm = vm.parseBytes(_trim(vm.readFile("assets/player-wasm.deflate.hex")));
        zNoise = vm.parseBytes(_trim(vm.readFile("assets/player-noise-wasm.deflate.hex")));
        BlobStore store = BlobStore(BLOB_STORE);
        bytes[7] memory t = _pieceTemplate();
        address[] memory tp = new address[](7);
        for (uint256 i = 0; i < 7; i++) tp[i] = _put(store, t[i]);
        address[] memory wp = _chunks(store, zWasm);
        address[] memory np = _chunks(store, zNoise);
        PieceArtifact a = new PieceArtifact(tp, wp, keccak256(zWasm), np, keccak256(zNoise));
        v3 = new PiecePlayerV3(IPlayerArtifact(address(a)), live.imageBase());
    }

    function test_Token1() public { _check(1); }
    function test_Token33() public { _check(33); }
    function test_Token64() public { _check(64); }

    function _check(uint256 id) internal {
        // The reference, read before the fork's Rakel moves to V3.
        string memory refJson = _decodeUtf8Json(bytes(live.tokenURI(IKohiPiece(address(RAKEL)), id)));

        vm.prank(OWNER);
        RAKEL.setTokenURIModule(IKohiTokenURI(address(v3)));
        uint256 gasV3 = _callGas(address(v3), abi.encodeCall(PiecePlayerV3.tokenURI, (IKohiPiece(address(RAKEL)), id)));
        uint256 gasRakel = _callGas(address(RAKEL), abi.encodeWithSignature("tokenURI(uint256)", id));
        string memory uri = RAKEL.tokenURI(id);
        emit log_named_uint("token", id);
        emit log_named_uint("  V3 tokenURI gas         ", gasV3);
        emit log_named_uint("  Rakel.tokenURI gas (V3) ", gasRakel);
        emit log_named_uint("  tokenURI bytes          ", bytes(uri).length);
        assertLt(gasRakel, GAS_CAP, "Rakel.tokenURI fits a 50M eth_call");
        _checkJson(id, uri, refJson);
    }

    function _checkJson(uint256 id, string memory uri, string memory refJson) internal {
        bytes memory b = bytes(uri);
        assertEq(string(_slice(b, 0, 29)), "data:application/json;base64,", "prefix");
        bytes memory body = _slice(b, 29, b.length);
        _assertBase64(body);
        string memory json = string(_b64decode(body));

        assertEq(vm.parseJsonString(json, ".name"), vm.parseJsonString(refJson, ".name"), "name");
        assertEq(vm.parseJsonString(json, ".description"), vm.parseJsonString(refJson, ".description"), "description");
        assertEq(vm.parseJsonString(json, ".image"), vm.parseJsonString(refJson, ".image"), "image");
        assertEq(keccak256(vm.parseJson(json, ".attributes")), keccak256(vm.parseJson(refJson, ".attributes")), "attributes");

        bytes memory url = bytes(vm.parseJsonString(json, ".animation_url"));
        assertEq(string(_slice(url, 0, 22)), "data:text/html;base64,", "animation_url prefix");
        bytes memory pageB64 = _slice(url, 22, url.length);
        _assertBase64(pageB64);
        _checkPage(id, _b64decode(pageB64), refJson);
    }

    function _checkPage(uint256 id, bytes memory page, string memory refJson) internal {
        bytes memory refUrl = bytes(vm.parseJsonString(refJson, ".animation_url"));
        bytes memory refPage = _b64decode(_slice(refUrl, 22, refUrl.length));
        bytes memory params = _between(refPage, "const PARAMS=[", "];");
        bytes[7] memory t = _pieceTemplate();
        bytes memory expected = abi.encodePacked(t[0], Base64.encode(zWasm), t[1], Base64.encode(zNoise), t[2]);
        expected = abi.encodePacked(expected, Base64.encode(RAKEL.kohiProgram()), t[3], vm.toString(int256(RAKEL.kohiSeed(id))));
        expected = abi.encodePacked(expected, t[4], params, t[5], "3", t[6]);
        assertEq(page.length, expected.length, "page length");
        assertEq(keccak256(page), keccak256(expected), "page");
    }

    function _callGas(address to, bytes memory data) internal view returns (uint256 used) {
        assembly {
            let g := gas()
            let ok := staticcall(gas(), to, add(data, 0x20), mload(data), 0, 0)
            used := sub(g, gas())
            if iszero(ok) { revert(0, 0) }
        }
    }

    function _put(BlobStore store, bytes memory data) internal returns (address) {
        (address ptr, bool have) = store.pointerOf(data);
        return have ? ptr : store.write(data);
    }

    function _chunks(BlobStore store, bytes memory data) internal returns (address[] memory ptrs) {
        uint256 cs = StreamStore.MAX_CHUNK;
        ptrs = new address[]((data.length + cs - 1) / cs);
        for (uint256 i = 0; i < ptrs.length; i++) {
            uint256 off = i * cs;
            ptrs[i] = _put(store, _slice(data, off, off + cs < data.length ? off + cs : data.length));
        }
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == 0x0a || b[n - 1] == 0x0d || b[n - 1] == 0x20)) n--;
        return string(_slice(b, 0, n));
    }

    function _between(bytes memory hay, string memory open, string memory close) internal pure returns (bytes memory) {
        bytes memory o = bytes(open);
        bytes memory c = bytes(close);
        uint256 i = _find(hay, o, 0) + o.length;
        return _slice(hay, i, _find(hay, c, i));
    }

    function _find(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        revert("marker not found");
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

    // The live player's utf8 document: undo its "%25" and "%23" escapes.
    function _decodeUtf8Json(bytes memory b) internal pure returns (string memory) {
        bytes memory body = _slice(b, 27, b.length);
        bytes memory out = new bytes(body.length);
        uint256 j;
        for (uint256 i = 0; i < body.length; i++) {
            if (body[i] == "%" && i + 2 < body.length && body[i + 1] == "2" && (body[i + 2] == "3" || body[i + 2] == "5")) {
                out[j++] = body[i + 2] == "3" ? bytes1("#") : bytes1("%");
                i += 2;
            } else {
                out[j++] = body[i];
            }
        }
        assembly {
            mstore(out, j)
        }
        return string(out);
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        assembly {
            mcopy(add(out, 0x20), add(add(b, 0x20), from), sub(to, from))
        }
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
