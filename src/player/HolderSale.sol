// SPDX-License-Identifier: Apache-2.0
/* Copyright (c) wattsy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. */
pragma solidity ^0.8.24;

import "../RegistryOwnable.sol";

/// @title IERC721Sale
/// @notice The part of ERC-721 that HolderSale calls.
interface IERC721Sale {
    /// @notice Returns the owner of a token.
    /// @param id The token.
    /// @return The owner.
    function ownerOf(uint256 id) external view returns (address);
    /// @notice Returns the number of tokens that an account holds.
    /// @param owner The account.
    /// @return The number of tokens.
    function balanceOf(address owner) external view returns (uint256);
    /// @notice Moves a token and calls onERC721Received if the receiver is a contract.
    /// @param from The current owner.
    /// @param to   The receiver.
    /// @param id   The token.
    function safeTransferFrom(address from, address to, uint256 id) external;
}

/// @title IDelegateRegistry
/// @notice The part of the delegate.xyz v2 registry that HolderSale calls.
interface IDelegateRegistry {
    /// @notice Checks whether `to` is a delegate of `from` for an ERC-721 token.
    /// @dev Returns true for a delegation of the whole wallet, of the
    ///      contract, or of the one token.
    /// @param to        The delegate (the wallet that acts).
    /// @param from      The wallet that holds the token (the delegator).
    /// @param contract_ The ERC-721 contract.
    /// @param tokenId   The token.
    /// @param rights    The rights value of the delegation. HolderSale passes zero.
    /// @return True if the delegation exists.
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}

/* =============================================================================
 *  HOLDERSALE · a walk-up sale of a minted piece, for holders of other works
 * =============================================================================
 *
 * A seller holds the tokens of a piece. The seller wants to sell them to
 * holders of other works, at one price, without a signature for each sale.
 * HolderSale does this. The tokens stay with the seller until someone buys
 * one. The seller approves this contract once, with setApprovalForAll on the
 * piece. The seller signs nothing for each sale.
 *
 * HOW A PURCHASE WORKS. A buyer picks one token that the seller still holds.
 * The buyer pays the price. In the same call, this contract moves the token
 * to the buyer and sends the payment to the seller. The contract never holds
 * a token or a payment.
 *
 * THE RULES. A purchase succeeds only if all of these are true:
 *  - sales are not paused;
 *  - the current time is at or after the start time;
 *  - the payment is exactly the price;
 *  - the buyer names a collection from the list fixed in the constructor;
 *  - the holder owns the token that the buyer names in that collection;
 *  - that holder token has not bought before;
 *  - the buying wallet has not bought before;
 *  - the seller still holds the token for sale.
 * Each holder token buys once. Each buying wallet buys once. If a holder
 * passes one token between wallets, it does not buy twice. A buying wallet
 * buys once, however many tokens it holds or can use. The limit is on the
 * buying wallet, so a contract that holds the tokens of many people (for
 * example an escrow) does not use up one purchase for all of them.
 *
 * DELEGATION. A collector can keep a token in a cold wallet and buy from a
 * hot wallet. The cold wallet delegates to the hot wallet in the delegate.xyz
 * v2 registry. The delegation can cover the whole wallet, the collection or
 * the one token. The hot wallet calls buyFor, and the purchased token goes to
 * the hot wallet.
 *
 * THE TRANSFER. The contract moves the token with safeTransferFrom. A buyer
 * that is a contract must implement onERC721Received. If it cannot receive
 * ERC-721 tokens, the whole purchase reverts and nothing is paid.
 *
 * WHAT THE OWNER CAN DO. The owner can set the price, set the start time, and
 * pause or resume purchases. The owner can do nothing else. The owner cannot
 * move a token, take a payment or change the collection list. The seller can
 * stop the sale at any time by revoking the approval. The seller can take one
 * token off sale by moving it.
 *
 * TRUST BOUNDARY. This contract holds no token and no payment. It can move a
 * token only while the seller keeps the approval. It sends each payment to the
 * seller in the same call as the purchase.
 */
