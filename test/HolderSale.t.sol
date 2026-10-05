// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import "../src/player/HolderSale.sol";

contract MockNFT is ERC721 {
    function name() public pure override returns (string memory) { return "M"; }
    function symbol() public pure override returns (string memory) { return "M"; }
    function tokenURI(uint256) public pure override returns (string memory) { return ""; }
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// A delegate.xyz v2 stand-in, etched at the registry's address: a delegation
/// of the whole wallet, of one contract, or of one token.
contract MockDelegates {
    mapping(address => mapping(address => bool)) public all;
    mapping(address => mapping(address => mapping(address => bool))) public byContract;
    mapping(address => mapping(address => mapping(address => mapping(uint256 => bool)))) public byToken;

    function delegateAll(address to, bool on) external { all[msg.sender][to] = on; }
    function delegateContract(address to, address c, bool on) external { byContract[msg.sender][to][c] = on; }
    function delegateToken(address to, address c, uint256 id, bool on) external { byToken[msg.sender][to][c][id] = on; }

    function checkDelegateForERC721(address to, address from, address c, uint256 id, bytes32)
        external
        view
        returns (bool)
    {
        return all[from][to] || byContract[from][to][c] || byToken[from][to][c][id];
    }
}

/// A seller that refuses payment.
contract RefusingSeller {
    receive() external payable { revert("no"); }
}

/// A contract wallet that does not accept ERC-721 tokens.
contract NoReceiver {
    function buy(HolderSale sale, uint256 tokenId, address c, uint256 holderTokenId) external payable {
        sale.buy{value: msg.value}(tokenId, c, holderTokenId);
    }
}

/*
 * HolderSale: a holder walks up and buys a token the seller still holds; the
 * token and the payment move in one call; the seller signs nothing per sale.
 * Each holder token buys once and each holding wallet buys once.
 */
contract HolderSaleTest is Test {
    MockNFT internal piece;
    MockNFT internal kintsugi;
    MockNFT internal cityLights;
    MockNFT internal other;
    HolderSale internal sale;
    MockDelegates internal registry;

    address internal owner = address(0xA11CE);
    address internal seller = address(0x5E11);
    address internal holder = address(0xB0B);
    address internal stranger = address(0xBAD);
    uint256 internal constant PRICE = 0.1 ether;
    uint64 internal constant START = 1_791_460_000;

    event Bought(
        address indexed buyer,
        address indexed holder,
        uint256 indexed tokenId,
        address collection,
        uint256 holderTokenId,
        uint256 price
    );

    function setUp() public {
        piece = new MockNFT();
        kintsugi = new MockNFT();
        cityLights = new MockNFT();
        other = new MockNFT();
        IERC721Sale[] memory cols = new IERC721Sale[](2);
        cols[0] = IERC721Sale(address(kintsugi));
        cols[1] = IERC721Sale(address(cityLights));
        sale = new HolderSale(owner, IERC721Sale(address(piece)), seller, cols, PRICE, START);
        for (uint256 id = 1; id <= 64; id++) piece.mint(seller, id);
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), true);
        cityLights.mint(holder, 7);
        vm.etch(address(sale.DELEGATES()), address(new MockDelegates()).code);
        registry = MockDelegates(address(sale.DELEGATES()));
        vm.deal(holder, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.warp(START);
    }

    function test_Buy_TokenAndPaymentMoveTogether() public {
        uint256 before = seller.balance;
        vm.prank(holder);
        vm.expectEmit(address(sale));
        emit Bought(holder, holder, 12, address(cityLights), 7, PRICE);
        sale.buy{value: PRICE}(12, address(cityLights), 7);
        assertEq(piece.ownerOf(12), holder);
        assertEq(seller.balance - before, PRICE, "the seller is paid");
        assertEq(address(sale).balance, 0, "the sale holds nothing");
        assertTrue(sale.bought(holder));
        assertTrue(sale.used(address(cityLights), 7));
    }

    function test_Buy_OncePerWallet_EvenWithManyTokens() public {
        kintsugi.mint(holder, 1);
        vm.startPrank(holder);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buy{value: PRICE}(2, address(kintsugi), 1);
        vm.stopPrank();
    }

    /// Passing one holder token to a fresh wallet does not buy twice.
    function test_Buy_OncePerHolderToken() public {
        vm.prank(holder);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
        vm.prank(holder);
        cityLights.transferFrom(holder, stranger, 7);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(2, address(cityLights), 7);
    }

    function test_Buy_OnlyTheHolderOfTheNamedToken() public {
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotTheHolder.selector);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
        kintsugi.mint(stranger, 99); // any listed collection qualifies
        vm.prank(stranger);
        sale.buy{value: PRICE}(1, address(kintsugi), 99);
        assertEq(piece.ownerOf(1), stranger);
    }

    function test_Buy_OnlyListedCollections() public {
        other.mint(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(HolderSale.NotACollection.selector);
        sale.buy{value: PRICE}(1, address(other), 1);
        assertTrue(sale.isCollection(address(kintsugi)));
        assertFalse(sale.isCollection(address(other)));
    }

    function test_Buy_ExactPaymentOnly() public {
        vm.startPrank(holder);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: PRICE - 1}(1, address(cityLights), 7);
        vm.expectRevert(HolderSale.WrongPayment.selector);
        sale.buy{value: PRICE + 1}(1, address(cityLights), 7);
        vm.stopPrank();
    }

    function test_Buy_NotBeforeStart() public {
        vm.warp(START - 1);
        vm.prank(holder);
        vm.expectRevert(HolderSale.NotStarted.selector);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
    }

    function test_Buy_OnlyWhatTheSellerHolds() public {
        // A held-back or gifted token has left the seller: it is not for sale.
        vm.prank(seller);
        piece.transferFrom(seller, owner, 5);
        vm.prank(holder);
        vm.expectRevert(HolderSale.NotForSale.selector);
        sale.buy{value: PRICE}(5, address(cityLights), 7);
    }

    function test_Buy_RevokedApprovalStopsTheSale() public {
        vm.prank(seller);
        piece.setApprovalForAll(address(sale), false);
        vm.prank(holder);
        vm.expectRevert();
        sale.buy{value: PRICE}(1, address(cityLights), 7);
    }

    /// A contract buyer that does not accept ERC-721 tokens fails loudly, and pays nothing.
    function test_Buy_NonReceiverContractRevertsWhole() public {
        NoReceiver wallet = new NoReceiver();
        kintsugi.mint(address(wallet), 3);
        vm.deal(address(this), 1 ether);
        uint256 before = seller.balance;
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        wallet.buy{value: PRICE}(sale, 9, address(kintsugi), 3);
        assertEq(piece.ownerOf(9), seller, "the token did not move");
        assertEq(seller.balance, before, "nothing was paid");
        assertFalse(sale.used(address(kintsugi), 3), "the holder token is not spent");
    }

    function test_Pause() public {
        vm.prank(owner);
        sale.setPaused(true);
        vm.prank(holder);
        vm.expectRevert(HolderSale.IsPaused.selector);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
        vm.prank(owner);
        sale.setPaused(false);
        vm.prank(holder);
        sale.buy{value: PRICE}(1, address(cityLights), 7);
    }

    function test_OwnerSettings() public {
        vm.startPrank(owner);
        sale.setPrice(0.2 ether);
        sale.setStartTime(START + 100);
        vm.stopPrank();
        assertEq(sale.price(), 0.2 ether);
        assertEq(sale.startTime(), START + 100);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setStartTime(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sale.setPaused(true);
        vm.stopPrank();
    }

    /// A cold wallet holds the token; its delegated hot wallet buys, and the purchase goes to the hot wallet.
    function test_BuyFor_DelegatedHotWallet_AllContractOrToken() public {
        address cold = holder;
        address hot = address(0x407);
        vm.deal(hot, 1 ether);
        vm.prank(hot);
        vm.expectRevert(HolderSale.NotDelegated.selector);
        sale.buyFor{value: PRICE}(3, address(cityLights), 7, cold);
        // A delegation of just that one token is enough.
        vm.prank(cold);
        registry.delegateToken(hot, address(cityLights), 7, true);
        vm.prank(hot);
        vm.expectEmit(address(sale));
        emit Bought(hot, cold, 3, address(cityLights), 7, PRICE);
        sale.buyFor{value: PRICE}(3, address(cityLights), 7, cold);
        assertEq(piece.ownerOf(3), hot);
        // The limit is on the buying wallet: the hot wallet has spent its one
        // purchase, even with another of the cold wallet's tokens...
        kintsugi.mint(cold, 50);
        vm.prank(cold);
        registry.delegateToken(hot, address(kintsugi), 50, true);
        vm.prank(hot);
        vm.expectRevert(HolderSale.AlreadyBought.selector);
        sale.buyFor{value: PRICE}(4, address(kintsugi), 50, cold);
        // ...the used holder token buys for no one...
        vm.prank(cold);
        vm.expectRevert(HolderSale.TokenAlreadyUsed.selector);
        sale.buy{value: PRICE}(4, address(cityLights), 7);
        // ...and the cold wallet, a different buying wallet, buys once with another token.
        vm.prank(cold);
        sale.buy{value: PRICE}(4, address(kintsugi), 50);
        assertEq(piece.ownerOf(4), cold);
    }

    function test_BuyFor_ContractDelegation() public {
        address hot = address(0x408);
        vm.deal(hot, 1 ether);
        vm.prank(holder);
        registry.delegateContract(hot, address(cityLights), true);
        vm.prank(hot);
        sale.buyFor{value: PRICE}(6, address(cityLights), 7, holder);
        assertEq(piece.ownerOf(6), hot);
    }

    function test_Buy_PaymentFailureRevertsTheWholeSale() public {
        RefusingSeller bad = new RefusingSeller();
        IERC721Sale[] memory cols = sale.collections();
        HolderSale s2 = new HolderSale(owner, IERC721Sale(address(piece)), address(bad), cols, PRICE, START);
        piece.mint(address(bad), 100);
        vm.prank(address(bad));
        piece.setApprovalForAll(address(s2), true);
        vm.prank(holder);
        vm.expectRevert(HolderSale.PaymentFailed.selector);
        s2.buy{value: PRICE}(100, address(cityLights), 7);
        assertEq(piece.ownerOf(100), address(bad), "the token did not move");
    }
}
