// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import "../src/player/HolderSale.sol";
import "./SaleAuditMocks.sol";

/*
 * Pre-launch audit battery for HolderSale (2026-10-05). Mirrors the Rakel
 * layout: tokens 1..15 with the creator, 16..64 with the seller, three
 * listed holder collections. Each test tries to break one rule.
 */
contract HolderSaleAuditTest is Test {
    AuditNFT internal piece;
    AuditNFT internal kintsugi;
    AuditNFT internal cityLights;
    AuditNFT internal tum;
    AuditNFT internal other;
    HolderSale internal sale;
    AuditDelegates internal registry;

    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal creator = makeAddr("creator");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant PRICE = 0.1 ether;
    uint64 internal constant START = 1_791_459_882; // 2026-10-08 11:44:42 UTC

    function setUp() public {
        piece = new AuditNFT();
        kintsugi = new AuditNFT();
        cityLights = new AuditNFT();
        tum = new AuditNFT();
        other = new AuditNFT();
        sale = _newSale(seller, PRICE, START);
        for (uint256 id = 1; id <= 15; id++) piece.mint(creator, id);
        for (uint256 id = 16; id <= 64; id++) piece.mint(seller, id);
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), true);
        vm.etch(address(sale.DELEGATES()), address(new AuditDelegates()).code);
        registry = AuditDelegates(address(sale.DELEGATES()));
        cityLights.mint(holder, 7);
        vm.deal(holder, 100 ether);
        vm.deal(stranger, 100 ether);
        vm.warp(START);
    }

    function _newSale(address seller_, uint256 price_, uint64 start_) internal returns (HolderSale) {
        IERC721Sale[] memory cols = new IERC721Sale[](3);
        cols[0] = IERC721Sale(address(kintsugi));
        cols[1] = IERC721Sale(address(cityLights));
        cols[2] = IERC721Sale(address(tum));
        return new HolderSale(owner, IERC721Sale(address(piece)), seller_, cols, price_, start_);
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly { s := mload(add(err, 0x20)) }
    }

    // =========================================================================
    //  Reentrancy: a hostile buyer re-enters from onERC721Received
    // =========================================================================

    function _armedBuyer(Reenter m, address c, uint256 otherToken, uint256 otherHolder, address vault)
        internal
        returns (ReentrantBuyer b)
    {
        b = new ReentrantBuyer(sale);
        vm.deal(address(b), 10 ether); // funds the inner call
        b.arm(m, c, otherToken, otherHolder, vault);
    }

    function test_Reenter_Buyer_SameTokenSameHolderToken() public {
        ReentrantBuyer b = _armedBuyer(Reenter.SameTokenSameHolder, address(kintsugi), 0, 8, address(0));
        kintsugi.mint(address(b), 8);
        uint256 s0 = seller.balance;
        b.buy{value: PRICE}(20, address(kintsugi), 8);
        assertFalse(b.innerOk());
        assertEq(_sel(b.innerErr()), HolderSale.TokenAlreadyUsed.selector);
        assertEq(piece.ownerOf(20), address(b));
        assertEq(seller.balance - s0, PRICE, "paid once");
        assertEq(address(sale).balance, 0);
    }

    function test_Reenter_Buyer_OtherTokenSameHolderToken() public {
        ReentrantBuyer b = _armedBuyer(Reenter.OtherTokenSameHolder, address(kintsugi), 21, 8, address(0));
        kintsugi.mint(address(b), 8);
        b.buy{value: PRICE}(20, address(kintsugi), 8);
        assertFalse(b.innerOk());
        assertEq(_sel(b.innerErr()), HolderSale.TokenAlreadyUsed.selector);
        assertEq(piece.ownerOf(21), seller, "the second token did not move");
    }

    function test_Reenter_Buyer_OtherTokenOtherHolderToken() public {
        ReentrantBuyer b = _armedBuyer(Reenter.OtherTokenOtherHolder, address(tum), 21, 9, address(0));
        kintsugi.mint(address(b), 8);
        tum.mint(address(b), 9);
        b.buy{value: PRICE}(20, address(kintsugi), 8);
        assertFalse(b.innerOk());
        assertEq(_sel(b.innerErr()), HolderSale.AlreadyBought.selector, "one purchase per wallet, even re-entered");
        assertFalse(sale.used(address(tum), 9), "the second holder token is not spent");
        assertEq(piece.ownerOf(21), seller);
    }

    function test_Reenter_Buyer_BuyForSelfAsVault() public {
        ReentrantBuyer b = _armedBuyer(Reenter.BuyForSelfVault, address(tum), 21, 9, address(0));
        kintsugi.mint(address(b), 8);
        tum.mint(address(b), 9);
        b.buy{value: PRICE}(20, address(kintsugi), 8);
        assertFalse(b.innerOk());
        assertEq(_sel(b.innerErr()), HolderSale.AlreadyBought.selector);
    }

    /// A vault that delegated to the buyer contract: the re-entered buyFor is
    /// a second purchase by the SAME buying wallet, so it fails AlreadyBought
    /// and spends nothing (the limit is on the buying wallet).
    function test_Reenter_Buyer_BuyForDelegatingVault_SecondPurchaseRefused() public {
        address vault = makeAddr("vault");
        tum.mint(vault, 9);
        ReentrantBuyer b = _armedBuyer(Reenter.BuyForOtherVault, address(tum), 21, 9, vault);
        kintsugi.mint(address(b), 8);
        vm.prank(vault);
        registry.delegateAll(address(b), true);
        uint256 s0 = seller.balance;
        b.buy{value: PRICE}(20, address(kintsugi), 8);
        assertFalse(b.innerOk(), "one purchase per buying wallet, even re-entered through a delegation");
        assertEq(_sel(b.innerErr()), HolderSale.AlreadyBought.selector);
        assertEq(piece.ownerOf(20), address(b));
        assertEq(piece.ownerOf(21), seller, "the second token did not move");
        assertEq(seller.balance - s0, PRICE, "paid once");
        assertTrue(sale.bought(address(b)));
        assertFalse(sale.bought(vault), "the vault keeps its own purchase");
        assertFalse(sale.used(address(tum), 9), "the vault's token is not spent");
        assertEq(address(sale).balance, 0);
    }

    // =========================================================================
    //  Reentrancy: a hostile seller re-enters from receive()
    // =========================================================================

    function _hostileSellerSale() internal returns (ReentrantSeller rs, HolderSale s2) {
        rs = new ReentrantSeller();
        s2 = _newSale(address(rs), PRICE, START);
        piece.mint(address(rs), 100);
        piece.mint(address(rs), 101);
        rs.approve(address(piece), address(s2));
    }

    function test_Reenter_Seller_BuysItsOwnTokenWithItsOwnHolderToken() public {
        (ReentrantSeller rs, HolderSale s2) = _hostileSellerSale();
        kintsugi.mint(address(rs), 50);
        rs.arm(101, address(kintsugi), 50);
        vm.prank(holder);
        s2.buy{value: PRICE}(100, address(cityLights), 7);
        assertTrue(rs.innerOk(), "the seller spent its own allocation on its own token");
        assertEq(piece.ownerOf(100), holder);
        assertEq(piece.ownerOf(101), address(rs), "self-purchase leaves the token where it was");
        assertEq(address(rs).balance, PRICE, "net: one payment from the real buyer");
        assertTrue(s2.bought(holder) && s2.bought(address(rs)));
        assertEq(address(s2).balance, 0);
    }

    function test_Reenter_Seller_CannotSpendTheBuyersHolderToken() public {
        (ReentrantSeller rs, HolderSale s2) = _hostileSellerSale();
        rs.arm(101, address(cityLights), 7);
        vm.prank(holder);
        s2.buy{value: PRICE}(100, address(cityLights), 7);
        assertFalse(rs.innerOk());
        assertEq(_sel(rs.innerErr()), HolderSale.NotTheHolder.selector);
        assertEq(piece.ownerOf(101), address(rs));
    }

    // =========================================================================
    //  Every guard, in order
    // =========================================================================

    /// One call that breaks every rule; fix them one at a time and watch the
    /// errors arrive in the documented order.
    function test_Guards_Order_Buy() public {
        address who = makeAddr("who");
        vm.deal(who, 10 ether);
        vm.prank(owner);
        sale.setPaused(true);
        vm.warp(START - 1);
        // used + bought set up by an earlier legitimate purchase of a token `who` will own
        kintsugi.mint(who, 1);
        vm.prank(seller);
        piece.transferFrom(seller, creator, 64); // 64 not for sale

        vm.startPrank(who);
        vm.expectRevert(HolderSale.IsPaused.selector);
        sale.buy{value: 1}(64, address(other), 99);
        vm.stopPrank();
        vm.prank(owner);
        sale.setPaused(false);

        vm.prank(who);
        vm.expectRevert(HolderSale.NotStarted.selector);
        sale.buy{value: 1}(64, address(other), 99);
        vm.warp(START);

        vm.prank(who);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: 1}(64, address(other), 99);

        vm.prank(who);
        vm.expectRevert(HolderSale.NotACollection.selector);
        sale.buy{value: PRICE}(64, address(other), 99);

        vm.prank(who);
        vm.expectRevert(HolderSale.NotTheHolder.selector);
        sale.buy{value: PRICE}(64, address(cityLights), 7);

        // make CL#7 used by the holder, then hand it to `who`
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        vm.prank(holder);
        cityLights.transferFrom(holder, who, 7);
        vm.prank(who);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(64, address(cityLights), 7);

        // `who` buys once with K#1, then tries a fresh token
        vm.prank(who);
        sale.buy{value: PRICE}(17, address(kintsugi), 1);
        kintsugi.mint(who, 2);
        vm.prank(who);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buy{value: PRICE}(64, address(kintsugi), 2);

        address fresh = makeAddr("fresh");
        vm.deal(fresh, 1 ether);
        vm.prank(who);
        kintsugi.transferFrom(who, fresh, 2);
        vm.prank(fresh);
        vm.expectRevert(HolderSale.NotForSale.selector);
        sale.buy{value: PRICE}(64, address(kintsugi), 2);

        vm.prank(fresh);
        sale.buy{value: PRICE}(18, address(kintsugi), 2);
        assertEq(piece.ownerOf(18), fresh);
    }

    /// buyFor checks the delegation BEFORE anything else, even the pause.
    function test_Guards_Order_BuyFor_DelegationFirst() public {
        vm.prank(owner);
        sale.setPaused(true);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: 0}(1, address(other), 1, holder);
        // with vault == msg.sender the delegation is skipped and the pause shows
        vm.prank(stranger);
        vm.expectRevert(HolderSale.IsPaused.selector);
        sale.buyFor{value: 0}(1, address(other), 1, stranger);
    }

    function test_StartBoundary() public {
        vm.warp(START - 1);
        vm.prank(holder);
        vm.expectRevert(HolderSale.NotStarted.selector);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        vm.warp(START);
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        kintsugi.mint(stranger, 1);
        vm.warp(START + 1);
        vm.prank(stranger);
        sale.buy{value: PRICE}(17, address(kintsugi), 1);
    }

    function test_ExactPrice_AndZeroPrice() public {
        vm.startPrank(holder);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: PRICE - 1}(16, address(cityLights), 7);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: PRICE + 1}(16, address(cityLights), 7);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: 0}(16, address(cityLights), 7);
        vm.stopPrank();

        vm.prank(owner);
        sale.setPrice(0);
        vm.prank(holder);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: 1}(16, address(cityLights), 7);
        uint256 s0 = seller.balance;
        vm.prank(holder);
        sale.buy{value: 0}(16, address(cityLights), 7);
        assertEq(piece.ownerOf(16), holder, "price 0 is a free claim");
        assertEq(seller.balance, s0);
    }

    function test_NotForSale_HeldBack_Sold_Nonexistent() public {
        for (uint256 id = 1; id <= 15; id++) {
            vm.prank(holder);
            vm.expectRevert(HolderSale.NotForSale.selector);
            sale.buy{value: PRICE}(id, address(cityLights), 7);
        }
        vm.prank(holder);
        sale.buy{value: PRICE}(40, address(cityLights), 7);
        kintsugi.mint(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotForSale.selector);
        sale.buy{value: PRICE}(40, address(kintsugi), 1);
        vm.prank(stranger);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        sale.buy{value: PRICE}(65, address(kintsugi), 1);
        vm.prank(stranger);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        sale.buy{value: PRICE}(0, address(kintsugi), 1);
    }

    function test_ApprovalRevokedMidSale_ThenRestored() public {
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), false);
        kintsugi.mint(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        sale.buy{value: PRICE}(17, address(kintsugi), 1);
        assertFalse(sale.used(address(kintsugi), 1), "a failed buy spends nothing");
        assertFalse(sale.bought(stranger));
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), true);
        vm.prank(stranger);
        sale.buy{value: PRICE}(17, address(kintsugi), 1);
    }

    function test_SellerMovesTokenAwayMidSale() public {
        vm.prank(seller);
        piece.transferFrom(seller, creator, 30);
        vm.prank(holder);
        vm.expectRevert(HolderSale.NotForSale.selector);
        sale.buy{value: PRICE}(30, address(cityLights), 7);
    }

    /// PROCEDURE RISK: any token that later lands back in the seller wallet
    /// (a held-back token moved there, a bought-back token) is for sale again
    /// at the sale price while the sale is unpaused and approved.
    function test_SellerReacquiredToken_IsForSaleAgain() public {
        vm.prank(creator);
        piece.transferFrom(creator, seller, 3);
        vm.prank(holder);
        sale.buy{value: PRICE}(3, address(cityLights), 7);
        assertEq(piece.ownerOf(3), holder, "a held-back token sold at the sale price");
    }

    // =========================================================================
    //  Holder tokens and holder collections
    // =========================================================================

    function test_HolderTokenMovedAfterUse_CannotBeReused() public {
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        address next = makeAddr("next");
        vm.deal(next, 1 ether);
        vm.prank(holder);
        cityLights.transferFrom(holder, next, 7);
        vm.prank(next);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(17, address(cityLights), 7);
        // and back again: the original wallet is spent too
        vm.prank(next);
        cityLights.transferFrom(next, holder, 7);
        vm.prank(holder);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(17, address(cityLights), 7);
        // the new owner can still buy with an unused token
        tum.mint(next, 0);
        vm.prank(next);
        sale.buy{value: PRICE}(17, address(tum), 0);
    }

    function test_BurnedOrMissingHolderToken_RevertsInTheCollection() public {
        vm.prank(stranger);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        sale.buy{value: PRICE}(16, address(kintsugi), 12345);
    }

    /// A listed collection whose ownerOf answers zero for a missing token: a
    /// plain buy cannot match (msg.sender is never zero); buyFor with
    /// vault = 0 is stopped only by the registry refusing from = 0.
    function test_ZeroOwnerCollection_VaultZero() public {
        ZeroOwnerNFT z = new ZeroOwnerNFT();
        IERC721Sale[] memory cols = new IERC721Sale[](1);
        cols[0] = IERC721Sale(address(z));
        HolderSale s2 = new HolderSale(owner, IERC721Sale(address(piece)), seller, cols, PRICE, START);
        vm.prank(seller);
        piece.setApprovalForAll(address(s2), true);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotTheHolder.selector);
        s2.buy{value: PRICE}(16, address(z), 777);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        s2.buyFor{value: PRICE}(16, address(z), 777, address(0));
        // Only if the registry ever said address(0) delegated would it pass.
        vm.prank(address(0));
        registry.delegateAll(stranger, true);
        vm.prank(stranger);
        s2.buyFor{value: PRICE}(16, address(z), 777, address(0));
        assertTrue(s2.bought(stranger), "the buying wallet is spent");
        assertTrue(s2.used(address(z), 777), "and so is the phantom holder token: it buys only once");
        address other2 = makeAddr("other2");
        vm.deal(other2, 1 ether);
        vm.prank(address(0));
        registry.delegateAll(other2, true);
        vm.prank(other2);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        s2.buyFor{value: PRICE}(17, address(z), 777, address(0));
    }

    function test_RevertingCollection_BubblesUp() public {
        RevertingNFT r = new RevertingNFT();
        IERC721Sale[] memory cols = new IERC721Sale[](1);
        cols[0] = IERC721Sale(address(r));
        HolderSale s2 = new HolderSale(owner, IERC721Sale(address(piece)), seller, cols, PRICE, START);
        vm.prank(stranger);
        vm.expectRevert(bytes("nope"));
        s2.buy{value: PRICE}(16, address(r), 1);
        vm.expectRevert(bytes("nope"));
        s2.isHolder(stranger);
    }

    // =========================================================================
    //  buyFor and delegate.xyz
    // =========================================================================

    function test_BuyFor_VaultIsSender_NoRegistryNeeded() public {
        vm.etch(address(sale.DELEGATES()), hex""); // no registry at all
        vm.prank(holder);
        sale.buyFor{value: PRICE}(16, address(cityLights), 7, holder);
        assertEq(piece.ownerOf(16), holder);
    }

    function test_BuyFor_EachDelegationKind() public {
        address[3] memory colds = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
        address[3] memory hots = [makeAddr("h0"), makeAddr("h1"), makeAddr("h2")];
        for (uint256 i = 0; i < 3; i++) {
            kintsugi.mint(colds[i], 100 + i);
            vm.deal(hots[i], 1 ether);
        }
        vm.prank(colds[0]);
        registry.delegateAll(hots[0], true);
        vm.prank(colds[1]);
        registry.delegateContract(hots[1], address(kintsugi), true);
        vm.prank(colds[2]);
        registry.delegateToken(hots[2], address(kintsugi), 102, true);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(hots[i]);
            sale.buyFor{value: PRICE}(20 + i, address(kintsugi), 100 + i, colds[i]);
            assertEq(piece.ownerOf(20 + i), hots[i], "the purchase goes to the hot wallet");
            assertTrue(sale.bought(hots[i]), "the buying (hot) wallet is spent");
            assertFalse(sale.bought(colds[i]), "the cold wallet is only the holder");
            assertTrue(sale.used(address(kintsugi), 100 + i), "the holder token is spent");
        }
    }

    function test_BuyFor_WrongTokenOrWrongContract() public {
        address cold = makeAddr("cold");
        address hot = makeAddr("hot");
        vm.deal(hot, 1 ether);
        kintsugi.mint(cold, 5);
        kintsugi.mint(cold, 6);
        cityLights.mint(cold, 5);
        vm.prank(cold);
        registry.delegateToken(hot, address(kintsugi), 6, true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: PRICE}(20, address(kintsugi), 5, cold);
        vm.prank(cold);
        registry.delegateContract(hot, address(tum), true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: PRICE}(20, address(cityLights), 5, cold);
        // a delegation for a token the vault does not own passes the registry
        // but not the holder check
        vm.prank(cold);
        registry.delegateToken(hot, address(kintsugi), 999, true);
        kintsugi.mint(stranger, 999);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotTheHolder.selector);
        sale.buyFor{value: PRICE}(20, address(kintsugi), 999, cold);
    }

    function test_BuyFor_NoDelegation() public {
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: PRICE}(16, address(cityLights), 7, holder);
    }

    /// Hot and cold both try: one purchase per BUYING wallet and one per
    /// holder token, whichever wallet sends it.
    function test_BuyFor_HotAndColdBothTry() public {
        address cold = holder;
        address hot = makeAddr("hot");
        vm.deal(hot, 1 ether);
        kintsugi.mint(cold, 40);
        tum.mint(hot, 3);
        vm.prank(cold);
        registry.delegateAll(hot, true);
        vm.prank(cold);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        // the cold wallet's used token buys for no one
        vm.prank(hot);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buyFor{value: PRICE}(17, address(cityLights), 7, cold);
        // the hot wallet is a different buying wallet: one purchase, with an unused cold token
        vm.prank(hot);
        sale.buyFor{value: PRICE}(17, address(kintsugi), 40, cold);
        assertEq(piece.ownerOf(17), hot);
        // and then neither wallet buys again, by any route
        vm.prank(hot);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buy{value: PRICE}(18, address(tum), 3);
        cityLights.mint(cold, 41);
        vm.prank(cold);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buy{value: PRICE}(18, address(cityLights), 41);
        vm.prank(cold);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(18, address(kintsugi), 40);
        assertEq(piece.balanceOf(hot), 1);
        assertEq(piece.balanceOf(cold), 1);
    }

    /// REGRESSION (L-1 fixed): two delegates of one shared vault (an escrow,
    /// a staking or lending contract), each with their own holder token, both
    /// buy. The vault no longer has one purchase for everyone in it.
    function test_L1Fixed_SharedVault_EachDelegateBuys() public {
        address escrow = makeAddr("escrow");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        cityLights.mint(escrow, 100);
        cityLights.mint(escrow, 101);
        vm.startPrank(escrow);
        registry.delegateToken(alice, address(cityLights), 100, true);
        registry.delegateToken(bob, address(cityLights), 101, true);
        vm.stopPrank();
        uint256 s0 = seller.balance;
        vm.prank(alice);
        sale.buyFor{value: PRICE}(20, address(cityLights), 100, escrow);
        vm.prank(bob);
        sale.buyFor{value: PRICE}(21, address(cityLights), 101, escrow);
        assertEq(piece.ownerOf(20), alice);
        assertEq(piece.ownerOf(21), bob);
        assertEq(seller.balance - s0, 2 * PRICE);
        assertTrue(sale.used(address(cityLights), 100) && sale.used(address(cityLights), 101));
        assertFalse(sale.bought(escrow), "the shared vault is only the holder");
        // each delegate still buys once
        cityLights.mint(escrow, 102);
        vm.prank(escrow);
        registry.delegateToken(alice, address(cityLights), 102, true);
        vm.prank(alice);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buyFor{value: PRICE}(22, address(cityLights), 102, escrow);
    }

    /// A wallet that bought for itself cannot then buy again through buyFor
    /// for a vault that delegated to it; the vault's token stays unspent.
    function test_BoughtForSelf_ThenBuyForVault_AlreadyBought() public {
        address vault = makeAddr("vaultX");
        tum.mint(vault, 9);
        vm.prank(vault);
        registry.delegateAll(holder, true);
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        vm.prank(holder);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buyFor{value: PRICE}(17, address(tum), 9, vault);
        assertFalse(sale.used(address(tum), 9));
        assertEq(piece.ownerOf(17), seller);
    }

    /// A vault that delegated can still buy once for itself, with a different
    /// holder token: the vault and its delegate are different buying wallets.
    /// Then both are spent.
    function test_DelegatingVault_StillBuysOnceForItself() public {
        address vault = makeAddr("vaultY");
        address hot = makeAddr("hotY");
        vm.deal(vault, 1 ether);
        vm.deal(hot, 1 ether);
        kintsugi.mint(vault, 60);
        kintsugi.mint(vault, 61);
        kintsugi.mint(vault, 62);
        vm.prank(vault);
        registry.delegateContract(hot, address(kintsugi), true);
        vm.prank(hot);
        sale.buyFor{value: PRICE}(16, address(kintsugi), 60, vault);
        vm.prank(vault);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(17, address(kintsugi), 60);
        vm.prank(vault);
        sale.buy{value: PRICE}(17, address(kintsugi), 61);
        assertEq(piece.ownerOf(16), hot);
        assertEq(piece.ownerOf(17), vault);
        vm.prank(vault);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buy{value: PRICE}(18, address(kintsugi), 62);
        vm.prank(hot);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buyFor{value: PRICE}(18, address(kintsugi), 62, vault);
    }

    /// The same holder token never buys twice, whoever tries and however it
    /// moves: other delegates, the vault itself, a new owner, a new owner's delegate.
    function test_HolderToken_NeverTwice_ByAnyone() public {
        address vault = makeAddr("vaultZ");
        address h1 = makeAddr("h1");
        address h2 = makeAddr("h2");
        address h3 = makeAddr("h3");
        address next = makeAddr("nextZ");
        address[5] memory ws = [vault, h1, h2, h3, next];
        for (uint256 i = 0; i < 5; i++) vm.deal(ws[i], 1 ether);
        tum.mint(vault, 77);
        vm.startPrank(vault);
        registry.delegateAll(h1, true);
        registry.delegateAll(h2, true);
        vm.stopPrank();
        vm.prank(h1);
        sale.buyFor{value: PRICE}(16, address(tum), 77, vault);
        vm.prank(h2);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buyFor{value: PRICE}(17, address(tum), 77, vault);
        vm.prank(vault);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(17, address(tum), 77);
        vm.prank(vault);
        tum.transferFrom(vault, next, 77);
        vm.prank(next);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(17, address(tum), 77);
        vm.prank(next);
        registry.delegateToken(h3, address(tum), 77, true);
        vm.prank(h3);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buyFor{value: PRICE}(17, address(tum), 77, next);
        assertEq(piece.balanceOf(seller), 48, "exactly one sale from token 77");
    }

    function testFuzz_HolderToken_NeverTwice(address a, address b, uint256 hid) public {
        address vault = makeAddr("fuzzVault");
        vm.assume(a != b && a != vault && b != vault && a != seller && b != seller);
        vm.assume(uint160(a) > 0x10000 && uint160(b) > 0x10000);
        vm.assume(a.code.length == 0 && b.code.length == 0);
        kintsugi.mint(vault, hid);
        vm.startPrank(vault);
        registry.delegateAll(a, true);
        registry.delegateAll(b, true);
        vm.stopPrank();
        vm.deal(a, 1 ether);
        vm.deal(b, 1 ether);
        vm.prank(a);
        sale.buyFor{value: PRICE}(16, address(kintsugi), hid, vault);
        vm.prank(b);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buyFor{value: PRICE}(17, address(kintsugi), hid, vault);
    }

    /// DESIGN NOTE: once per buying wallet is not once per person. One
    /// collector with N holder tokens buys N times, by spreading the tokens
    /// over N wallets or by delegating them to N hot wallets. Each holder
    /// token still buys once.
    function test_Design_OneCollectorManyWallets() public {
        uint256 n = 5;
        for (uint256 i = 0; i < n; i++) {
            address w = makeAddr(string.concat("w", vm.toString(i)));
            cityLights.mint(w, 200 + i);
            vm.deal(w, 1 ether);
            vm.prank(w);
            sale.buy{value: PRICE}(20 + i, address(cityLights), 200 + i);
        }
        assertEq(piece.balanceOf(seller), 49 - n);
    }

    // =========================================================================
    //  Buyers that are contracts
    // =========================================================================

    function test_ContractWalletWithReceiver_Buys() public {
        WalletWithReceiver w = new WalletWithReceiver();
        kintsugi.mint(address(w), 3);
        vm.deal(address(this), 1 ether);
        w.exec{value: PRICE}(address(sale), PRICE, abi.encodeCall(HolderSale.buy, (16, address(kintsugi), 3)));
        assertEq(piece.ownerOf(16), address(w));
    }

    function test_GasBurningReceiver_RevertsWhole() public {
        GasBurner g = new GasBurner();
        kintsugi.mint(address(g), 3);
        vm.deal(address(g), 1 ether);
        vm.prank(address(g));
        (bool ok,) = address(sale).call{value: PRICE, gas: 500_000}(
            abi.encodeCall(HolderSale.buy, (16, address(kintsugi), 3))
        );
        assertFalse(ok);
        assertEq(piece.ownerOf(16), seller);
        assertFalse(sale.used(address(kintsugi), 3));
    }

    // =========================================================================
    //  Stray value and tokens
    // =========================================================================

    function test_PlainEtherIsRefused_ForcedEtherIsInert() public {
        vm.prank(stranger);
        (bool ok,) = address(sale).call{value: 1}("");
        assertFalse(ok, "no receive or fallback");
        vm.deal(address(sale), 1 ether); // as a selfdestruct would force it
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        assertEq(address(sale).balance, 1 ether, "forced ether stays put, no code path touches it");
    }

    function test_TokensSentToTheSale() public {
        vm.prank(seller);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        piece.safeTransferFrom(seller, address(sale), 20);
        // a plain transferFrom strands the token forever: there is no rescue
        vm.prank(seller);
        piece.transferFrom(seller, address(sale), 20);
        assertEq(piece.ownerOf(20), address(sale));
    }

    function test_Constructor_ZeroSeller_BadConfig() public {
        IERC721Sale[] memory cols = sale.collections();
        vm.expectRevert(HolderSale.BadConfig.selector);
        new HolderSale(owner, IERC721Sale(address(piece)), address(0), cols, PRICE, START);
    }

    function test_Constructor_ZeroPiece_BadConfig() public {
        IERC721Sale[] memory cols = sale.collections();
        vm.expectRevert(HolderSale.BadConfig.selector);
        new HolderSale(owner, IERC721Sale(address(0)), seller, cols, PRICE, START);
    }

    function test_Constructor_EmptyCollections_BadConfig() public {
        vm.expectRevert(HolderSale.BadConfig.selector);
        new HolderSale(owner, IERC721Sale(address(piece)), seller, new IERC721Sale[](0), PRICE, START);
    }

    function test_Constructor_ZeroCollection_BadConfig() public {
        for (uint256 at = 0; at < 3; at++) {
            IERC721Sale[] memory cols = sale.collections();
            cols[at] = IERC721Sale(address(0));
            vm.expectRevert(HolderSale.BadConfig.selector);
            new HolderSale(owner, IERC721Sale(address(piece)), seller, cols, PRICE, START);
        }
    }

    function test_Constructor_ZeroOwner_Refused() public {
        IERC721Sale[] memory cols = sale.collections();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HolderSale(address(0), IERC721Sale(address(piece)), seller, cols, PRICE, START);
    }

    // =========================================================================
    //  Owner surface
    // =========================================================================

    function test_Owner_OnlyOwner_AllSetters() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setPrice(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setStartTime(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.transferOwnership(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.renounceOwnership();
        vm.stopPrank();
        // the seller has no owner powers either
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        sale.setPrice(0);
    }

    function test_Owner_TwoStepTransfer() public {
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        sale.transferOwnership(next);
        assertEq(sale.owner(), owner, "nothing changes until accepted");
        assertEq(sale.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.acceptOwnership();
        vm.prank(next);
        sale.acceptOwnership();
        assertEq(sale.owner(), next);
        assertEq(sale.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        sale.setPrice(0);
    }

    function test_Owner_RenounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(RegistryOwnable.RenounceDisabled.selector);
        sale.renounceOwnership();
        assertEq(sale.owner(), owner);
    }

    function test_Owner_PriceChangeTakesEffectOnNextBuy() public {
        vm.prank(owner);
        sale.setPrice(0.2 ether);
        vm.prank(holder);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        uint256 s0 = seller.balance;
        vm.prank(holder);
        sale.buy{value: 0.2 ether}(16, address(cityLights), 7);
        assertEq(seller.balance - s0, 0.2 ether);
    }

    function test_Owner_StartTimeCanMoveBackAndForth() public {
        vm.prank(owner);
        sale.setStartTime(START + 1 days);
        vm.prank(holder);
        vm.expectRevert(HolderSale.NotStarted.selector);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
        vm.prank(owner);
        sale.setStartTime(0);
        vm.prank(holder);
        sale.buy{value: PRICE}(16, address(cityLights), 7);
    }

    function test_Views() public {
        assertEq(sale.collections().length, 3);
        assertTrue(sale.isHolder(holder));
        assertFalse(sale.isHolder(stranger));
        assertEq(address(sale.piece()), address(piece));
        assertEq(sale.seller(), seller);
        assertEq(sale.startTime(), START);
        assertEq(sale.price(), PRICE);
    }

    // =========================================================================
    //  Sell-out: all 49, then nothing
    // =========================================================================

    function test_SellOut_All49_ThenNotForSale() public {
        uint256 s0 = seller.balance;
        for (uint256 id = 16; id <= 64; id++) {
            address w = address(uint160(0x100000 + id));
            tum.mint(w, id);
            vm.deal(w, 1 ether);
            vm.prank(w);
            sale.buy{value: PRICE}(id, address(tum), id);
            assertEq(piece.ownerOf(id), w);
        }
        assertEq(piece.balanceOf(seller), 0);
        assertEq(seller.balance - s0, 49 * PRICE);
        for (uint256 id = 1; id <= 64; id++) {
            vm.prank(holder);
            vm.expectRevert(HolderSale.NotForSale.selector);
            sale.buy{value: PRICE}(id, address(cityLights), 7);
        }
    }

    // =========================================================================
    //  Fuzz
    // =========================================================================

    function testFuzz_Price(uint256 price_, uint256 value) public {
        price_ = bound(price_, 0, 1000 ether);
        value = bound(value, 0, 1000 ether);
        vm.prank(owner);
        sale.setPrice(price_);
        vm.deal(holder, value);
        uint256 s0 = seller.balance;
        vm.prank(holder);
        (bool ok,) = address(sale).call{value: value}(abi.encodeCall(HolderSale.buy, (16, address(cityLights), 7)));
        assertEq(ok, value == price_);
        assertEq(seller.balance - s0, ok ? price_ : 0);
        assertEq(address(sale).balance, 0);
    }

    function testFuzz_StartTime(uint64 start_, uint64 now_) public {
        vm.prank(owner);
        sale.setStartTime(start_);
        vm.warp(now_);
        vm.prank(holder);
        (bool ok,) = address(sale).call{value: PRICE}(abi.encodeCall(HolderSale.buy, (16, address(cityLights), 7)));
        assertEq(ok, now_ >= start_);
    }

    function testFuzz_TokenId(uint256 id) public {
        vm.prank(holder);
        (bool ok,) = address(sale).call{value: PRICE}(abi.encodeCall(HolderSale.buy, (id, address(cityLights), 7)));
        assertEq(ok, id >= 16 && id <= 64);
        if (ok) assertEq(piece.ownerOf(id), holder);
    }

    function testFuzz_HolderTokenId(uint256 hid, uint8 which, address intruder) public {
        vm.assume(intruder != address(0) && intruder.code.length == 0);
        AuditNFT c = which % 3 == 0 ? kintsugi : which % 3 == 1 ? cityLights : tum;
        address h = makeAddr("fuzzHolder");
        vm.assume(intruder != h);
        c.mint(h, hid == 7 && address(c) == address(cityLights) ? 8 : hid);
        uint256 id = hid == 7 && address(c) == address(cityLights) ? 8 : hid;
        vm.deal(intruder, 1 ether);
        vm.prank(intruder);
        vm.expectRevert(HolderSale.NotTheHolder.selector);
        sale.buy{value: PRICE}(16, address(c), id);
        vm.deal(h, 1 ether);
        vm.prank(h);
        sale.buy{value: PRICE}(16, address(c), id);
        assertTrue(sale.used(address(c), id));
    }

    /// Only a delegation that matches (all, this contract, or this token)
    /// lets the hot wallet spend the vault's token.
    function testFuzz_DelegationMatching(uint8 kind, uint256 hid, uint256 delegatedId, uint8 delegatedColl) public {
        address cold = makeAddr("fcold");
        address hot = makeAddr("fhot");
        vm.deal(hot, 1 ether);
        kintsugi.mint(cold, hid);
        AuditNFT dc = delegatedColl % 2 == 0 ? kintsugi : cityLights;
        kind = kind % 3;
        vm.prank(cold);
        if (kind == 0) registry.delegateAll(hot, true);
        else if (kind == 1) registry.delegateContract(hot, address(dc), true);
        else registry.delegateToken(hot, address(dc), delegatedId, true);
        bool expect = kind == 0 || (kind == 1 && address(dc) == address(kintsugi)) || (kind == 2 && address(dc) == address(kintsugi) && delegatedId == hid);
        vm.prank(hot);
        (bool ok, bytes memory err) = address(sale).call{value: PRICE}(
            abi.encodeCall(HolderSale.buyFor, (16, address(kintsugi), hid, cold))
        );
        assertEq(ok, expect);
        if (!ok) assertEq(_sel(err), HolderSale.NotDelegated.selector);
    }
}
