// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/player/HolderSale.sol";

/*
 * DeploySale: a HolderSale for a piece that is already deployed, from the
 * piece's JSON config (saleSeller, salePrice in wei as a string, saleStart in
 * unix seconds, saleCollections).
 *
 *   PIECE_CONFIG=pieces/rakel/piece.json PIECE=<piece address>  *     forge script script/DeploySale.s.sol:DeploySale
 *
 * The sale sells nothing until the seller approves it on the piece
 * (setApprovalForAll), a transaction only the seller can make. A plain
 * `forge script` only simulates; it broadcasts with --broadcast.
 */
contract DeploySale is Script {
    function run() external {
        string memory json = vm.readFile(vm.envString("PIECE_CONFIG"));
        address piece = vm.envAddress("PIECE");
        require(piece.code.length != 0, "no contract at PIECE");
        address seller = vm.parseJsonAddress(json, ".saleSeller");
        require(seller != address(0), "the config has no saleSeller");
        address[] memory cols = vm.parseJsonAddressArray(json, ".saleCollections");
        IERC721Sale[] memory collections = new IERC721Sale[](cols.length);
        for (uint256 i = 0; i < cols.length; i++) {
            require(cols[i].code.length != 0, "a sale collection is absent on this chain");
            collections[i] = IERC721Sale(cols[i]);
        }
        uint256 price = vm.parseUint(vm.parseJsonString(json, ".salePrice"));
        uint64 start = uint64(vm.parseJsonUint(json, ".saleStart"));
        vm.startBroadcast();
        HolderSale sale = new HolderSale(msg.sender, IERC721Sale(piece), seller, collections, price, start);
        vm.stopBroadcast();
        console2.log("HolderSale", address(sale));
    }
}
