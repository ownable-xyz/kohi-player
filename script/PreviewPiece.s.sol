// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "./DeployPiece.s.sol";

/*
 * PreviewPiece: the tokenURIs a deployment would serve, as one local HTML
 * page, without deploying anything.
 *
 *   PIECE_CONFIG=pieces/rakel/piece.json \
 *     forge script script/PreviewPiece.s.sol:PreviewPiece --sig "preview()" --fork-url <mainnet rpc>
 *
 * On a fork of the chain, in simulation only (never pass --broadcast), it
 * deploys the player from assets/ and the piece from its config, exactly as
 * DeployPlayer and DeployPiece do, against the live engine. It then calls the
 * piece's tokenURI for each token in PREVIEW_TOKENS (default 1,2,3,4,17,33,49,64)
 * and writes preview/index.html. That page holds each tokenURI exactly as the
 * contract returned it, decodes it the way a marketplace does, and loads its
 * animation_url into a sandboxed iframe, so the browser renders the work from
 * the contract's own bytes.
 */
contract PreviewPiece is DeployPiece {
    string internal constant CSS =
        "body{margin:0;background:#111;color:#ddd;font:14px/1.5 system-ui,sans-serif}"
        "header{padding:24px 24px 8px}h1{margin:0 0 4px;font-size:22px}.meta{color:#999;max-width:70ch}"
        "main{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:24px;padding:24px}"
        ".card{background:#1b1b1d;border-radius:6px;overflow:hidden}"
        "iframe{display:block;width:100%;aspect-ratio:1;border:0;background:#0b0b0d}"
        ".info{padding:12px 14px}.info h2{margin:0 0 6px;font-size:16px}"
        ".attrs{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0}"
        ".attrs span{background:#26262a;border-radius:4px;padding:2px 8px;font-size:12px}"
        ".small{color:#888;font-size:12px}code{color:#aaa}";

    string internal constant NOTE =
        "<div class='small'>Each card is the contract's tokenURI, decoded as a marketplace would, with its "
        "animation_url in a sandboxed iframe (scripts only). Simulated on a mainnet fork; nothing was deployed.</div>";

    string internal constant SCRIPT =
        "<script>"
        "function decodeJsonUri(u){"
        "if(u.startsWith('data:application/json;utf8,'))return JSON.parse(u.slice(27).replace(/%23/g,'#').replace(/%25/g,'%'));"
        "if(u.startsWith('data:application/json;base64,'))return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(u.slice(29)),c=>c.charCodeAt(0))));"
        "throw new Error('unexpected URI '+u.slice(0,40));}"
        "const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));"
        "try{const c=decodeJsonUri(document.getElementById('contracturi').textContent);"
        "document.getElementById('coll').innerHTML='<b>contractURI</b>: '+esc(c.name)+' ('+esc(c.symbol)+') &middot; '+esc(c.description);}catch(e){}"
        "const grid=document.getElementById('grid');"
        "for(const s of document.querySelectorAll('section.t')){"
        "const uri=s.querySelector('script').textContent;let j;try{j=decodeJsonUri(uri);}catch(e){continue;}"
        "const card=document.createElement('div');card.className='card';"
        "const f=document.createElement('iframe');f.setAttribute('sandbox','allow-scripts');f.loading='lazy';f.src=j.animation_url;"
        "const attrs=(j.attributes||[]).map(a=>'<span>'+esc(a.trait_type)+': '+esc(a.value)+'</span>').join('');"
        "const info=document.createElement('div');info.className='info';"
        "info.innerHTML='<h2>'+esc(j.name)+'</h2><div class=attrs>'+attrs+'</div>'"
        "+'<div class=small>'+esc(j.description)+'</div>'"
        "+'<div class=small>tokenURI '+(uri.length/1024).toFixed(0)+' KB &middot; '+(s.dataset.gas/1e6).toFixed(1)+'M gas &middot; '"
        "+(('image' in j)?'image: <code>'+esc(j.image)+'</code>':'no image field')+'</div>';"
        "card.append(f,info);grid.append(card);}"
        "</script></body></html>";

    function preview() external {
        string memory json = vm.readFile(vm.envString("PIECE_CONFIG"));
        Engine memory e = _engine(uint8(vm.parseJsonUint(json, ".noiseKind")));
        if (vm.keyExists(json, ".renderer")) e.renderer = vm.parseJsonAddress(json, ".renderer");
        else require(vm.parseJsonUint(json, ".family") == 3, "set renderer for this family");

        // Simulation: without --broadcast nothing is sent.
        vm.startBroadcast();
        (PiecePlayer player,) = _deployPlayer(new BlobStore(), "");
        KohiPiece piece = _deploy(json, e);
        _art(piece, json);
        piece.setSeeds(_seeds(json));
        piece.lockSeeds();
        _mint(piece, json);
        piece.setTokenURIModule(IKohiTokenURI(address(player)));
        piece.setContractURI(_contractURI(json));
        vm.stopBroadcast();

        uint256[] memory ids = vm.envOr("PREVIEW_TOKENS", ",", _defaultTokens());
        string memory out = "preview/index.html";
        vm.createDir("preview", true);
        vm.writeFile(out, string(_head(piece)));
        // Each token is appended as it is read, so no tokenURI stays in memory.
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 g = _callGas(address(piece), ids[i]);
            string memory uri = piece.tokenURI(ids[i]);
            vm.writeLine(out, string(_item(ids[i], g, uri)));
            console2.log("tokenURI", ids[i], g, bytes(uri).length);
        }
        vm.writeLine(out, SCRIPT);
        console2.log("wrote preview/index.html");
    }

    /// The gas of tokenURI(id) as an eth_call would spend it: a staticcall
    /// that copies no return data into this frame.
    function _callGas(address piece, uint256 id) internal view returns (uint256 used) {
        bytes memory data = abi.encodeWithSignature("tokenURI(uint256)", id);
        assembly {
            let g := gas()
            let ok := staticcall(gas(), piece, add(data, 0x20), mload(data), 0, 0)
            used := sub(g, gas())
            if iszero(ok) { revert(0, 0) }
        }
    }

    function _item(uint256 id, uint256 g, string memory uri) internal pure returns (bytes memory) {
        bytes memory open = abi.encodePacked("<section class='t' data-id='", vm.toString(id), "' data-gas='", vm.toString(g));
        return abi.encodePacked(open, "'><script type='text/plain'>", uri, "</script></section>");
    }

    function _head(KohiPiece piece) internal view returns (bytes memory) {
        bytes memory top = abi.encodePacked(
            "<!doctype html><html lang='en'><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width,initial-scale=1'><title>",
            piece.name(),
            " preview</title>"
        );
        bytes memory head = abi.encodePacked(top, "<style>", CSS, "</style></head><body><header><h1>", piece.name(), "</h1>");
        return abi.encodePacked(
            head,
            "<div class='meta' id='coll'></div>",
            NOTE,
            "</header><script type='text/plain' id='contracturi'>",
            piece.contractURI(),
            "</script><main id='grid'></main>"
        );
    }

    function _defaultTokens() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](8);
        (ids[0], ids[1], ids[2], ids[3]) = (1, 2, 3, 4);
        (ids[4], ids[5], ids[6], ids[7]) = (17, 33, 49, 64);
    }
}
