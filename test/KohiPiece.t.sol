// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BlobStore.sol";
import "../src/StreamStore.sol";
import "../src/player/KohiPiece.sol";
import "../src/IKVMTraitsRunner.sol";
import "../src/Attributes.sol";
import "../src/player/PieceArtifact.sol";
import "../src/player/PiecePlayer.sol";
import {IKohiPiece, KohiRenderPath} from "../src/player/IKohiPiece.sol";
import {IKohiTokenURI} from "../src/player/IKohiTokenURI.sol";
import "../script/PieceTemplate.sol";

contract StubModule is IKohiTokenURI {
    function tokenURI(IKohiPiece, uint256 tokenId) external pure returns (string memory) {
        return string.concat("stub:", vm_dec(tokenId));
    }

    function vm_dec(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) { b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b); v /= 10; }
        return string(b);
    }
}

/// A smart-contract account that approves exactly one digest (ERC-1271).
contract Mock1271 {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/*
 * KohiPiece, configured as Rakel (64 tokens, family 3): the lifecycle (art
 * and seed locks before any mint), the pre-mint to one sale address, the tokenURI module seam, and the artwork read back through
 * IKohiPiece. The program is the committed p5c build of rakel-1080.js
 * (tools/gen-rakel-golden.ts, with --check); the expected trait values come
 * from the TypeScript reference interpreter, so the live traits runner is
 * checked against an independent implementation. Runs on a mainnet fork
 * (MAINNET_RPC_URL), against the live Kohi engine.
 */
contract KohiPieceRakelTest is Test, PieceTemplate {
    // The live mainnet engine. These tests run on a mainnet fork (MAINNET_RPC_URL).
    address internal constant LIVE_RUNNER = 0x334A2E292Da5499cf955280E4DAef48852E330C6;
    address internal constant LIVE_TRAITS = 0xB4fdc3e8ad6fDb68D9deBcB6c4be497BBbd46218;
    address internal constant LIVE_RENDERER = 0x454ead37E6254101f9abe416a4Ff25CAF75cbaa1;

    KohiPiece internal rakel;
    address internal runner = LIVE_RUNNER;
    IKVMTraitsRunner internal traits = IKVMTraitsRunner(LIVE_TRAITS);
    address internal renderer = LIVE_RENDERER;
    bytes internal prog;

    address internal artist = address(0xA11CE);
    address internal collector = address(0xC011);
    address internal stepRunnerAddr = address(0x5739);

    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event TokenURIModuleSet(address module);
    event TokenURILocked(address module);
    event ProgramChunksAdded(uint256 chunks, uint256 bytesAdded);
    event TraitAdded(uint8 id, string name);
    event DescriptionSet(string description);
    event ArtLocked(bytes32 programHash);
    event SeedsSet(uint256 count);
    event SeedsLocked(bytes32 seedsHash);
    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event ContractURIUpdated();
    event ContractURILocked();
    event CreatorAttribution(bytes32 structHash, string domainName, string version, address creator, bytes signature);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        rakel = new KohiPiece(
            artist, "Rakel", "RAKEL", 64,
            KohiRenderPath({family: 3, noiseKind: 0, runner: address(runner), stepRunner: stepRunnerAddr, renderer: address(renderer)}),
            address(traits)
        );
        prog = vm.parseBytes(_trim(vm.readFile("pieces/rakel/program.hex")));
    }

    // ---- the artwork ---------------------------------------------------------------

    function test_Program_RoundTripsAcrossChunks() public {
        vm.prank(artist);
        rakel.appendProgram(prog);
        assertGt(prog.length, StreamStore.MAX_CHUNK, "Rakel is larger than one SSTORE2 contract");
        assertEq(keccak256(rakel.kohiProgram()), keccak256(prog), "program round trip");
    }

    function test_LockArt_FreezesEverything() public {
        _setArt();
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.appendProgram(hex"00");
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.clearProgram();
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.setParams(new int64[](0));
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.addTrait(9, 0, false, 0, "X", new string[](0));
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.clearTraits();
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.setDescription("changed");
        vm.expectRevert(KohiPiece.ArtIsLocked.selector);
        rakel.lockArt();
        vm.stopPrank();
        assertTrue(rakel.artLocked());
    }

    function test_LockArt_NeedsProgramAndTraits() public {
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.EmptyProgram.selector);
        rakel.lockArt();
        rakel.appendProgram(prog);
        vm.expectRevert(KohiPiece.NoTraits.selector);
        rakel.lockArt();
        vm.stopPrank();
    }

    function test_UnsafeText_Refused() public {
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.UnsafeText.selector);
        rakel.setDescription('a "quoted" word');
        vm.expectRevert(KohiPiece.UnsafeText.selector);
        rakel.setDescription("back\\slash");
        vm.expectRevert(KohiPiece.UnsafeText.selector);
        rakel.setDescription("new\nline");
        rakel.setDescription("100% fine, #1 too");
        vm.stopPrank();
    }

    // ---- seeds and minting ---------------------------------------------------------

    function test_Seeds_LockNeedsExactly64() public {
        vm.startPrank(artist);
        vm.expectRevert(abi.encodeWithSelector(KohiPiece.BadSeedCount.selector, 65));
        rakel.setSeeds(new int32[](65));
        rakel.setSeeds(_seedList(63));
        vm.expectRevert(abi.encodeWithSelector(KohiPiece.BadSeedCount.selector, 63));
        rakel.lockSeeds();
        rakel.setSeeds(_seedList(64));
        rakel.lockSeeds();
        vm.expectRevert(KohiPiece.SeedsAreLocked.selector);
        rakel.setSeeds(_seedList(64));
        vm.stopPrank();
    }

    function test_Mint_NeedsBothLocks() public {
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.ArtNotLocked.selector);
        rakel.mintTo(artist, 1);
        vm.stopPrank();
        _setArt();
        vm.prank(artist);
        vm.expectRevert(KohiPiece.SeedsNotLocked.selector);
        rakel.mintTo(artist, 1);
    }

    function test_PreMint_All64ToTheSaleAddress() public {
        _setArt();
        _setSeeds();
        vm.prank(artist);
        rakel.mintTo(collector, 64);
        assertEq(rakel.totalSupply(), 64);
        assertEq(rakel.balanceOf(collector), 64);
        assertEq(rakel.balanceOf(artist), 0);
        assertEq(rakel.ownerOf(1), collector);
        assertEq(rakel.ownerOf(64), collector);
        int32[] memory s = rakel.seeds();
        assertEq(rakel.kohiSeed(1), s[0], "token 1 gets seed 1");
        assertEq(rakel.kohiSeed(64), s[63], "token 64 gets seed 64");
        vm.prank(artist);
        vm.expectRevert(KohiPiece.SupplyExceeded.selector);
        rakel.mintTo(artist, 1);
    }

    /// mintTo continues where the last call stopped, so the pre-mint can be split across transactions.
    function test_Mint_InBatches() public {
        _setArt();
        _setSeeds();
        vm.startPrank(artist);
        rakel.mintTo(collector, 32);
        rakel.mintTo(collector, 32);
        vm.stopPrank();
        assertEq(rakel.balanceOf(collector), 64);
        assertEq(rakel.kohiSeed(33), rakel.seeds()[32]);
    }

    function test_OnlyOwner() public {
        vm.startPrank(collector);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.appendProgram(prog);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.setSeeds(_seedList(64));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.mintTo(collector, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.setTokenURIModule(IKohiTokenURI(address(1)));
        vm.stopPrank();
    }

    // ---- the tokenURI module seam --------------------------------------------------

    function test_TokenURI_ModuleSeam() public {
        _mintAll();
        vm.expectRevert(KohiPiece.NoTokenURIModule.selector);
        rakel.tokenURI(1);
        StubModule stub = new StubModule();
        vm.prank(artist);
        vm.expectEmit(address(rakel));
        emit BatchMetadataUpdate(1, 64);
        rakel.setTokenURIModule(stub);
        assertEq(rakel.tokenURI(5), "stub:5");
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        rakel.tokenURI(65);
    }

    function test_TokenURI_LockIsFinal() public {
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.NoTokenURIModule.selector);
        rakel.lockTokenURI();
        StubModule stub = new StubModule();
        rakel.setTokenURIModule(stub);
        rakel.lockTokenURI();
        vm.expectRevert(KohiPiece.TokenURIIsLocked.selector);
        rakel.setTokenURIModule(IKohiTokenURI(address(0)));
        vm.stopPrank();
        assertTrue(rakel.tokenURILocked());
    }

    /// The default module: PiecePlayer, animation_url only (no image field).
    function test_TokenURI_PiecePlayer_AnimationUrlOnly() public {
        _mintAll();
        PiecePlayer player = _piecePlayer();
        vm.prank(artist);
        rakel.setTokenURIModule(player);
        bytes memory json = bytes(rakel.tokenURI(3));
        assertEq(_slice(json, 0, 27), "data:application/json;utf8,");
        assertTrue(_contains(json, '"name":"Rakel %233"'), "name, # escaped");
        assertTrue(_contains(json, '"animation_url":"data:text/html;base64,'), "animation_url");
        assertFalse(_contains(json, '"image"'), "no image field");
    }

    // ---- the artwork through IKohiPiece --------------------------------------------

    function test_RenderPath() public {
        KohiRenderPath memory p = rakel.kohiRenderPath();
        assertEq(p.family, 3);
        assertEq(p.noiseKind, 0);
        assertEq(p.runner, address(runner));
        assertEq(p.stepRunner, stepRunnerAddr);
        assertEq(p.renderer, address(renderer));
        assertTrue(rakel.supportsInterface(type(IKohiPiece).interfaceId));
        assertTrue(rakel.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(rakel.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(rakel.supportsInterface(0x49064906), "ERC-4906");
    }

    /// The on-chain traits runner, given Rakel's program, returns the same
    /// trait values as the TypeScript reference interpreter, for every golden seed.
    function test_Traits_MatchReferenceInterpreter() public {
        string memory json = vm.readFile("test/golden/rakel-expected-traits.json");
        for (uint256 i = 0; i < 5; i++) {
            string memory at = string.concat("[", vm.toString(i), "]");
            int32 seed = int32(vm.parseJsonInt(json, string.concat(at, ".seed")));
            string[] memory want = vm.parseJsonStringArray(json, string.concat(at, ".values"));
            bytes memory recs = Attributes.extractTraits(traits.traitsOf(prog, seed, new int64[](0), 4));
            assertEq(recs.length, 36, "four 9-byte trait records");
            for (uint256 t = 0; t < 4; t++) {
                assertEq(uint8(recs[t * 9]), t, "trait id order");
                int64 v = int64(uint64(bytes8(_slice(recs, t * 9 + 1, t * 9 + 9))));
                assertEq(int256(v), vm.parseInt(want[t]), string.concat("seed ", vm.toString(int256(seed)), " trait ", vm.toString(t)));
            }
        }
    }

    /// kohiAttributes names the species and register the seed draws.
    function test_Attributes_NameTheSeedsTraits() public {
        _setArt();
        int32[] memory s = _seedList(64);
        s[0] = 7; // Monolith, Reliquary, Night, 1 pass (golden)
        s[1] = 42; // Churn, Clerestory, Daylight, 11 passes (golden)
        vm.startPrank(artist);
        rakel.setSeeds(s);
        rakel.lockSeeds();
        rakel.mintTo(artist, 2);
        vm.stopPrank();
        string memory a1 = rakel.kohiAttributes(1);
        assertTrue(_contains(bytes(a1), '"value":"Monolith"'), a1);
        assertTrue(_contains(bytes(a1), '"value":"Reliquary"'), a1);
        assertTrue(_contains(bytes(a1), '"value":"Night"'), a1);
        string memory a2 = rakel.kohiAttributes(2);
        assertTrue(_contains(bytes(a2), '"value":"Churn"'), a2);
        assertTrue(_contains(bytes(a2), '"value":"Clerestory"'), a2);
        assertTrue(_contains(bytes(a2), '"value":"Daylight"'), a2);
        emit log_named_string("attributes(seed 42)", a2);
    }

    function test_UnknownToken_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IKohiPiece.KohiNoSuchToken.selector, 1));
        rakel.kohiSeed(1);
        vm.expectRevert(abi.encodeWithSelector(IKohiPiece.KohiNoSuchToken.selector, 1));
        rakel.kohiName(1);
    }

    // ---- the constructor configuration ----------------------------------------------

    function test_Config_NameSymbolSupplyFamily() public {
        assertEq(rakel.name(), "Rakel");
        assertEq(rakel.symbol(), "RAKEL");
        assertEq(rakel.maxSupply(), 64);
        assertEq(rakel.family(), 3);
        assertEq(rakel.noiseKind(), 0);
        (, string memory domainName, string memory version,,,,) = rakel.eip712Domain();
        assertEq(domainName, "Rakel", "the EIP-712 domain carries the piece's name");
        assertEq(version, "1");
    }

    function test_Config_ASmallerPiece() public {
        KohiPiece p = new KohiPiece(
            artist, "Small", "SML", 2,
            KohiRenderPath({family: 1, noiseKind: 1, runner: address(runner), stepRunner: address(0), renderer: address(0)}),
            address(traits)
        );
        vm.startPrank(artist);
        p.appendProgram(prog);
        p.addTrait(0, 1, false, 0, "Species", new string[](0));
        p.lockArt();
        int32[] memory s2 = new int32[](2);
        (s2[0], s2[1]) = (7, 42);
        p.setSeeds(s2);
        p.lockSeeds();
        p.mintTo(collector, 2);
        vm.expectRevert(KohiPiece.SupplyExceeded.selector);
        p.mintTo(collector, 1);
        vm.stopPrank();
        assertEq(p.kohiName(2), "Small #2");
        assertEq(p.kohiRenderPath().family, 1);
    }

    function test_Config_Refused() public {
        KohiRenderPath memory ok = KohiRenderPath({family: 3, noiseKind: 0, runner: address(1), stepRunner: address(0), renderer: address(0)});
        vm.expectRevert(KohiPiece.BadConfig.selector);
        new KohiPiece(artist, "X", "X", 0, ok, address(traits));
        KohiRenderPath memory badFamily = ok;
        badFamily.family = 6;
        vm.expectRevert(KohiPiece.BadConfig.selector);
        new KohiPiece(artist, "X", "X", 1, badFamily, address(traits));
    }

    // ---- royalty (ERC-2981 defines no event) -----------------------------------------

    function test_Royalty_FivePercentToTheSaleAddress() public {
        (address r0, uint256 a0) = rakel.royaltyInfo(1, 1 ether);
        assertEq(r0, address(0), "no royalty until one is set");
        assertEq(a0, 0);
        vm.prank(artist);
        rakel.setDefaultRoyalty(collector, 500);
        (address r, uint256 a) = rakel.royaltyInfo(1, 1 ether);
        assertEq(r, collector);
        assertEq(a, 0.05 ether, "5% of the sale price");
        (, a) = rakel.royaltyInfo(64, 10_000);
        assertEq(a, 500, "the same for every token");
    }

    function test_Royalty_OwnerOnlyAndBounded() public {
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.setDefaultRoyalty(collector, 500);
        vm.startPrank(artist);
        vm.expectRevert(ERC2981.RoyaltyOverflow.selector);
        rakel.setDefaultRoyalty(collector, 10_001);
        vm.expectRevert(ERC2981.RoyaltyReceiverIsZeroAddress.selector);
        rakel.setDefaultRoyalty(address(0), 500);
        vm.stopPrank();
    }

    // ---- collection metadata (ERC-7572) ----------------------------------------------

    function test_ContractURI_SetThenLock() public {
        assertEq(rakel.contractURI(), "");
        vm.startPrank(artist);
        vm.expectEmit(address(rakel));
        emit ContractURIUpdated();
        rakel.setContractURI("data:application/json;base64,e30=");
        assertEq(rakel.contractURI(), "data:application/json;base64,e30=");
        vm.expectEmit(address(rakel));
        emit ContractURILocked();
        rakel.lockContractURI();
        vm.expectRevert(KohiPiece.ContractURIIsLocked.selector);
        rakel.setContractURI("x");
        vm.expectRevert(KohiPiece.ContractURIIsLocked.selector);
        rakel.lockContractURI();
        vm.stopPrank();
        assertTrue(rakel.contractURILocked());
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.setContractURI("x");
    }

    // ---- creator attribution (ERC-7015) --------------------------------------------

    function test_Attribution_PlainAccount() public {
        (address creatorAddr, uint256 key) = makeAddrAndKey("creator");
        _setArt();
        _setSeeds();
        bytes32 structHash = keccak256(abi.encode(rakel.ARTWORK_CREATION_TYPEHASH(), keccak256(prog), rakel.seedsHash()));
        assertEq(rakel.programHash(), keccak256(prog), "lockArt records the program hash");
        bytes memory sig = _sign(key, structHash);
        vm.prank(artist);
        vm.expectEmit(address(rakel));
        emit CreatorAttribution(structHash, "Rakel", "1", creatorAddr, sig);
        rakel.attributeCreator(creatorAddr, sig);
        assertEq(rakel.creator(), creatorAddr);
        vm.prank(artist);
        vm.expectRevert(KohiPiece.AlreadyAttributed.selector);
        rakel.attributeCreator(creatorAddr, sig);
    }

    function test_Attribution_ContractAccount() public {
        Mock1271 wallet = new Mock1271();
        _setArt();
        _setSeeds();
        bytes32 structHash = keccak256(abi.encode(rakel.ARTWORK_CREATION_TYPEHASH(), rakel.programHash(), rakel.seedsHash()));
        vm.prank(artist);
        vm.expectRevert(KohiPiece.BadSignature.selector);
        rakel.attributeCreator(address(wallet), hex"00");
        wallet.approve(_digest(structHash));
        vm.prank(artist);
        rakel.attributeCreator(address(wallet), hex"00");
        assertEq(rakel.creator(), address(wallet));
    }

    /// An account with an EIP-7702 delegation has code, yet its key still signs.
    function test_Attribution_DelegatedAccount() public {
        (address creatorAddr, uint256 key) = makeAddrAndKey("creator");
        vm.etch(creatorAddr, abi.encodePacked(hex"ef0100", address(0xdead)));
        _setArt();
        _setSeeds();
        bytes32 structHash = keccak256(abi.encode(rakel.ARTWORK_CREATION_TYPEHASH(), rakel.programHash(), rakel.seedsHash()));
        vm.prank(artist);
        rakel.attributeCreator(creatorAddr, _sign(key, structHash));
        assertEq(rakel.creator(), creatorAddr);
    }

    function test_Attribution_Refusals() public {
        (address creatorAddr, uint256 key) = makeAddrAndKey("creator");
        (, uint256 otherKey) = makeAddrAndKey("other");
        vm.prank(artist);
        vm.expectRevert(KohiPiece.ArtNotLocked.selector);
        rakel.attributeCreator(creatorAddr, "");
        _setArt();
        vm.prank(artist);
        vm.expectRevert(KohiPiece.SeedsNotLocked.selector);
        rakel.attributeCreator(creatorAddr, "");
        _setSeeds();
        bytes32 structHash = keccak256(abi.encode(rakel.ARTWORK_CREATION_TYPEHASH(), rakel.programHash(), rakel.seedsHash()));
        vm.startPrank(artist);
        vm.expectRevert(KohiPiece.BadSignature.selector);
        rakel.attributeCreator(creatorAddr, _sign(otherKey, structHash));
        vm.expectRevert(KohiPiece.BadSignature.selector);
        rakel.attributeCreator(creatorAddr, _sign(key, keccak256("a different artwork")));
        vm.expectRevert(KohiPiece.BadSignature.selector);
        rakel.attributeCreator(address(0), _sign(key, structHash));
        vm.stopPrank();
        // A valid signature is still owner-only: nobody else can claim the piece.
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, collector));
        rakel.attributeCreator(creatorAddr, _sign(key, structHash));
    }

    /// The EIP-712 digest, built here from the spec, not from the contract.
    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Rakel"),
                keccak256("1"),
                block.chainid,
                address(rakel)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    // ---- events --------------------------------------------------------------------

    /// Every owner step announces itself, and the lock events carry the hashes
    /// that pin what was frozen.
    function test_Events_TheLaunchSequence() public {
        vm.startPrank(artist);
        uint256 cs = StreamStore.MAX_CHUNK;
        vm.expectEmit(address(rakel));
        emit ProgramChunksAdded((prog.length + cs - 1) / cs, prog.length);
        rakel.appendProgram(prog);
        vm.expectEmit(address(rakel));
        emit TraitAdded(3, "Passes");
        rakel.addTrait(3, 0, false, 0, "Passes", new string[](0));
        vm.expectEmit(address(rakel));
        emit DescriptionSet("d");
        rakel.setDescription("d");
        vm.expectEmit(address(rakel));
        emit ArtLocked(keccak256(prog));
        rakel.lockArt();

        int32[] memory s = _seedList(64);
        vm.expectEmit(address(rakel));
        emit SeedsSet(64);
        rakel.setSeeds(s);
        vm.expectEmit(address(rakel));
        emit SeedsLocked(keccak256(abi.encodePacked(s)));
        rakel.lockSeeds();

        vm.expectEmit(address(rakel));
        emit Transfer(address(0), collector, 1);
        vm.expectEmit(address(rakel));
        emit Transfer(address(0), collector, 2);
        rakel.mintTo(collector, 2);

        StubModule stub = new StubModule();
        vm.expectEmit(address(rakel));
        emit TokenURIModuleSet(address(stub));
        vm.expectEmit(address(rakel));
        emit BatchMetadataUpdate(1, 64);
        rakel.setTokenURIModule(stub);
        vm.expectEmit(address(rakel));
        emit TokenURILocked(address(stub));
        rakel.lockTokenURI();
        vm.stopPrank();
    }

    // ---- helpers -------------------------------------------------------------------

    function _setArt() internal {
        vm.startPrank(artist);
        rakel.appendProgram(prog);
        string[] memory species = new string[](4);
        (species[0], species[1], species[2], species[3]) = ("Monolith", "Veil", "Crossfire", "Churn");
        string[] memory reg = new string[](11);
        (reg[0], reg[1], reg[2], reg[3], reg[4], reg[5]) = ("Kiln", "Nocturne", "Gloaming", "Willow", "Phosphor", "Reliquary");
        (reg[6], reg[7], reg[8], reg[9], reg[10]) = ("Meridian", "Orchard", "Quarry", "Auric", "Clerestory");
        string[] memory light = new string[](2);
        (light[0], light[1]) = ("Night", "Daylight");
        rakel.addTrait(0, 1, false, 0, "Species", species);
        rakel.addTrait(1, 1, false, 0, "Register", reg);
        rakel.addTrait(2, 1, false, 0, "Light", light);
        rakel.addTrait(3, 0, false, 0, "Passes", new string[](0));
        rakel.setDescription("Rakel by wattsy. A squeegee pull, stored as a KVM program.");
        rakel.lockArt();
        vm.stopPrank();
        // The labels above mirror the p5c manifest (rakel-1080.traits.json).
        string memory m = vm.readFile("pieces/rakel/traits.json");
        assertEq(vm.parseJsonString(m, "[0].name"), "Species");
        assertEq(vm.parseJsonString(m, "[1].labels[10]"), "Clerestory");
        assertEq(vm.parseJsonString(m, "[3].name"), "Passes");
    }

    function _setSeeds() internal {
        vm.startPrank(artist);
        rakel.setSeeds(_seedList(64));
        rakel.lockSeeds();
        vm.stopPrank();
    }

    function _mintAll() internal {
        _setArt();
        _setSeeds();
        vm.prank(artist);
        rakel.mintTo(artist, 64);
    }

    function _seedList(uint256 n) internal pure returns (int32[] memory s) {
        s = new int32[](n);
        for (uint256 i = 0; i < n; i++) s[i] = int32(int256(1000 + i * 7919));
    }

    function _piecePlayer() internal returns (PiecePlayer) {
        BlobStore store = new BlobStore();
        bytes[7] memory t = _pieceTemplate();
        address[] memory tp = new address[](7);
        for (uint256 i = 0; i < 7; i++) tp[i] = store.write(t[i]);
        bytes memory wasm = vm.parseBytes(_trim(vm.readFile("assets/player-wasm.hex")));
        bytes memory noise = vm.parseBytes(_trim(vm.readFile("assets/player-noise-wasm.hex")));
        PieceArtifact art = new PieceArtifact(tp, _chunks(store, wasm), keccak256(wasm), _chunks(store, noise), keccak256(noise));
        return new PiecePlayer(IPlayerArtifact(address(art)), "");
    }

    function _chunks(BlobStore store, bytes memory data) internal returns (address[] memory ptrs) {
        uint256 cs = StreamStore.MAX_CHUNK;
        uint256 n = (data.length + cs - 1) / cs;
        ptrs = new address[](n);
        for (uint256 i = 0; i < n; i++) ptrs[i] = store.write(_slice(data, i * cs, i * cs + cs < data.length ? i * cs + cs : data.length));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) out[i - from] = b[i];
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i = 0; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) if (hay[i + j] != needle[j]) { ok = false; break; }
            if (ok) return true;
        }
        return false;
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == 0x0a || b[n - 1] == 0x0d || b[n - 1] == 0x20)) n--;
        return string(_slice(b, 0, n));
    }
}
