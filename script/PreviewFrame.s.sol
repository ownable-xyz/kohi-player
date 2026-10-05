// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BlobStore.sol";
import "../src/IPlayerArtifact.sol";
import "../src/player/PieceArtifact.sol";
import "../src/player/PiecePlayer.sol";
import "../src/player/PiecePlayerV2.sol";
import "./PieceTemplate.sol";

interface ITokenURI {
    function tokenURI(uint256) external view returns (string memory);
}

/*
 * PreviewFrame: how a piece's page sits inside marketplace frames, before and
 * after a change to page segment 0 (the head and its CSS), as one local HTML
 * page. Nothing is deployed.
 *
 *   [PREVIEW_TEMPLATE_0=<file>] \
 *     forge script script/PreviewFrame.s.sol:PreviewFrame --sig "preview()" --fork-url <mainnet rpc>
 *
 * The new segment 0 is the current page template's (PieceTemplate.sol), or
 * the bytes of the file at PREVIEW_TEMPLATE_0, to try a candidate.
 *
 * On a fork, in simulation only (never pass --broadcast), it stores the new
 * segment 0 in the live BlobStore, builds a PieceArtifact from it and the live
 * artifact's other 6 segments and both wasm blobs, and serves it from a
 * PiecePlayerV2 with the live image base. For each token in PREVIEW_TOKENS
 * (default 1,17) it writes the live tokenURI and the new one to
 * preview/frames.html. That page decodes both the way a marketplace does and
 * loads each animation_url into frames of several sizes and host colors.
 */
