// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/player/HolderSale.sol";
import "./SaleAuditMocks.sol";

/// Drives HolderSale with random buys, delegated buys, holder-token transfers,
/// delegations, price changes, pauses, approval flips and time jumps, and
/// keeps a ghost ledger of what each successful purchase should have done.
contract SaleHandler is Test {
    HolderSale public sale;
    AuditNFT public piece;
    AuditNFT[3] public cols;
    AuditDelegates public registry;
    address public seller;
    address public owner;

    uint256 public constant N = 60; // more holding wallets than tokens for sale
    address[N] public actors;
    uint256 public constant HOLDER_IDS = 40; // ids 0..39 in each collection

    // ghost ledger
    uint256 public sold;
    uint256 public paidToSeller;
    uint256 public sellerStart;
    mapping(uint256 => address) public buyerOf;
    mapping(address => mapping(uint256 => uint256)) public timesUsed;
    mapping(address => uint256) public timesBought; // keyed on the BUYING wallet (msg.sender)
    uint256[] public soldIds;
    bool public doubleUse;
    bool public doubleBuy;
    bool public wrongHolder; // a purchase whose named holder did not own the holder token
    bool public unmarked; // a purchase that left the buyer or the holder token unrecorded

    constructor(HolderSale s, AuditNFT p, AuditNFT[3] memory c, AuditDelegates r, address seller_, address owner_) {
        sale = s;
        piece = p;
        cols = c;
        registry = r;
        seller = seller_;
        owner = owner_;
        sellerStart = seller_.balance;
        for (uint256 i = 0; i < N; i++) {
            actors[i] = address(uint160(0xA0000 + i));
            vm.deal(actors[i], 1000 ether);
        }
        // spread the holder tokens over the actors
        for (uint256 k = 0; k < 3; k++) {
            for (uint256 id = 0; id < HOLDER_IDS; id++) {
                c[k].mint(actors[(id + 7 * k) % N], id);
            }
        }
    }

    function _record(uint256 tokenId, address buyer, address holder, address c, uint256 hid, uint256 value) internal {
        if (timesUsed[c][hid] != 0) doubleUse = true;
        if (timesBought[buyer] != 0) doubleBuy = true;
        timesUsed[c][hid]++;
        timesBought[buyer]++;
        if (AuditNFT(c).ownerOf(hid) != holder) wrongHolder = true;
        if (!sale.bought(buyer) || !sale.used(c, hid)) unmarked = true;
        buyerOf[tokenId] = buyer;
        soldIds.push(tokenId);
        sold++;
        paidToSeller += value;
    }

    function buy(uint256 a, uint256 k, uint256 hid, uint256 tokenId, uint8 mode) external {
        address c = address(cols[k % 3]);
        hid = hid % (HOLDER_IDS + 2); // a couple of missing ids too
        address actor = actors[a % N];
        // mostly the real holder, sometimes anyone
        if (mode % 4 != 0 && hid < HOLDER_IDS) actor = AuditNFT(c).ownerOf(hid);
        tokenId = bound(tokenId, 10, 66);
        uint256 value = mode % 16 == 1 ? sale.price() + 1 : sale.price();
        vm.prank(actor);
        try sale.buy{value: value}(tokenId, c, hid) {
            _record(tokenId, actor, actor, c, hid, value);
        } catch {}
    }

    function buyFor(uint256 a, uint256 k, uint256 hid, uint256 tokenId, uint8 mode) external {
        address actor = actors[a % N];
        address c = address(cols[k % 3]);
        hid = hid % HOLDER_IDS;
        address vault = AuditNFT(c).ownerOf(hid);
        if (mode % 8 == 0) vault = actors[(a % N + 1) % N]; // often not the holder
        if (mode % 3 != 0) {
            // delegate first, of a random kind
            vm.startPrank(vault);
            if (mode % 3 == 1) registry.delegateToken(actor, c, hid, true);
            else registry.delegateContract(actor, c, true);
            vm.stopPrank();
        }
        tokenId = bound(tokenId, 10, 66);
        uint256 value = sale.price();
        vm.prank(actor);
        try sale.buyFor{value: value}(tokenId, c, hid, vault) {
            _record(tokenId, actor, vault, c, hid, value);
        } catch {}
    }

    function moveHolderToken(uint256 from, uint256 to, uint256 k, uint256 hid) external {
        AuditNFT c = cols[k % 3];
        hid = hid % HOLDER_IDS;
        address o = c.ownerOf(hid);
        address dest = actors[to % N];
        if (o == dest) return;
        from; // the current owner moves it
        vm.prank(o);
        c.transferFrom(o, dest, hid);
    }

    function delegate(uint256 from, uint256 to, uint256 kind, uint256 k, uint256 hid, bool on) external {
        address f = actors[from % N];
        address t = actors[to % N];
        vm.startPrank(f);
        if (kind % 3 == 0) registry.delegateAll(t, on);
        else if (kind % 3 == 1) registry.delegateContract(t, address(cols[k % 3]), on);
        else registry.delegateToken(t, address(cols[k % 3]), hid % HOLDER_IDS, on);
        vm.stopPrank();
    }

    function setPrice(uint256 p) external {
        vm.prank(owner);
        sale.setPrice(bound(p, 0, 5 ether));
    }

    function setPaused(uint8 x) external {
        vm.prank(owner);
        sale.setPaused(x % 8 == 0); // paused one time in eight
    }

    function flipApproval(uint8 x) external {
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), x % 8 != 0); // revoked one time in eight
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    function soldCount() external view returns (uint256) {
        return soldIds.length;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 1500
contract HolderSaleInvariantTest is Test {
    HolderSale internal sale;
    AuditNFT internal piece;
    SaleHandler internal handler;
    address internal seller = makeAddr("seller");
    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    uint64 internal constant START = 1_791_459_882;

    function setUp() public {
        piece = new AuditNFT();
        AuditNFT[3] memory c = [new AuditNFT(), new AuditNFT(), new AuditNFT()];
        IERC721Sale[] memory cols = new IERC721Sale[](3);
        for (uint256 i = 0; i < 3; i++) cols[i] = IERC721Sale(address(c[i]));
        sale = new HolderSale(owner, IERC721Sale(address(piece)), seller, cols, 0.1 ether, START);
        for (uint256 id = 1; id <= 15; id++) piece.mint(creator, id);
        for (uint256 id = 16; id <= 64; id++) piece.mint(seller, id);
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), true);
        vm.etch(address(sale.DELEGATES()), address(new AuditDelegates()).code);
        handler = new SaleHandler(sale, piece, c, AuditDelegates(address(sale.DELEGATES())), seller, owner);
        vm.warp(START - 1 hours);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = SaleHandler.buy.selector;
        sel[1] = SaleHandler.buyFor.selector;
        sel[2] = SaleHandler.moveHolderToken.selector;
        sel[3] = SaleHandler.delegate.selector;
        sel[4] = SaleHandler.setPrice.selector;
        sel[5] = SaleHandler.setPaused.selector;
        sel[6] = SaleHandler.flipApproval.selector;
        sel[7] = SaleHandler.warp.selector;
        sel[8] = SaleHandler.buy.selector; // buys twice as likely
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// Coverage: how many purchases each run actually landed.
    function afterInvariant() public {
        console2.log("purchases this run", handler.sold());
        assertGt(handler.sold(), 0, "the handler must land purchases, or the invariants prove nothing");
    }

    function invariant_SaleHoldsNoEther() public {
        assertEq(address(sale).balance, 0);
    }

    function invariant_SellerPaidExactlyForWhatSold() public {
        assertEq(seller.balance - handler.sellerStart(), handler.paidToSeller());
    }

    function invariant_EverySoldTokenWentToItsBuyer() public {
        uint256 n = handler.soldCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.soldIds(i);
            assertTrue(id >= 16 && id <= 64, "only seller-held tokens sell");
            assertEq(piece.ownerOf(id), handler.buyerOf(id));
        }
    }

    function invariant_NoHolderTokenUsedTwice_NoBuyingWalletBoughtTwice() public {
        assertFalse(handler.doubleUse());
        assertFalse(handler.doubleBuy());
        assertFalse(handler.wrongHolder());
        assertFalse(handler.unmarked());
    }

    function invariant_AtMost49_AndSupplyConserved() public {
        assertLe(handler.sold(), 49);
        assertEq(piece.balanceOf(seller) + handler.sold(), 49);
        for (uint256 id = 1; id <= 15; id++) assertEq(piece.ownerOf(id), creator);
    }
}
