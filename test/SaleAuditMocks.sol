// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import "../src/player/HolderSale.sol";

/// Audit fixtures for HolderSale: a plain ERC-721, a delegate.xyz v2 stand-in,
/// a legacy-style collection whose ownerOf answers zero for a missing token,
/// and hostile buyers and sellers that re-enter the sale.

contract AuditNFT is ERC721 {
    function name() public pure override returns (string memory) { return "A"; }
    function symbol() public pure override returns (string memory) { return "A"; }
    function tokenURI(uint256) public pure override returns (string memory) { return ""; }
    function mint(address to, uint256 id) external { _mint(to, id); }
    function burn(uint256 id) external { _burn(id); }
}

/// A delegate.xyz v2 stand-in, etched at the registry's address.
contract AuditDelegates {
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

/// A legacy-style ERC-721 whose ownerOf returns address(0) for a missing
/// token instead of reverting (pre-OpenZeppelin-4 behaviour some old
/// collections still have).
contract ZeroOwnerNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 id) external { ownerOf[id] = to; balanceOf[to]++; }
}

/// A collection whose ownerOf always reverts.
contract RevertingNFT {
    function ownerOf(uint256) external pure returns (address) { revert("nope"); }
    function balanceOf(address) external pure returns (uint256) { revert("nope"); }
}

/// What a hostile buyer tries from inside onERC721Received.
enum Reenter {
    None,
    SameTokenSameHolder, // buy(tokenId, c, holderTokenId) again
    OtherTokenSameHolder, // buy(other, c, holderTokenId)
    OtherTokenOtherHolder, // buy(other, c, otherHolderTokenId): same wallet, second holder token
    BuyForOtherVault, // buyFor(other, c, vaultToken, vault): a vault that delegated to this contract (legitimate)
    BuyForSelfVault // buyFor(other, c, otherHolderTokenId, address(this))
}

contract ReentrantBuyer {
    HolderSale public immutable sale;
    Reenter public mode;
    address public c;
    uint256 public otherToken;
    uint256 public otherHolderToken;
    address public vault;
    bool public innerOk;
    bytes public innerErr;
    uint256 public calls;

    constructor(HolderSale sale_) { sale = sale_; }

    function arm(Reenter m, address c_, uint256 otherToken_, uint256 otherHolderToken_, address vault_) external {
        mode = m;
        c = c_;
        otherToken = otherToken_;
        otherHolderToken = otherHolderToken_;
        vault = vault_;
    }

    function buy(uint256 tokenId, address c_, uint256 holderTokenId) external payable {
        sale.buy{value: msg.value}(tokenId, c_, holderTokenId);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        calls++;
        if (calls == 1 && mode != Reenter.None) {
            uint256 p = sale.price();
            bytes memory data;
            if (mode == Reenter.SameTokenSameHolder) {
                data = abi.encodeCall(HolderSale.buy, (tokenId, c, otherHolderToken));
            } else if (mode == Reenter.OtherTokenSameHolder) {
                data = abi.encodeCall(HolderSale.buy, (otherToken, c, otherHolderToken));
            } else if (mode == Reenter.OtherTokenOtherHolder) {
                data = abi.encodeCall(HolderSale.buy, (otherToken, c, otherHolderToken));
            } else if (mode == Reenter.BuyForOtherVault) {
                data = abi.encodeCall(HolderSale.buyFor, (otherToken, c, otherHolderToken, vault));
            } else if (mode == Reenter.BuyForSelfVault) {
                data = abi.encodeCall(HolderSale.buyFor, (otherToken, c, otherHolderToken, address(this)));
            }
            (innerOk, innerErr) = address(sale).call{value: p}(data);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// A seller contract whose receive() re-enters the sale with the payment it
/// was just sent.
contract ReentrantSeller {
    HolderSale public sale;
    uint256 public reTokenId;
    address public reCollection;
    uint256 public reHolderToken;
    bool public innerOk;
    bytes public innerErr;
    uint256 public receives;

    function approve(address piece, address sale_) external {
        sale = HolderSale(sale_);
        AuditNFT(piece).setApprovalForAll(sale_, true);
    }

    function arm(uint256 tokenId, address c, uint256 holderToken) external {
        reTokenId = tokenId;
        reCollection = c;
        reHolderToken = holderToken;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        receives++;
        if (receives == 1 && msg.value != 0) {
            (innerOk, innerErr) = address(sale).call{value: msg.value}(
                abi.encodeCall(HolderSale.buy, (reTokenId, reCollection, reHolderToken))
            );
        }
    }
}

/// A Safe-like contract wallet that accepts ERC-721 tokens and calls out.
contract WalletWithReceiver {
    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// A receiver that burns all the gas it is given (a griefing buyer: it only
/// hurts itself, because the buy reverts as a whole).
contract GasBurner {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        while (true) {}
        return 0;
    }
}
