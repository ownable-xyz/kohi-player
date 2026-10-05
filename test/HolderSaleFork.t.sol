// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import "../src/player/HolderSale.sol";

/// The delegate.xyz v2 registry, the parts these tests use.
interface IDelegateRegistryV2 {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function delegateContract(address to, address contract_, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function delegateERC721(address to, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}

/// vm.cool (EIP-2929 reset), newer than the pinned forge-std's Vm interface.
interface ICoolCheat {
    function cool(address target) external;
}

interface IERC721View {
    function ownerOf(uint256) external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function isApprovedForAll(address, address) external view returns (bool);
    function setApprovalForAll(address, bool) external;
    function totalSupply() external view returns (uint256);
}

/*
 * Mainnet-fork end-to-end for the Rakel HolderSale (read-only fork; nothing
 * is sent anywhere). Deploys a HolderSale exactly as script/DeploySale.s.sol
 * would from pieces/rakel/piece.json against the REAL deployed Rakel, has
 * the real seller approve, warps to the start, and lets real Kohi holders
 * (EOAs, a Safe, an EIP-7702 account) buy. Uses the real delegate.xyz v2
 * registry for buyFor.
 *
 *   MAINNET_RPC_URL=... [FORK_BLOCK=n] [SALE=0x...] forge test --match-contract HolderSaleForkTest -vv
 */
contract HolderSaleForkTest is Test {
    address internal constant RAKEL = 0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18;
    address internal constant DEPLOYER = 0xAFA08732b9A1D334686B0ca5f6D9B9C6953993B0;
    address internal constant SELLER = 0x00aa5Ba307dfE79C111df5B2f9e79d7F63458561;
    address internal constant CREATOR = 0x16cCd2a1346978e27FDCbda43569E251C4227341;
    address internal constant KINTSUGI = 0xDf6e32D85d17e907e0DA157faB7C12788e7161Da;
    address internal constant CITY_LIGHTS = 0x1aBA27D6A420feb25aF6CF6b80b93B7526725a71;
    address internal constant TUM = 0xA04C6BD65E4352B30DCc6B0f21CF58aDEcc52781;
    IDelegateRegistryV2 internal constant REG = IDelegateRegistryV2(0x00000000000000447e69651d841bD8D104Bed493);

    HolderSale internal sale;
    IERC721View internal rakel = IERC721View(RAKEL);
    uint256 internal price;
    uint64 internal start;

    event Bought(
        address indexed buyer,
        address indexed holder,
        uint256 indexed tokenId,
        address collection,
        uint256 holderTokenId,
        uint256 price
    );

    function setUp() public {
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(vm.rpcUrl("mainnet"));
        else vm.createSelectFork(vm.rpcUrl("mainnet"), blk);
        // SALE=<address> runs the whole battery against a deployed sale instead
        // (launch day: after DeploySale, before and after the seller approves).
        address deployed = vm.envOr("SALE", address(0));
        sale = deployed == address(0) ? _deployLikeTheScript() : HolderSale(deployed);
        price = sale.price();
        start = sale.startTime();
    }

    /// The body of DeploySale.run(), with the deployer as msg.sender.
    function _deployLikeTheScript() internal returns (HolderSale s) {
        string memory json = vm.readFile("pieces/rakel/piece.json");
        address piece = RAKEL;
        require(piece.code.length != 0, "no contract at PIECE");
        address seller = vm.parseJsonAddress(json, ".saleSeller");
        require(seller != address(0), "the config has no saleSeller");
        address[] memory cols = vm.parseJsonAddressArray(json, ".saleCollections");
        IERC721Sale[] memory collections = new IERC721Sale[](cols.length);
        for (uint256 i = 0; i < cols.length; i++) {
            require(cols[i].code.length != 0, "a sale collection is absent on this chain");
            collections[i] = IERC721Sale(cols[i]);
        }
        uint256 p = vm.parseUint(vm.parseJsonString(json, ".salePrice"));
        uint64 st = uint64(vm.parseJsonUint(json, ".saleStart"));
        vm.prank(DEPLOYER);
        s = new HolderSale(DEPLOYER, IERC721Sale(piece), seller, collections, p, st);
    }

    function _approveAndStart() internal {
        vm.prank(SELLER);
        rakel.setApprovalForAll(address(sale), true);
        if (block.timestamp < start) vm.warp(start);
    }

    function _nextForSale() internal view returns (uint256) {
        for (uint256 id = 16; id <= 64; id++) {
            if (rakel.ownerOf(id) == SELLER) return id;
        }
        revert("sold out");
    }

    // ---- the configuration -------------------------------------------------

    function test_Fork_ConfigMatchesTheLaunchPlan() public {
        assertEq(sale.owner(), DEPLOYER);
        assertEq(address(sale.piece()), RAKEL);
        assertEq(sale.seller(), SELLER);
        assertEq(price, 0.05 ether);
        assertEq(start, 1_791_459_882, "2026-10-08 11:44:42 UTC");
        IERC721Sale[] memory cols = sale.collections();
        assertEq(cols.length, 3);
        assertEq(address(cols[0]), KINTSUGI);
        assertEq(address(cols[1]), CITY_LIGHTS);
        assertEq(address(cols[2]), TUM);
        assertFalse(sale.paused());
        assertGt(address(REG).code.length, 0, "delegate.xyz v2 is live");
    }

    function test_Fork_RakelHoldings_AsPlanned() public {
        uint256 atSeller;
        for (uint256 id = 16; id <= 64; id++) {
            if (rakel.ownerOf(id) == SELLER) atSeller++;
        }
        console2.log("tokens 16..64 still with the seller:", atSeller);
        for (uint256 id = 1; id <= 15; id++) assertEq(rakel.ownerOf(id), CREATOR, "1..15 held back by the creator");
        assertEq(rakel.totalSupply(), 64);
        assertEq(SELLER.code.length, 0, "the seller is a plain account (no 7702 code)");
    }

    /// The sale's runtime code is exactly this source, rebuilt at its own
    /// address with its own constructor inputs. Run with SALE=<deployed> on
    /// launch day before the seller approves anything.
    function test_Fork_SaleCodeIsThisSource() public {
        bytes memory live = address(sale).code;
        bytes memory args = abi.encode(
            sale.owner(), address(sale.piece()), sale.seller(), sale.collections(), sale.price(), sale.startTime()
        );
        deployCodeTo("HolderSale.sol:HolderSale", args, address(sale));
        assertEq(keccak256(address(sale).code), keccak256(live));
        console2.log("HolderSale runtime code hash:");
        console2.logBytes32(keccak256(live));
    }

    // ---- before the start --------------------------------------------------

    function test_Fork_NothingBeforeApprovalOrStart() public {
        address h = IERC721View(KINTSUGI).ownerOf(1);
        vm.deal(h, 1 ether);
        if (rakel.isApprovedForAll(SELLER, address(sale))) {
            console2.log("the seller has already approved this sale");
            vm.prank(SELLER);
            rakel.setApprovalForAll(address(sale), false);
        }
        if (block.timestamp < start) {
            vm.prank(h);
            vm.expectRevert(HolderSale.NotStarted.selector);
            sale.buy{value: price}(16, KINTSUGI, 1);
        }
        vm.warp(start - 1);
        vm.prank(h);
        vm.expectRevert(HolderSale.NotStarted.selector);
        sale.buy{value: price}(16, KINTSUGI, 1);
        vm.warp(start);
        vm.prank(h);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector); // not approved yet
        sale.buy{value: price}(16, KINTSUGI, 1);
    }

    // ---- end to end with real holders ---------------------------------------

    struct Pick {
        address c;
        uint256 id;
    }

    function test_Fork_EndToEnd_RealHolders() public {
        _approveAndStart();
        Pick[8] memory picks = [
            Pick(KINTSUGI, 1),
            Pick(CITY_LIGHTS, 2),
            Pick(TUM, 5),
            Pick(KINTSUGI, 3),
            Pick(TUM, 0), // TUM counts from 0
            Pick(KINTSUGI, 2), // the creator holds one: the creator may buy too
            Pick(CITY_LIGHTS, 100), // a Safe at the time of writing
            Pick(CITY_LIGHTS, 5) // an EIP-7702 account at the time of writing
        ];
        uint256 landed;
        for (uint256 i = 0; i < picks.length; i++) {
            address h = IERC721View(picks[i].c).ownerOf(picks[i].id);
            uint256 cs = h.code.length;
            if (sale.bought(h)) {
                console2.log("skip, wallet already bought:", h);
                continue;
            }
            uint256 tokenId = _nextForSale();
            vm.deal(h, h.balance + 1 ether);
            uint256 s0 = SELLER.balance;
            uint256 h0 = h.balance;
            vm.prank(h);
            (bool ok, bytes memory err) =
                address(sale).call{value: price}(abi.encodeCall(HolderSale.buy, (tokenId, picks[i].c, picks[i].id)));
            console2.log("holder", h);
            console2.log("  code size", cs, ok ? "BOUGHT" : "REVERTED");
            if (ok) {
                landed++;
                assertEq(rakel.ownerOf(tokenId), h, "the token landed with the holder");
                assertEq(SELLER.balance - s0, price, "the seller was paid");
                assertEq(h0 - h.balance, price);
                assertTrue(sale.bought(h) && sale.used(picks[i].c, picks[i].id));
            } else {
                // A contract wallet that cannot take ERC-721 tokens fails as a
                // whole and spends nothing; any other revert is a bug.
                assertGt(cs, 0, "an EOA purchase must not revert");
                assertEq(bytes4(err), ERC721.TransferToNonERC721ReceiverImplementer.selector);
                assertEq(rakel.ownerOf(tokenId), SELLER);
                assertFalse(sale.used(picks[i].c, picks[i].id));
            }
            assertEq(address(sale).balance, 0);
        }
        assertGe(landed, 5);
    }

    /// One wallet holding several Kohi tokens (Kintsugi #1 and City Lights #1
    /// share an owner at the time of writing) buys once.
    function test_Fork_SameWalletTwoCollections_BuysOnce() public {
        _approveAndStart();
        address h = IERC721View(KINTSUGI).ownerOf(1);
        vm.deal(h, 1 ether);
        uint256 first = _nextForSale(); // never inside a pranked call's arguments
        vm.prank(h);
        sale.buy{value: price}(first, KINTSUGI, 1);
        // find any second token this wallet holds
        if (IERC721View(CITY_LIGHTS).ownerOf(1) == h) {
            uint256 next = _nextForSale();
            vm.prank(h);
            vm.expectRevert(HolderSale.AlreadyBought.selector);
            sale.buy{value: price}(next, CITY_LIGHTS, 1);
        }
    }

    function test_Fork_SafeHolder() public {
        _approveAndStart();
        address h = IERC721View(CITY_LIGHTS).ownerOf(100);
        console2.log("CL#100 holder code size", h.code.length);
        vm.deal(h, 1 ether);
        uint256 tokenId = _nextForSale();
        vm.prank(h);
        sale.buy{value: price}(tokenId, CITY_LIGHTS, 100);
        assertEq(rakel.ownerOf(tokenId), h);
    }

    function test_Fork_7702Holder() public {
        _approveAndStart();
        address h = IERC721View(CITY_LIGHTS).ownerOf(5);
        bytes memory code = h.code;
        console2.log("CL#5 holder code size", code.length);
        if (code.length == 23) console2.logBytes(code); // 0xef0100 || delegate
        vm.deal(h, 1 ether);
        uint256 tokenId = _nextForSale();
        vm.prank(h);
        sale.buy{value: price}(tokenId, CITY_LIGHTS, 5);
        assertEq(rakel.ownerOf(tokenId), h);
    }

    // ---- buyFor against the real delegate.xyz v2 registry --------------------

    function _coldHot(address c, uint256 id, string memory hotName) internal returns (address cold, address hot) {
        cold = IERC721View(c).ownerOf(id);
        hot = makeAddr(hotName);
        vm.deal(hot, 1 ether);
    }

    function test_Fork_BuyFor_TokenDelegation() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(CITY_LIGHTS, 2, "hotT");
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 2, bytes32(0), true);
        uint256 tokenId = _nextForSale();
        vm.expectEmit(address(sale));
        emit Bought(hot, cold, tokenId, CITY_LIGHTS, 2, price);
        vm.prank(hot);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
        assertEq(rakel.ownerOf(tokenId), hot);
        assertTrue(sale.bought(hot));
        assertFalse(sale.bought(cold));
    }

    /// Real registry, real holder of two Kohi tokens: the hot wallet buys with
    /// one, the cold wallet then buys once for itself with the other, and the
    /// hot wallet cannot buy again (the limit is on the buying wallet).
    function test_Fork_BuyFor_VaultStillBuysOnceForItself() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(KINTSUGI, 1, "hotV");
        if (IERC721View(CITY_LIGHTS).ownerOf(1) != cold) return; // needs one wallet with K#1 and CL#1
        vm.prank(cold);
        REG.delegateAll(hot, bytes32(0), true);
        uint256 t1 = _nextForSale();
        vm.prank(hot);
        sale.buyFor{value: price}(t1, KINTSUGI, 1, cold);
        uint256 t2 = _nextForSale();
        vm.prank(hot);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buyFor{value: price}(t2, CITY_LIGHTS, 1, cold);
        vm.deal(cold, cold.balance + 1 ether);
        vm.prank(cold);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: price}(t2, KINTSUGI, 1);
        vm.prank(cold);
        sale.buy{value: price}(t2, CITY_LIGHTS, 1);
        assertEq(rakel.ownerOf(t1), hot);
        assertEq(rakel.ownerOf(t2), cold);
    }

    function test_Fork_BuyFor_ContractDelegation() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(TUM, 5, "hotC");
        vm.prank(cold);
        REG.delegateContract(hot, TUM, bytes32(0), true);
        uint256 tokenId = _nextForSale();
        vm.prank(hot);
        sale.buyFor{value: price}(tokenId, TUM, 5, cold);
        assertEq(rakel.ownerOf(tokenId), hot);
    }

    function test_Fork_BuyFor_AllDelegation() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(KINTSUGI, 3, "hotA");
        vm.prank(cold);
        REG.delegateAll(hot, bytes32(0), true);
        uint256 tokenId = _nextForSale();
        vm.prank(hot);
        sale.buyFor{value: price}(tokenId, KINTSUGI, 3, cold);
        assertEq(rakel.ownerOf(tokenId), hot);
        // the cold wallet itself is now spent
        vm.deal(cold, 1 ether);
        uint256 next = _nextForSale();
        vm.prank(cold);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: price}(next, KINTSUGI, 3);
    }

    function test_Fork_BuyFor_WrongToken_WrongContract_RightsScoped_None() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(CITY_LIGHTS, 2, "hotW");
        uint256 tokenId = _nextForSale();
        // none
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
        // wrong token
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 3, bytes32(0), true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
        // wrong contract
        vm.prank(cold);
        REG.delegateContract(hot, KINTSUGI, bytes32(0), true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
        // a delegation scoped to specific rights does not count as a full one
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 2, bytes32("airdrop"), true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
        // a revoked delegation stops working
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 2, bytes32(0), true);
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 2, bytes32(0), false);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(tokenId, CITY_LIGHTS, 2, cold);
    }

    /// The real registry never reports a delegation from address(0), so
    /// buyFor(vault = 0) is closed even against a collection that answered
    /// zero for a missing token (none of the three does: they revert).
    function test_Fork_Registry_NoDelegationFromZero() public {
        assertFalse(REG.checkDelegateForERC721(address(this), address(0), CITY_LIGHTS, 1, bytes32(0)));
        assertFalse(REG.checkDelegateForERC721(address(0), address(0), CITY_LIGHTS, 1, bytes32(0)));
        _approveAndStart();
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: price}(16, CITY_LIGHTS, 999_999, address(0));
    }

    function test_Fork_Collections_RevertOnMissingToken() public {
        _approveAndStart();
        address[3] memory cs = [KINTSUGI, CITY_LIGHTS, TUM];
        address h = makeAddr("anyone");
        vm.deal(h, 1 ether);
        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(); // "ERC721: owner query for nonexistent token"
            IERC721View(cs[i]).ownerOf(999_999);
            vm.prank(h);
            vm.expectRevert();
            sale.buy{value: price}(16, cs[i], 999_999);
        }
    }

    function test_Fork_HolderTokenMovedAfterUse() public {
        _approveAndStart();
        address h = IERC721View(TUM).ownerOf(5);
        vm.deal(h, 1 ether);
        uint256 first = _nextForSale();
        vm.prank(h);
        sale.buy{value: price}(first, TUM, 5);
        address next = makeAddr("nextOwner");
        vm.deal(next, 1 ether);
        vm.prank(h);
        (bool moved,) = TUM.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", h, next, 5));
        assertTrue(moved, "real TUM transfer");
        uint256 tokenId = _nextForSale();
        vm.prank(next);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: price}(tokenId, TUM, 5);
    }

    function test_Fork_SellerRevokes_StopsTheSale() public {
        _approveAndStart();
        vm.prank(SELLER);
        rakel.setApprovalForAll(address(sale), false);
        address h = IERC721View(KINTSUGI).ownerOf(1);
        vm.deal(h, 1 ether);
        uint256 tokenId = _nextForSale();
        vm.prank(h);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        sale.buy{value: price}(tokenId, KINTSUGI, 1);
    }

    // ---- gas, worst case: cold slots, first buy of the transaction ------------

    /// Cool every account the purchase touches, so the measurement is the
    /// first-buy-in-a-transaction worst case (EIP-2929 cold accesses).
    function _coolAll(address c) internal {
        ICoolCheat(address(vm)).cool(c);
        ICoolCheat(address(vm)).cool(RAKEL);
        ICoolCheat(address(vm)).cool(address(sale));
        ICoolCheat(address(vm)).cool(SELLER);
        ICoolCheat(address(vm)).cool(address(REG));
    }

    function _gasBuy(address c, uint256 id) internal returns (uint256 used) {
        _approveAndStart();
        address h = IERC721View(c).ownerOf(id);
        vm.deal(h, 1 ether);
        uint256 tokenId = 64;
        _coolAll(c);
        vm.prank(h);
        uint256 g = gasleft();
        sale.buy{value: price}(tokenId, c, id);
        used = g - gasleft();
    }

    function test_Fork_Gas_Buy_Kintsugi() public {
        uint256 g = _gasBuy(KINTSUGI, 3);
        console2.log("buy gas, Kintsugi holder (call only, excl. 21k base + calldata):", g);
        assertLt(g, 175_000);
    }

    function test_Fork_Gas_Buy_CityLights() public {
        uint256 g = _gasBuy(CITY_LIGHTS, 2);
        console2.log("buy gas, City Lights holder:", g);
        assertLt(g, 175_000);
    }

    function test_Fork_Gas_Buy_TUM() public {
        uint256 g = _gasBuy(TUM, 5);
        console2.log("buy gas, TUM holder:", g);
        assertLt(g, 175_000);
    }

    function test_Fork_Gas_BuyFor_RealRegistry_TokenDelegation() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(CITY_LIGHTS, 2, "hotG");
        vm.prank(cold);
        REG.delegateERC721(hot, CITY_LIGHTS, 2, bytes32(0), true);
        _coolAll(CITY_LIGHTS);
        vm.prank(hot);
        uint256 g = gasleft();
        sale.buyFor{value: price}(64, CITY_LIGHTS, 2, cold);
        g = g - gasleft();
        console2.log("buyFor gas, real registry, token delegation:", g);
        assertLt(g, 190_000);
    }

    function test_Fork_Gas_BuyFor_RealRegistry_AllDelegation() public {
        _approveAndStart();
        (address cold, address hot) = _coldHot(KINTSUGI, 3, "hotG2");
        vm.prank(cold);
        REG.delegateAll(hot, bytes32(0), true);
        _coolAll(KINTSUGI);
        vm.prank(hot);
        uint256 g = gasleft();
        sale.buyFor{value: price}(64, KINTSUGI, 3, cold);
        g = g - gasleft();
        console2.log("buyFor gas, real registry, all delegation:", g);
        assertLt(g, 190_000);
    }
}
