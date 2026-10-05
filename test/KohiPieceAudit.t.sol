// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import "../src/player/KohiPiece.sol";
import "../src/player/PiecePlayer.sol";
import "../src/player/PiecePlayerV2.sol";
import "../src/player/PiecePlayerV3.sol";
import "../src/player/PieceArtifact.sol";
import "../src/BlobStore.sol";
import {IKohiPiece, KohiRenderPath} from "../src/player/IKohiPiece.sol";
import {IKohiTokenURI} from "../src/player/IKohiTokenURI.sol";

/// A tokenURI module that lies about the picture.
contract LyingModule is IKohiTokenURI {
    function tokenURI(IKohiPiece, uint256) external pure returns (string memory) {
        return "data:application/json;utf8,{\"name\":\"not the art\"}";
    }
}

/// A tokenURI module that refuses to answer.
contract BrickModule is IKohiTokenURI {
    function tokenURI(IKohiPiece, uint256) external pure returns (string memory) {
        revert("bricked");
    }
}

/*
 * Read-only awareness audit of the DEPLOYED Rakel KohiPiece on a mainnet fork
 * (nothing is sent anywhere). The contract cannot change; these tests pin
 * what its owner can still do, what is frozen, and that the deployed code is
 * exactly this source.
 *
 *   MAINNET_RPC_URL=... [FORK_BLOCK=n] forge test --match-contract KohiPieceAuditTest -vv
 */