contract HolderSale is RegistryOwnable {
    /// @notice The delegate.xyz v2 registry. It has the same address on every chain.
    IDelegateRegistry public constant DELEGATES = IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493);

    /// @notice The piece on sale.
    IERC721Sale public immutable piece;
    /// @notice The account that holds the unsold tokens and receives the payments.
    address public immutable seller;

    // The collections whose holders can buy. Fixed in the constructor.
    IERC721Sale[] internal _collections;

    /// @notice The price of one token, in wei.
    uint256 public price;
    /// @notice No purchase can happen before this time (unix seconds).
    uint64 public startTime;
    /// @notice True while purchases are paused.
    bool public paused;
    /// @notice True for a buying wallet that has bought.
    mapping(address => bool) public bought;
    /// @notice True for a collection token that has been used to buy. The first key is the collection, the second key is the token.
    mapping(address => mapping(uint256 => bool)) public used;

    /// @notice A token was bought.
    /// @param buyer         The caller. The token goes to this account.
    /// @param holder        The holding wallet that owns the holder token.
    /// @param tokenId       The token that was bought.
    /// @param collection    The collection of the holder token.
    /// @param holderTokenId The holder token that was used to buy.
    /// @param price         The price that was paid, in wei.
    event Bought(
        address indexed buyer,
        address indexed holder,
        uint256 indexed tokenId,
        address collection,
        uint256 holderTokenId,
        uint256 price
    );
    /// @notice The owner set a new price.
    /// @param price The new price, in wei.
    event PriceSet(uint256 price);
    /// @notice The owner set a new start time.
    /// @param startTime The new start time (unix seconds).
    event StartTimeSet(uint64 startTime);
    /// @notice The owner paused or resumed purchases.
    /// @param paused True if purchases are now paused.
    event PausedSet(bool paused);

    /// @notice The start time has not passed.
    error NotStarted();
    /// @notice Purchases are paused.
    error IsPaused();
    /// @notice The payment is not exactly the price.
    error WrongPayment();
    /// @notice The collection is not in the list of collections.
    error NotACollection();
    /// @notice The holder does not own the named holder token.
    error NotTheHolder();
    /// @notice The holder token has already been used to buy.
    error TokenAlreadyUsed();
    /// @notice The caller is not a delegate of the holding wallet.
    error NotDelegated();
    /// @notice The buying wallet has already bought.
    error AlreadyBought();
    /// @notice The constructor arguments are not valid.
    error BadConfig();
    /// @notice The seller does not hold the token.
    error NotForSale();
    /// @notice The seller could not receive the payment.
    error PaymentFailed();

    /// @notice Sets the owner, the piece, the seller, the collections, the price and the start time.
    /// @param owner_       The owner. The owner can set the price, the start time and the pause.
    /// @param piece_       The piece on sale.
    /// @param seller_      The account that holds the tokens and receives the payments.
    /// @param collections_ The collections whose holders can buy.
    /// @param price_       The price, in wei.
    /// @param startTime_   The first second in which a purchase is allowed.
    /// @dev Reverts BadConfig if the piece or the seller is the zero address,
    ///      if the collection list is empty, or if a collection is the zero
    ///      address.
    constructor(
        address owner_,
        IERC721Sale piece_,
        address seller_,
        IERC721Sale[] memory collections_,
        uint256 price_,
        uint64 startTime_
    ) RegistryOwnable(owner_) {
        if (address(piece_) == address(0) || seller_ == address(0) || collections_.length == 0) revert BadConfig();
        for (uint256 i = 0; i < collections_.length; i++) {
            if (address(collections_[i]) == address(0)) revert BadConfig();
        }
        piece = piece_;
        seller = seller_;
        _collections = collections_;
        price = price_;
        startTime = startTime_;
    }

    /// @notice Buys `tokenId` with `holderTokenId` of `collection`. The caller owns the holder token.
    /// @dev Send exactly `price` wei. Reverts IsPaused if purchases are
    ///      paused. Reverts NotStarted before the start time. Reverts
    ///      WrongPayment if msg.value is not the price. Reverts NotACollection
    ///      if the collection is not in the list. Reverts NotTheHolder if the
    ///      caller does not own the holder token. Reverts TokenAlreadyUsed if
    ///      the holder token has bought before. Reverts AlreadyBought if the
    ///      caller has bought before.
    ///      Reverts NotForSale if the seller does not hold `tokenId`. Reverts
    ///      PaymentFailed if the seller cannot receive the payment. Reverts if
    ///      the caller is a contract that cannot receive ERC-721 tokens.
    /// @param tokenId       The token to buy. The seller must still hold it.
    /// @param collection    One of the collections whose holders can buy.
    /// @param holderTokenId A token of `collection` that the caller owns and
    ///                      that has not been used to buy.
    function buy(uint256 tokenId, address collection, uint256 holderTokenId) external payable {
        _buy(tokenId, collection, holderTokenId, msg.sender);
    }

    /// @notice Buys `tokenId` with a token that `vault` holds and has delegated to the caller.
    /// @dev Send exactly `price` wei. The token goes to the caller, and the
    ///      caller is the buying wallet. The holding wallet is `vault`. Reverts NotDelegated if `vault` is not
    ///      the caller and the delegate.xyz v2 registry has no delegation from
    ///      `vault` to the caller. The registry call uses a rights value of
    ///      zero. All the reverts of buy also apply.
    /// @param tokenId       The token to buy. The seller must still hold it.
    /// @param collection    One of the collections whose holders can buy.
    /// @param holderTokenId A token of `collection` that `vault` owns and that
    ///                      has not been used to buy.
    /// @param vault         The holding wallet. In the delegate.xyz v2
    ///                      registry, it has delegated to the caller the whole
    ///                      wallet, the collection or that token.
    function buyFor(uint256 tokenId, address collection, uint256 holderTokenId, address vault) external payable {
        if (
            vault != msg.sender
                && !DELEGATES.checkDelegateForERC721(msg.sender, vault, collection, holderTokenId, bytes32(0))
        ) revert NotDelegated();
        _buy(tokenId, collection, holderTokenId, vault);
    }

    // Check every rule, record the use of the holder token and the buying
    // wallet (the caller), move the token to the caller and pay the seller. The records
    // are written before the token moves and before the payment is sent.
    function _buy(uint256 tokenId, address collection, uint256 holderTokenId, address holder) internal {
        if (paused) revert IsPaused();
        if (block.timestamp < startTime) revert NotStarted();
        if (msg.value != price) revert WrongPayment();
        if (!isCollection(collection)) revert NotACollection();
        if (IERC721Sale(collection).ownerOf(holderTokenId) != holder) revert NotTheHolder();
        if (used[collection][holderTokenId]) revert TokenAlreadyUsed();
        if (bought[msg.sender]) revert AlreadyBought();
        if (piece.ownerOf(tokenId) != seller) revert NotForSale();
        used[collection][holderTokenId] = true;
        bought[msg.sender] = true;
        piece.safeTransferFrom(seller, msg.sender, tokenId);
        (bool ok,) = seller.call{value: msg.value}("");
        if (!ok) revert PaymentFailed();
        emit Bought(msg.sender, holder, tokenId, collection, holderTokenId, msg.value);
    }

    /// @notice Returns true if `collection` is one of the collections whose holders can buy.
    /// @param collection The collection address.
    /// @return True if the collection is in the list.
    function isCollection(address collection) public view returns (bool) {
        for (uint256 i = 0; i < _collections.length; i++) {
            if (address(_collections[i]) == collection) return true;
        }
        return false;
    }

    /// @notice Returns true if `account` holds a token of any of the collections.
    /// @param account The account to check.
    /// @return True if the account holds at least one such token.
    function isHolder(address account) public view returns (bool) {
        for (uint256 i = 0; i < _collections.length; i++) {
            if (_collections[i].balanceOf(account) != 0) return true;
        }
        return false;
    }

    /// @notice Returns the collections whose holders can buy.
    /// @return The collection list.
    function collections() external view returns (IERC721Sale[] memory) {
        return _collections;
    }

    /// @notice Sets the price. Only the owner can call this function.
    /// @param price_ The new price, in wei.
    function setPrice(uint256 price_) external onlyOwner {
        price = price_;
        emit PriceSet(price_);
    }

    /// @notice Sets the start time. Only the owner can call this function.
    /// @param startTime_ The new start time (unix seconds).
    function setStartTime(uint64 startTime_) external onlyOwner {
        startTime = startTime_;
        emit StartTimeSet(startTime_);
    }

    /// @notice Pauses or resumes purchases. Only the owner can call this function.
    /// @param paused_ True to pause purchases, false to resume them.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }
}
