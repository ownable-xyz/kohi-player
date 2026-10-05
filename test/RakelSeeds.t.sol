// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IKVMTraitsRunner.sol";
import "../src/Attributes.sol";
import "../src/player/KohiPiece.sol";

/*
 * The curated seeds, checked on chain before they are set on the mainnet contract.
 *
 * The curation page (npm run curate:rakel) exports the ordered selection to
 * pieces/rakel/seeds.json, with each seed's traits
 * from the TypeScript reference interpreter. This suite checks:
 *   - exactly 64 seeds, no duplicate;
 *   - the on-chain traits runner, given the committed Rakel program, returns
 *     exactly the recorded traits for every seed;
 *   - Rakel.setSeeds then lockSeeds accepts the list.
 * Until the export holds 64 seeds the suite skips, so CI stays green while
 * curation is in progress.
 */
contract RakelSeedsTest is Test {
    address internal constant LIVE_TRAITS = 0xB4fdc3e8ad6fDb68D9deBcB6c4be497BBbd46218;
    string internal constant EXPORT = "pieces/rakel/seeds.json";
    IKVMTraitsRunner internal traits;
    bytes internal prog;
    string internal json;
    bool internal ready;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        traits = IKVMTraitsRunner(LIVE_TRAITS);
        prog = vm.parseBytes(_trim(vm.readFile("pieces/rakel/program.hex")));
        if (vm.exists(EXPORT)) {
            json = vm.readFile(EXPORT);
            ready = vm.parseJsonUint(json, ".count") == 64;
        }
    }

    function test_Curated_Exactly64Unique() public {
        vm.skip(!ready);
        int256[] memory seeds = vm.parseJsonIntArray(json, ".seeds");
        assertEq(seeds.length, 64, "64 seeds");
        for (uint256 i = 0; i < seeds.length; i++) {
            assertTrue(seeds[i] >= type(int32).min && seeds[i] <= type(int32).max, "int32 seed");
            for (uint256 j = i + 1; j < seeds.length; j++) assertTrue(seeds[i] != seeds[j], "duplicate seed");
        }
    }

    function test_Curated_OnChainTraitsMatchThePage() public {
        vm.skip(!ready);
        int256[] memory seeds = vm.parseJsonIntArray(json, ".seeds");
        for (uint256 i = 0; i < seeds.length; i++) {
            string[] memory want = vm.parseJsonStringArray(json, string.concat(".traits[", vm.toString(i), "]"));
            bytes memory recs = Attributes.extractTraits(traits.traitsOf(prog, int32(seeds[i]), new int64[](0), 4));
            assertEq(recs.length, 36, "four trait records");
            for (uint256 t = 0; t < 4; t++) {
                int64 v = int64(uint64(bytes8(_slice(recs, t * 9 + 1, t * 9 + 9))));
                assertEq(int256(v), vm.parseInt(want[t]), string.concat("token ", vm.toString(i + 1), " trait ", vm.toString(t)));
            }
        }
    }

    function test_Curated_ContractAcceptsTheList() public {
        vm.skip(!ready);
        int256[] memory raw = vm.parseJsonIntArray(json, ".seeds");
        int32[] memory seeds = new int32[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) seeds[i] = int32(raw[i]);
        KohiPiece rakel = new KohiPiece(
            address(this), "Rakel", "RAKEL", 64,
            KohiRenderPath({family: 3, noiseKind: 0, runner: address(1), stepRunner: address(2), renderer: address(3)}),
            address(traits)
        );
        rakel.setSeeds(seeds);
        rakel.lockSeeds();
        assertTrue(rakel.seedsLocked());
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) out[i - from] = b[i];
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == 0x0a || b[n - 1] == 0x0d || b[n - 1] == 0x20)) n--;
        return string(_slice(b, 0, n));
    }
}