contract PreviewFrame is Script, PieceTemplate {
    address internal constant RAKEL = 0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18;
    address internal constant IMAGE_PLAYER = 0x5B01D7BD6f13506da108A5224d3D3Ff1DF80685B;
    address internal constant BLOB_STORE = 0x3f89D4cc734f90BE2dAd9d8A2e92681761607192;

    string internal constant HEAD =
        "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'><title>Frame preview</title><style>"
        "body{margin:0;font:14px/1.5 system-ui,sans-serif;background:#f4f4f5;color:#18181b}"
        "header{padding:24px 24px 8px;max-width:90ch}h1{margin:0 0 6px;font-size:22px}h2{margin:28px 24px 8px;font-size:18px}"
        "p{margin:4px 0;color:#52525b}code{background:#e4e4e7;border-radius:3px;padding:0 4px}"
        ".row{display:flex;flex-wrap:wrap;gap:20px;padding:8px 24px 16px;align-items:flex-start}"
        ".host{border-radius:12px;padding:14px}.host.white{background:#fff;box-shadow:0 1px 3px #0002}"
        ".host.dark{background:#18181b;color:#e4e4e7}.host.dark p{color:#a1a1aa}"
        ".host.schemedark{background:#fff;color-scheme:dark;box-shadow:0 1px 3px #0002}"
        ".label{font-size:12px;margin:0 0 6px}.pair{display:flex;gap:14px}"
        ".pair div{display:flex;flex-direction:column;gap:4px}.pair span{font-size:12px;opacity:.7}"
        "iframe{border:0;display:block;border-radius:8px}"
        ".gas{font-size:12px;color:#71717a;padding:0 24px}"
        "</style></head><body><header><h1>Frame preview: page segment 0</h1>"
        "<p><b>Before</b>: the live tokenURI, dark background (<code>#0b0b0d</code>), canvas scaled down to fit but never up.</p>"
        "<p><b>After</b>: a PiecePlayerV2 on an artifact whose segment 0 has <code>background:transparent</code> and "
        "<code>#kohi{width:100vw;height:100vh;object-fit:contain}</code>: the canvas fills the frame on its longer fit, "
        "and any letterbox shows the marketplace's own background. Everything else in the page is unchanged.</p>"
        "<p>Simulated on a mainnet fork; nothing was deployed. Each frame renders the work from the contract's own bytes, "
        "so a page with many frames takes a while.</p></header>";

    string internal constant SCRIPT =
        "<script>"
        "function decodeJsonUri(u){"
        "if(u.startsWith('data:application/json;utf8,'))return JSON.parse(u.slice(27).replace(/%23/g,'#').replace(/%25/g,'%'));"
        "if(u.startsWith('data:application/json;base64,'))return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(u.slice(29)),c=>c.charCodeAt(0))));"
        "throw new Error('unexpected URI '+u.slice(0,40));}"
        "const FRAMES=["
        "['white','Rarible-like: white page, square card',320,320],"
        "['white','white page, wide card (16:9)',480,270],"
        "['white','white page, tall card (3:4)',300,400],"
        "['white','white page, large square (above 1080 px)',1200,1200],"
        "['white','grid thumbnail',140,140],"
        "['dark','dark page, square card',320,320],"
        "['dark','dark page, wide card (16:9)',480,270],"
        "['schemedark','white card on a page that declares color-scheme: dark',320,320]];"
        "for(const s of document.querySelectorAll('section.t')){"
        "const id=s.dataset.id;const before=decodeJsonUri(s.querySelector('.before').textContent);"
        "const after=decodeJsonUri(s.querySelector('.after').textContent);"
        "const h=document.createElement('h2');h.textContent=after.name;document.body.append(h);"
        "const g=document.createElement('div');g.className='gas';"
        "g.textContent='tokenURI gas: before '+(s.dataset.gasBefore/1e6).toFixed(2)+'M, after '+(s.dataset.gasAfter/1e6).toFixed(2)+'M';"
        "document.body.append(g);const row=document.createElement('div');row.className='row';document.body.append(row);"
        "for(const [cls,label,w,hh] of FRAMES){const host=document.createElement('div');host.className='host '+cls;"
        "const p=document.createElement('p');p.className='label';p.textContent=label+' ('+w+' x '+hh+')';"
        "const pair=document.createElement('div');pair.className='pair';"
        "for(const [name,j] of [['before',before],['after',after]]){const d=document.createElement('div');"
        "const f=document.createElement('iframe');f.setAttribute('sandbox','allow-scripts');f.loading='lazy';"
        "f.width=w;f.height=hh;f.src=j.animation_url;const t=document.createElement('span');t.textContent=name;"
        "d.append(f,t);pair.append(d);}host.append(p,pair);row.append(host);}}"
        "</script></body></html>";

    function preview() external {
        string memory file = vm.envOr("PREVIEW_TEMPLATE_0", string(""));
        bytes memory seg0 = bytes(file).length == 0 ? _pieceTemplate()[0] : bytes(vm.readFile(file));
        PiecePlayer live = PiecePlayer(IMAGE_PLAYER);
        PieceArtifact a = PieceArtifact(address(live.artifact()));

        // Simulation only: these calls change the fork, never the chain.
        BlobStore store = BlobStore(BLOB_STORE);
        (address p0, bool have) = store.pointerOf(seg0);
        if (!have) p0 = store.write(seg0);
        address[] memory t = a.htmlTemplatePointers();
        t[0] = p0;
        PieceArtifact next = new PieceArtifact(t, a.wasmPointers(), a.blobHash(), a.noisePointers(), a.noiseHash());
        PiecePlayerV2 player = new PiecePlayerV2(IPlayerArtifact(address(next)), live.imageBase());
        console2.log("segment 0 bytes", seg0.length);

        uint256[] memory ids = vm.envOr("PREVIEW_TOKENS", ",", _defaultTokens());
        string memory out = "preview/frames.html";
        vm.writeFile(out, HEAD);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 gb = _callGas(RAKEL, abi.encodeWithSignature("tokenURI(uint256)", ids[i]));
            uint256 ga = _callGas(address(player), abi.encodeCall(PiecePlayerV2.tokenURI, (IKohiPiece(RAKEL), ids[i])));
            string memory before = ITokenURI(RAKEL).tokenURI(ids[i]);
            string memory afterUri = player.tokenURI(IKohiPiece(RAKEL), ids[i]);
            vm.writeLine(out, string(_item(ids[i], gb, ga, before, afterUri)));
            console2.log("token", ids[i], gb, ga);
        }
        vm.writeLine(out, SCRIPT);
        console2.log("wrote preview/frames.html");
    }

    /// The gas of a view call as an eth_call spends it: a staticcall that
    /// copies no return data into this frame.
    function _callGas(address to, bytes memory data) internal view returns (uint256 used) {
        assembly {
            let g := gas()
            let ok := staticcall(gas(), to, add(data, 0x20), mload(data), 0, 0)
            used := sub(g, gas())
            if iszero(ok) { revert(0, 0) }
        }
    }

    function _item(uint256 id, uint256 gb, uint256 ga, string memory before, string memory afterUri)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory open = abi.encodePacked(
            "<section class='t' hidden data-id='", vm.toString(id), "' data-gas-before='", vm.toString(gb),
            "' data-gas-after='", vm.toString(ga), "'>"
        );
        return abi.encodePacked(
            open,
            "<script type='text/plain' class='before'>",
            before,
            "</script><script type='text/plain' class='after'>",
            afterUri,
            "</script></section>"
        );
    }

    function _defaultTokens() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 17);
    }
}