contract KohiPieceAuditTest is Test {
    KohiPiece internal constant RAKEL = KohiPiece(0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18);
    address internal constant OWNER = 0xAFA08732b9A1D334686B0ca5f6D9B9C6953993B0;
    address internal constant SELLER = 0x00aa5Ba307dfE79C111df5B2f9e79d7F63458561;
    address internal constant CREATOR = 0x16cCd2a1346978e27FDCbda43569E251C4227341;
    address internal constant BLOBSTORE = 0x3f89D4cc734f90BE2dAd9d8A2e92681761607192;
    address internal constant ARTIFACT = 0x089C7092C284dE7068Ea322b0F9a293148796B32;
    address internal constant PLAYER = 0x178B2419627e4319e2383Ed7802d26eBDa206Cb3;
    address internal constant IMAGE_PLAYER = 0x5B01D7BD6f13506da108A5224d3D3Ff1DF80685B;
    address internal constant ARTIFACT_V2 = 0x9d0333740e59E641fe9F2CeeCd716d595249703a;
    address internal constant IMAGE_PLAYER_V2 = 0xc2E3898DB496dc2f72E76c08b8db1039dCcbe59B;
    address internal constant ARTIFACT_V3 = 0xB0e19C43673c281f594CBcDA85b9Ac3f199F9D64;
    address internal constant IMAGE_PLAYER_V3 = 0x5cf3D9EcDB7501899692c8F4273E2Ea4D1338624;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.rpcUrl("mainnet"));
        else vm.createSelectFork(vm.rpcUrl("mainnet"), blk);
    }

    // ---- state -------------------------------------------------------------

    function test_Rakel_StateAsDeployed() public {
        assertEq(RAKEL.owner(), OWNER);
        assertEq(RAKEL.pendingOwner(), address(0), "no ownership transfer pending");
        assertTrue(RAKEL.artLocked());
        assertTrue(RAKEL.seedsLocked());
        assertEq(RAKEL.totalSupply(), 64);
        assertEq(RAKEL.maxSupply(), 64);
        assertEq(RAKEL.creator(), CREATOR);
        assertEq(address(RAKEL.tokenURIModule()), IMAGE_PLAYER_V3, "PiecePlayerV3 serves the tokenURI");
        console2.log("tokenURILocked", RAKEL.tokenURILocked());
        console2.log("contractURILocked", RAKEL.contractURILocked());
        (address recv, uint256 fee) = RAKEL.royaltyInfo(16, 1 ether);
        assertEq(recv, SELLER);
        assertEq(fee, 0.05 ether, "5% royalty");
    }

    function test_Rakel_ArtAndSeedsMatchTheirHashesAndTheConfig() public {
        bytes memory program = RAKEL.kohiProgram();
        assertEq(keccak256(program), RAKEL.programHash());
        bytes memory local = vm.parseBytes(vm.readLine("pieces/rakel/program.hex"));
        assertEq(keccak256(program), keccak256(local), "the program on chain is pieces/rakel/program.hex");
        int32[] memory s = RAKEL.seeds();
        assertEq(keccak256(abi.encodePacked(s)), RAKEL.seedsHash());
        int256[] memory cfg = vm.parseJsonIntArray(vm.readFile("pieces/rakel/seeds.json"), ".seeds");
        assertEq(s.length, cfg.length);
        for (uint256 i = 0; i < s.length; i++) {
            assertEq(int256(s[i]), cfg[i]);
            assertEq(RAKEL.kohiSeed(i + 1), s[i]);
        }
    }

    // ---- the owner surface ---------------------------------------------------

    function test_Rakel_StrangerHasNoPowers() public {
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeCall(KohiPiece.appendProgram, (hex"00"));
        calls[1] = abi.encodeCall(KohiPiece.clearProgram, ());
        calls[2] = abi.encodeCall(KohiPiece.setParams, (new int64[](0)));
        calls[3] = abi.encodeCall(KohiPiece.setDescription, ("x"));
        calls[4] = abi.encodeCall(KohiPiece.lockArt, ());
        calls[5] = abi.encodeCall(KohiPiece.setSeeds, (new int32[](0)));
        calls[6] = abi.encodeCall(KohiPiece.lockSeeds, ());
        calls[7] = abi.encodeCall(KohiPiece.mintTo, (stranger, 1));
        calls[8] = abi.encodeCall(KohiPiece.setTokenURIModule, (IKohiTokenURI(address(0))));
        calls[9] = abi.encodeCall(KohiPiece.lockTokenURI, ());
        calls[10] = abi.encodeCall(KohiPiece.setContractURI, ("x"));
        calls[11] = abi.encodeCall(KohiPiece.lockContractURI, ());
        calls[12] = abi.encodeCall(KohiPiece.setDefaultRoyalty, (stranger, 1000));
        calls[13] = abi.encodeCall(KohiPiece.attributeCreator, (stranger, hex""));
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory err) = address(RAKEL).call(calls[i]);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        RAKEL.renounceOwnership();
    }

    function test_Rakel_OwnerCannotTouchTheArtSeedsOrSupply() public {
        vm.startPrank(OWNER);
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.appendProgram(hex"00");
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.clearProgram();
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.setParams(new int64[](1));
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.addTrait(9, 0, false, 0, "x", new string[](0));
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.clearTraits();
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.setDescription("x");
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        RAKEL.lockArt();
        vm.expectRevert(KohiPiece.SeedsAreLocked.selector);
        RAKEL.setSeeds(new int32[](64));
        vm.expectRevert(KohiPiece.SeedsAreLocked.selector);
        RAKEL.lockSeeds();
        vm.expectRevert(KohiPiece.SupplyExceeded.selector);
        RAKEL.mintTo(OWNER, 1);
        vm.expectRevert(KohiPiece.AlreadyAttributed.selector);
        RAKEL.attributeCreator(OWNER, hex"");
        vm.expectRevert(RegistryOwnable.RenounceDisabled.selector);
        RAKEL.renounceOwnership();
        vm.stopPrank();
    }

    /// The owner holds no transfer power over anyone's token.
    function test_Rakel_OwnerCannotMoveTokens() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        RAKEL.transferFrom(SELLER, OWNER, 16);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        RAKEL.transferFrom(CREATOR, OWNER, 1);
        vm.stopPrank();
    }

    /// What the owner CAN still do, while unlocked: swap the metadata module.
    /// A lying module changes what marketplaces show; a reverting one blanks
    /// tokenURI. Neither touches the art, the seeds, the hashes or ownership.
    function test_Rakel_MetadataModuleSwap_CannotTouchTheArt() public {
        // build the modules first: a `new` inside a pranked call would take the prank
        LyingModule liar = new LyingModule();
        BrickModule brick = new BrickModule();
        if (RAKEL.tokenURILocked()) {
            vm.prank(OWNER);
            vm.expectRevert(KohiPiece.TokenURIIsLocked.selector);
            RAKEL.setTokenURIModule(liar);
            return;
        }
        bytes32 ph = RAKEL.programHash();
        bytes32 sh = RAKEL.seedsHash();
        bytes32 prog = keccak256(RAKEL.kohiProgram());
        int32 seed16 = RAKEL.kohiSeed(16);
        address owner16 = RAKEL.ownerOf(16);

        vm.prank(OWNER);
        RAKEL.setTokenURIModule(liar);
        assertEq(RAKEL.tokenURI(16), "data:application/json;utf8,{\"name\":\"not the art\"}");

        vm.prank(OWNER);
        RAKEL.setTokenURIModule(brick);
        vm.expectRevert(bytes("bricked"));
        RAKEL.tokenURI(16);

        assertEq(RAKEL.programHash(), ph);
        assertEq(RAKEL.seedsHash(), sh);
        assertEq(keccak256(RAKEL.kohiProgram()), prog);
        assertEq(RAKEL.kohiSeed(16), seed16);
        assertEq(RAKEL.ownerOf(16), owner16);

        // and the lock, once pressed, is final
        vm.prank(OWNER);
        RAKEL.setTokenURIModule(IKohiTokenURI(IMAGE_PLAYER));
        vm.prank(OWNER);
        RAKEL.lockTokenURI();
        vm.prank(OWNER);
        vm.expectRevert(KohiPiece.TokenURIIsLocked.selector);
        RAKEL.setTokenURIModule(liar);
    }

    function test_Rakel_ContractURIAndRoyalty_StillMutable() public {
        vm.startPrank(OWNER);
        if (!RAKEL.contractURILocked()) {
            RAKEL.setContractURI("ipfs://other");
            assertEq(RAKEL.contractURI(), "ipfs://other");
        }
        RAKEL.setDefaultRoyalty(OWNER, 1000); // never locked, by design
        vm.stopPrank();
        (address recv, uint256 fee) = RAKEL.royaltyInfo(16, 1 ether);
        assertEq(recv, OWNER);
        assertEq(fee, 0.1 ether);
    }

    // ---- the deployed code is this source ------------------------------------

    /// Rebuild each deployed contract from this source with its on-chain
    /// constructor inputs AT its own address (so address-derived immutables
    /// match) and compare the runtime code byte for byte. A comment-only edit
    /// leaves it equal (bytecode_hash = none, cbor_metadata = false).
    function test_DeployedCode_IsThisSource_KohiPiece() public {
        bytes memory live = address(RAKEL).code;
        KohiRenderPath memory path = RAKEL.kohiRenderPath();
        bytes memory args =
            abi.encode(OWNER, RAKEL.name(), RAKEL.symbol(), RAKEL.maxSupply(), path, RAKEL.traitsRunner());
        deployCodeTo("KohiPiece.sol:KohiPiece", args, address(RAKEL));
        assertEq(keccak256(address(RAKEL).code), keccak256(live), "KohiPiece runtime code matches the source");
    }

    function test_DeployedCode_IsThisSource_Players() public {
        address[2] memory players = [PLAYER, IMAGE_PLAYER];
        for (uint256 i = 0; i < 2; i++) {
            PiecePlayer p = PiecePlayer(players[i]);
            bytes memory live = address(p).code;
            bytes memory args = abi.encode(address(p.artifact()), p.imageBase());
            deployCodeTo("PiecePlayer.sol:PiecePlayer", args, address(p));
            assertEq(keccak256(address(p).code), keccak256(live), "PiecePlayer runtime code matches the source");
        }
        assertEq(address(PiecePlayer(IMAGE_PLAYER).artifact()), ARTIFACT);
        assertEq(address(PiecePlayer(PLAYER).artifact()), ARTIFACT);
    }

    /// PiecePlayerV2 and its artifact (the transparent, fit-to-frame page),
    /// present from the block they were deployed at. Rakel does not use them:
    /// some consumers do not decode a `data:text/html,` animation_url.
    function test_DeployedCode_IsThisSource_V2() public {
        if (IMAGE_PLAYER_V2.code.length == 0) return; // a fork block before the V2 deployment
        PiecePlayerV2 p = PiecePlayerV2(IMAGE_PLAYER_V2);
        bytes memory live = IMAGE_PLAYER_V2.code;
        bytes memory args = abi.encode(address(p.artifact()), p.imageBase());
        deployCodeTo("PiecePlayerV2.sol:PiecePlayerV2", args, IMAGE_PLAYER_V2);
        assertEq(keccak256(IMAGE_PLAYER_V2.code), keccak256(live), "PiecePlayerV2 runtime code matches the source");
        assertEq(address(p.artifact()), ARTIFACT_V2);

        PieceArtifact a = PieceArtifact(ARTIFACT_V2);
        live = ARTIFACT_V2.code;
        args = abi.encode(a.htmlTemplatePointers(), a.wasmPointers(), a.blobHash(), a.noisePointers(), a.noiseHash());
        deployCodeTo("PieceArtifact.sol:PieceArtifact", args, ARTIFACT_V2);
        assertEq(keccak256(ARTIFACT_V2.code), keccak256(live), "PieceArtifact (V2) runtime code matches the source");
    }

    /// PiecePlayerV3 and its artifact (the page in base64, the wasm modules
    /// compressed with raw DEFLATE), present from the block they were
    /// deployed at. Rakel serves its tokenURI from this player.
    function test_DeployedCode_IsThisSource_V3() public {
        if (IMAGE_PLAYER_V3.code.length == 0) return; // a fork block before the V3 deployment
        PiecePlayerV3 p = PiecePlayerV3(IMAGE_PLAYER_V3);
        bytes memory live = IMAGE_PLAYER_V3.code;
        bytes memory args = abi.encode(address(p.artifact()), p.imageBase());
        deployCodeTo("PiecePlayerV3.sol:PiecePlayerV3", args, IMAGE_PLAYER_V3);
        assertEq(keccak256(IMAGE_PLAYER_V3.code), keccak256(live), "PiecePlayerV3 runtime code matches the source");
        assertEq(address(p.artifact()), ARTIFACT_V3);

        PieceArtifact a = PieceArtifact(ARTIFACT_V3);
        live = ARTIFACT_V3.code;
        args = abi.encode(a.htmlTemplatePointers(), a.wasmPointers(), a.blobHash(), a.noisePointers(), a.noiseHash());
        deployCodeTo("PieceArtifact.sol:PieceArtifact", args, ARTIFACT_V3);
        assertEq(keccak256(ARTIFACT_V3.code), keccak256(live), "PieceArtifact (V3) runtime code matches the source");
        assertEq(a.blobHash(), keccak256(vm.parseBytes(_trimmed("assets/player-wasm.deflate.hex"))), "V3 wasm is the deflate asset");
        assertEq(a.noiseHash(), keccak256(vm.parseBytes(_trimmed("assets/player-noise-wasm.deflate.hex"))), "V3 noise is the deflate asset");
    }

    function _trimmed(string memory path) internal view returns (string memory) {
        bytes memory s = bytes(vm.readFile(path));
        uint256 n = s.length;
        while (n > 0 && (s[n - 1] == 0x0a || s[n - 1] == 0x0d || s[n - 1] == 0x20)) n--;
        assembly {
            mstore(s, n)
        }
        return string(s);
    }

    function test_DeployedCode_IsThisSource_ArtifactAndBlobStore() public {
        PieceArtifact a = PieceArtifact(ARTIFACT);
        bytes memory live = ARTIFACT.code;
        bytes memory args = abi.encode(a.htmlTemplatePointers(), a.wasmPointers(), a.blobHash(), a.noisePointers(), a.noiseHash());
        deployCodeTo("PieceArtifact.sol:PieceArtifact", args, ARTIFACT);
        assertEq(keccak256(ARTIFACT.code), keccak256(live), "PieceArtifact runtime code matches the source");

        bytes memory liveStore = BLOBSTORE.code;
        deployCodeTo("BlobStore.sol:BlobStore", "", BLOBSTORE);
        assertEq(keccak256(BLOBSTORE.code), keccak256(liveStore), "BlobStore runtime code matches the source");
    }

    // ---- the player pages ------------------------------------------------------

    /// The live tokenURI resolves (the ~30M-gas view the marketplaces call).
    function test_Rakel_TokenURI_Resolves() public {
        string memory uri = RAKEL.tokenURI(16);
        bytes memory b = bytes(uri);
        assertGt(b.length, 100_000);
        bytes memory head = new bytes(29);
        for (uint256 i = 0; i < 29; i++) head[i] = b[i];
        assertEq(string(head), "data:application/json;base64,");
    }

    /// Every template segment and blob the artifact names is live code, and
    /// the content hash recomputes.
    function test_Artifact_SegmentsLive() public {
        PieceArtifact a = PieceArtifact(ARTIFACT);
        address[] memory t = a.htmlTemplatePointers();
        assertEq(t.length, 7);
        for (uint256 i = 0; i < t.length; i++) assertGt(t[i].code.length, 1);
        assertTrue(a.contentHash() != bytes32(0));
    }
}
