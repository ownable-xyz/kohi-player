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

import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC2981} from "solady/tokens/ERC2981.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import "../RegistryOwnable.sol";
import "../StreamStore.sol";
import "../Attributes.sol";
import "../IKVMTraitsRunner.sol";
import {IKohiPiece, KohiRenderPath} from "./IKohiPiece.sol";
import {IKohiTokenURI} from "./IKohiTokenURI.sol";

/* =============================================================================
 *  KOHIPIECE · a generative artwork stored on chain as one program and its seeds
 * =============================================================================
 *
 * THE PROBLEM. Many NFTs keep their artwork off chain. The token holds a link,
 * and the link can break or change. A KohiPiece keeps the artwork itself on chain
 * as a short program. Any reader can rebuild every image from chain state
 * alone.
 *
 * HOW IT WORKS. The program is for the KVM, a bytecode virtual machine for
 * generative art. This contract stores the program. Each token is that
 * program run with one seed. A seed is a number that makes one run differ
 * from another. The artist chooses all the seeds before any token exists, so
 * every token is a chosen work. The supply is fixed at deployment.
 *
 * kohiProgram() returns the program. kohiSeed(id) returns the seed of one
 * token. kohiRenderPath() names the contracts that make the image. The
 * interpreter runs the program to a draw stream. The renderer of the piece's
 * family turns the draw stream into pixels. Anyone can render any token with
 * view calls.
 *
 * THE TRUST BOUNDARY. One account, the owner (the artist), controls the
 * contract. Ownership moves in two steps and cannot be renounced. The locks
 * below end each power for good.
 *
 * WHAT THE OWNER CAN DO, AND WHEN IT STOPS.
 *  - Before lockArt(): write the program, the params, the trait names and the
 *    description. lockArt() freezes all four forever.
 *  - Before lockSeeds(): set the seeds. lockSeeds() needs exactly maxSupply
 *    seeds. It freezes them forever.
 *  - mintTo() mints in token order (id 1 gets seed 1). It works only after
 *    both locks, so no token exists before its artwork and seed are final.
 *    The supply cannot grow.
 *  - Before lockTokenURI(): choose the tokenURI module. This is the contract
 *    that writes the metadata of each token. lockTokenURI() freezes the
 *    choice. A module changes how the metadata looks. It cannot change the
 *    artwork.
 *  - Before lockContractURI(): set the collection metadata (ERC-7572).
 *    lockContractURI() freezes it.
 *  - Once, after both locks: record the creator (ERC-7015). The creator signs
 *    the program hash and the seeds hash as EIP-712 typed data. The
 *    attribution therefore names this exact artwork. This contract checks the
 *    signature. A signature from the key of the account passes. If it does
 *    not match, the contract asks the account through ERC-1271. An account
 *    with an EIP-7702 delegation has code. Its own key still signs for it.
 *  - Set the default royalty (ERC-2981). This is never locked.
 *
 * WHAT IS PERMANENT. The constructor fixes the name, the symbol, the supply
 * and the render path. The contract has no upgrade path and no self-destruct.
 * The owner has no function that moves a token. Token holders move their own
 * tokens under the ERC-721 rules.
 *
 * Every change to the tokenURI module emits the ERC-4906 BatchMetadataUpdate
 * event, so marketplaces refresh the metadata.
 */
/// @title KohiPiece
/// @notice An ERC-721 collection whose artwork is a KVM program stored in the
///         contract, run once per token with a seed that the artist chose.
/// @dev Built on Solady ERC721, ERC2981 and EIP712 and on OpenZeppelin
///      Ownable2Step. The program is stored in SSTORE2 chunks. Locks are
///      one-way flags with no unlock function.
contract KohiPiece is ERC721, ERC2981, EIP712, RegistryOwnable, IKohiPiece {
    /// @notice The number of tokens. It cannot change.
    uint256 public immutable maxSupply;
    /// @notice The rasterizer family the program is drawn for (0 to 5).
    uint8 public immutable family;
    /// @notice The noise kind the program uses: 0 NoiseV1, 1 GradNoise.
    uint8 public immutable noiseKind;
    /// @notice The EIP-712 type hash of the message that the creator signs for
    ///         ERC-7015.
    bytes32 public constant ARTWORK_CREATION_TYPEHASH =
        keccak256("ArtworkCreation(bytes32 programHash,bytes32 seedsHash)");

    /// @notice The one-shot interpreter (KVMRunner).
    address public immutable runner;
    /// @notice The stepped interpreter, for renders larger than one call.
    address public immutable stepRunner;
    /// @notice The renderer of the piece's family.
    address public immutable renderer;
    /// @notice The traits-only interpreter that kohiAttributes reads.
    address public immutable traitsRunner;

    /// @dev The collection name. Also the EIP-712 domain name.
    string internal _name;
    /// @dev The collection symbol.
    string internal _symbol;
    /// @dev The SSTORE2 contracts that hold the program, in order.
    address[] internal _programPtrs;
    /// @dev The PARAM slot values. Slot i is _params[i].
    int64[] internal _params;
    /// @dev The display metadata of each trait.
    Attributes.TraitMeta[] internal _traitMeta;
    /// @dev The description of the piece.
    string internal _description;
    /// @dev The seeds. _seeds[i] is the seed of token i + 1.
    int32[] internal _seeds;
    /// @dev The collection metadata URI (ERC-7572).
    string internal _contractURI;

    /// @notice True after lockArt(): the program, params, traits and
    ///         description are final.
    bool public artLocked;
    /// @notice True after lockSeeds(): the seeds are final.
    bool public seedsLocked;
    /// @notice True after lockTokenURI(): the tokenURI module is final.
    bool public tokenURILocked;
    /// @notice True after lockContractURI(): the collection metadata is final.
    bool public contractURILocked;
    /// @notice keccak256 of the program, set by lockArt().
    bytes32 public programHash;
    /// @notice keccak256(abi.encodePacked(seeds)), set by lockSeeds().
    bytes32 public seedsHash;
    /// @notice The attributed creator (ERC-7015), or zero before attribution.
    address public creator;
    /// @notice The module that writes each token's metadata.
    IKohiTokenURI public tokenURIModule;
    /// @notice The number of tokens minted.
    uint256 public totalSupply;

    /// @notice Program bytes were added.
    /// @param chunks     The number of SSTORE2 contracts written.
    /// @param bytesAdded The number of program bytes added.
    event ProgramChunksAdded(uint256 chunks, uint256 bytesAdded);
    /// @notice The program was removed.
    event ProgramCleared();
    /// @notice The PARAM slot values were set.
    /// @param count The number of slot values.
    event ParamsSet(uint256 count);
    /// @notice The display metadata of a trait was added.
    /// @param id   The TRAIT record id.
    /// @param name The trait name.
    event TraitAdded(uint8 id, string name);
    /// @notice All trait metadata was removed.
    event TraitsCleared();
    /// @notice The description was set.
    /// @param description The description.
    event DescriptionSet(string description);
    /// @notice The program, params, traits and description are now final.
    /// @param programHash The keccak256 of the program.
    event ArtLocked(bytes32 programHash);
    /// @notice The seed list was set.
    /// @param count The number of seeds.
    event SeedsSet(uint256 count);
    /// @notice The seeds are now final.
    /// @param seedsHash The keccak256 of the packed seeds.
    event SeedsLocked(bytes32 seedsHash);
    /// @notice The tokenURI module was set.
    /// @param module The module address.
    event TokenURIModuleSet(address module);
    /// @notice The tokenURI module is now final.
    /// @param module The module address.
    event TokenURILocked(address module);
    /// @notice The collection metadata URI changed (ERC-7572).
    event ContractURIUpdated();
    /// @notice The collection metadata URI is now final.
    event ContractURILocked();
    /// @notice The creator of the artwork was recorded (ERC-7015).
    /// @param structHash The EIP-712 struct hash that the creator signed.
    /// @param domainName The EIP-712 domain name, which is the collection name.
    /// @param version    The EIP-712 domain version.
    /// @param creator    The creator account.
    /// @param signature  The creator signature.
    event CreatorAttribution(bytes32 structHash, string domainName, string version, address creator, bytes signature);
    /// @notice The metadata of a range of tokens changed (ERC-4906).
    /// @param _fromTokenId The first token of the range.
    /// @param _toTokenId   The last token of the range.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice The program, params, traits and description are final.
    error ArtIsLocked();
    /// @notice The art is not final yet.
    error ArtNotLocked();
    /// @notice The seeds are final.
    error SeedsAreLocked();
    /// @notice The seeds are not final yet.
    error SeedsNotLocked();
    /// @notice The seed count is wrong.
    /// @param count The seed count that was found.
    error BadSeedCount(uint256 count);
    /// @notice The mint is past maxSupply.
    error SupplyExceeded();
    /// @notice The tokenURI module is final.
    error TokenURIIsLocked();
    /// @notice No tokenURI module is set.
    error NoTokenURIModule();
    /// @notice The program has no bytes.
    error EmptyProgram();
    /// @notice No trait metadata is set.
    error NoTraits();
    /// @notice The text has a quote, a backslash or a control byte.
    error UnsafeText();
    /// @notice The collection metadata URI is final.
    error ContractURIIsLocked();
    /// @notice The creator is already recorded.
    error AlreadyAttributed();
    /// @notice The creator signature is not valid, or the creator is zero.
    error BadSignature();
    /// @notice The constructor arguments are not valid.
    error BadConfig();

    /// @notice Deploy a piece with its name, supply and render path.
    /// @dev Reverts BadConfig if maxSupply_ is zero, the family is above 5, or
    ///      the noise kind is above 1.
    /// @param owner_        The owner (the artist).
    /// @param name_         The collection name; token names are "<name> #<id>".
    /// @param symbol_       The collection symbol.
    /// @param maxSupply_    The number of tokens, and of seeds.
    /// @param path          The family, noise kind, interpreter, stepped
    ///                      interpreter and renderer.
    /// @param traitsRunner_ The traits-only interpreter.
    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        KohiRenderPath memory path,
        address traitsRunner_
    ) RegistryOwnable(owner_) {
        if (maxSupply_ == 0 || path.family > 5 || path.noiseKind > 1) revert BadConfig();
        _name = name_;
        _symbol = symbol_;
        maxSupply = maxSupply_;
        family = path.family;
        noiseKind = path.noiseKind;
        runner = path.runner;
        stepRunner = path.stepRunner;
        renderer = path.renderer;
        traitsRunner = traitsRunner_;
    }

    /// @dev Reverts ArtIsLocked after lockArt().
    modifier whileArtOpen() {
        if (artLocked) revert ArtIsLocked();
        _;
    }

    // ---- the artwork (owner, until lockArt) ---------------------------------

    /// @notice Append bytes to the program.
    /// @dev One SSTORE2 contract holds at most 24,575 bytes. This function
    ///      splits the bytes across as many contracts as it needs. Owner only.
    ///      Reverts ArtIsLocked after lockArt().
    /// @param data The next part of the program.
    function appendProgram(bytes calldata data) external onlyOwner whileArtOpen {
        address[] memory ptrs = StreamStore.writeChunks(data);
        for (uint256 i = 0; i < ptrs.length; i++) _programPtrs.push(ptrs[i]);
        emit ProgramChunksAdded(ptrs.length, data.length);
    }

    /// @notice Remove the whole program, to write it again.
    /// @dev Owner only. Reverts ArtIsLocked after lockArt().
    function clearProgram() external onlyOwner whileArtOpen {
        delete _programPtrs;
        emit ProgramCleared();
    }

    /// @notice Set the PARAM slot values that the program reads.
    /// @dev Owner only. Reverts ArtIsLocked after lockArt().
    /// @param params The raw 64-bit slot values; slot i is params[i].
    function setParams(int64[] calldata params) external onlyOwner whileArtOpen {
        _params = params;
        emit ParamsSet(params.length);
    }

    /// @notice Add the display metadata of one trait the program emits.
    /// @dev Owner only. Reverts ArtIsLocked after lockArt(). Reverts UnsafeText
    ///      for a name or label with a quote, a backslash or a control byte.
    /// @param id        The TRAIT record id.
    /// @param kind      0 number, 1 choice, 2 flag, 3 value.
    /// @param hidden    True to omit the trait from the attributes.
    /// @param decimals  The decimal places for kind 3.
    /// @param traitName The trait name (trait_type).
    /// @param labels    The label of each value, for kinds 1 and 2.
    function addTrait(
        uint8 id,
        uint8 kind,
        bool hidden,
        uint8 decimals,
        string calldata traitName,
        string[] calldata labels
    ) external onlyOwner whileArtOpen {
        _requireSafeText(traitName);
        Attributes.TraitMeta storage m = _traitMeta.push();
        m.id = id;
        m.kind = kind;
        m.hidden = hidden;
        m.decimals = decimals;
        m.name = traitName;
        for (uint256 i = 0; i < labels.length; i++) {
            _requireSafeText(labels[i]);
            m.labels.push(labels[i]);
        }
        emit TraitAdded(id, traitName);
    }

    /// @notice Remove every trait, to add them again.
    /// @dev Owner only. Reverts ArtIsLocked after lockArt().
    function clearTraits() external onlyOwner whileArtOpen {
        delete _traitMeta;
        emit TraitsCleared();
    }

    /// @notice Set the description of the piece.
    /// @dev Owner only. Reverts ArtIsLocked after lockArt(). Reverts UnsafeText
    ///      for a quote, a backslash or a control byte.
    /// @param description The description.
    function setDescription(string calldata description) external onlyOwner whileArtOpen {
        _requireSafeText(description);
        _description = description;
        emit DescriptionSet(description);
    }

    /// @notice Freeze the program, params, traits and description forever.
    /// @dev Owner only. Reverts ArtIsLocked if the art is already locked.
    ///      Reverts EmptyProgram if no program is set. Reverts NoTraits if no
    ///      trait is set. The ArtLocked event carries the keccak256 of the
    ///      program.
    function lockArt() external onlyOwner whileArtOpen {
        if (_programPtrs.length == 0) revert EmptyProgram();
        if (_traitMeta.length == 0) revert NoTraits();
        artLocked = true;
        programHash = keccak256(StreamStore.readChunks(_programPtrs));
        emit ArtLocked(programHash);
    }

    // ---- the seeds (owner, until lockSeeds) ---------------------------------

    /// @notice Set the curated seeds. seeds[i] is the seed of token i + 1.
    /// @dev Owner only. Replaces any earlier list. Reverts SeedsAreLocked after
    ///      lockSeeds(). Reverts BadSeedCount for more than maxSupply seeds.
    /// @param seedList The seeds, in token order.
    function setSeeds(int32[] calldata seedList) external onlyOwner {
        if (seedsLocked) revert SeedsAreLocked();
        if (seedList.length > maxSupply) revert BadSeedCount(seedList.length);
        _seeds = seedList;
        emit SeedsSet(seedList.length);
    }

    /// @notice Freeze the seeds forever.
    /// @dev Owner only. Reverts SeedsAreLocked if the seeds are already locked.
    ///      Reverts BadSeedCount unless exactly maxSupply seeds are set. The
    ///      SeedsLocked event carries keccak256(abi.encodePacked(seeds)).
    function lockSeeds() external onlyOwner {
        if (seedsLocked) revert SeedsAreLocked();
        if (_seeds.length != maxSupply) revert BadSeedCount(_seeds.length);
        seedsLocked = true;
        seedsHash = keccak256(abi.encodePacked(_seeds));
        emit SeedsLocked(seedsHash);
    }

    /// @notice The curated seed list, in token order.
    /// @return The seeds. Entry i is the seed of token i + 1.
    function seeds() external view returns (int32[] memory) {
        return _seeds;
    }

    // ---- minting ------------------------------------------------------------

    /// @notice Mint the next `count` tokens to `to`, in token order.
    /// @dev Owner only. Reverts ArtNotLocked before lockArt(). Reverts
    ///      SeedsNotLocked before lockSeeds(). Reverts SupplyExceeded if the
    ///      mint passes maxSupply. The first token minted is id 1.
    /// @param to    The recipient.
    /// @param count The number of tokens to mint.
    function mintTo(address to, uint256 count) external onlyOwner {
        if (!artLocked) revert ArtNotLocked();
        if (!seedsLocked) revert SeedsNotLocked();
        uint256 next = totalSupply;
        if (next + count > maxSupply) revert SupplyExceeded();
        for (uint256 i = 1; i <= count; i++) _mint(to, next + i);
        totalSupply = next + count;
    }

    // ---- metadata -----------------------------------------------------------

    /// @notice Choose the module that writes each token's metadata.
    /// @dev Owner only. Reverts TokenURIIsLocked after lockTokenURI(). Emits
    ///      BatchMetadataUpdate for every token id, 1 to maxSupply. The owner
    ///      can set the zero address. tokenURI() then reverts NoTokenURIModule.
    /// @param module The module.
    function setTokenURIModule(IKohiTokenURI module) external onlyOwner {
        if (tokenURILocked) revert TokenURIIsLocked();
        tokenURIModule = module;
        emit TokenURIModuleSet(address(module));
        emit BatchMetadataUpdate(1, maxSupply);
    }

    /// @notice Freeze the tokenURI module forever.
    /// @dev Owner only. Reverts TokenURIIsLocked if it is already locked.
    ///      Reverts NoTokenURIModule if no module is set.
    function lockTokenURI() external onlyOwner {
        if (tokenURILocked) revert TokenURIIsLocked();
        if (address(tokenURIModule) == address(0)) revert NoTokenURIModule();
        tokenURILocked = true;
        emit TokenURILocked(address(tokenURIModule));
    }

    /// @notice Set the collection metadata URI (ERC-7572).
    /// @dev Owner only. Reverts ContractURIIsLocked after lockContractURI().
    ///      Emits ContractURIUpdated.
    /// @param uri The URI of the collection JSON.
    function setContractURI(string calldata uri) external onlyOwner {
        if (contractURILocked) revert ContractURIIsLocked();
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice Freeze the collection metadata URI forever.
    /// @dev Owner only. Reverts ContractURIIsLocked if it is already locked.
    function lockContractURI() external onlyOwner {
        if (contractURILocked) revert ContractURIIsLocked();
        contractURILocked = true;
        emit ContractURILocked();
    }

    /// @notice The collection metadata URI (ERC-7572).
    /// @return The URI of the collection JSON.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Record the creator of the artwork (ERC-7015). Once only.
    /// @dev Owner only, after lockArt() and lockSeeds(). `signature` is the
    ///      EIP-712 signature of the creator for ArtworkCreation(programHash,
    ///      seedsHash). The domain is the name, "1", the chain id and the
    ///      address of this contract. The check first recovers the signer from
    ///      the signature. If that is not creator_, the check asks creator_
    ///      through ERC-1271. Reverts ArtNotLocked or SeedsNotLocked before
    ///      the locks. Reverts AlreadyAttributed if a creator is recorded.
    ///      Reverts BadSignature if creator_ is zero or the signature is not
    ///      valid.
    /// @param creator_  The account of the creator.
    /// @param signature The signature of the creator.
    function attributeCreator(address creator_, bytes calldata signature) external onlyOwner {
        if (!artLocked) revert ArtNotLocked();
        if (!seedsLocked) revert SeedsNotLocked();
        if (creator != address(0)) revert AlreadyAttributed();
        if (creator_ == address(0)) revert BadSignature();
        bytes32 structHash = keccak256(abi.encode(ARTWORK_CREATION_TYPEHASH, programHash, seedsHash));
        bytes32 digest = _hashTypedData(structHash);
        if (
            ECDSA.tryRecoverCalldata(digest, signature) != creator_
                && !SignatureCheckerLib.isValidERC1271SignatureNowCalldata(creator_, digest, signature)
        ) revert BadSignature();
        creator = creator_;
        emit CreatorAttribution(structHash, _name, "1", creator_, signature);
    }

    /// @notice Set the default royalty (ERC-2981).
    /// @dev Owner only. Nothing locks it. The Solady ERC2981 base reverts for
    ///      a zero receiver or a fee above 10,000.
    /// @param receiver     The royalty receiver.
    /// @param feeNumerator The fee in basis points of 10,000.
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice The metadata URI of a token. The tokenURI module writes it.
    /// @dev Reverts TokenDoesNotExist for a token that is not minted. Reverts
    ///      NoTokenURIModule if no module is set.
    /// @param id The token.
    /// @return The metadata URI.
    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        if (address(tokenURIModule) == address(0)) revert NoTokenURIModule();
        return tokenURIModule.tokenURI(this, id);
    }

    /// @notice The collection name.
    /// @return The name.
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice The collection symbol.
    /// @return The symbol.
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev The EIP-712 domain name and version.
    function _domainNameAndVersion() internal view override returns (string memory, string memory) {
        return (_name, "1");
    }

    /// @dev The constructor body sets the name after the EIP712 constructor
    ///      would have cached it. The domain is therefore computed on each use.
    function _domainNameAndVersionMayChange() internal pure override returns (bool) {
        return true;
    }

    // ---- IKohiPiece ---------------------------------------------------------

    /// @inheritdoc IKohiPiece
    function kohiProgram() external view returns (bytes memory) {
        return StreamStore.readChunks(_programPtrs);
    }

    /// @inheritdoc IKohiPiece
    function kohiParams() external view returns (int64[] memory) {
        return _params;
    }

    /// @inheritdoc IKohiPiece
    function kohiSeed(uint256 tokenId) public view returns (int32) {
        if (!_exists(tokenId)) revert KohiNoSuchToken(tokenId);
        return _seeds[tokenId - 1];
    }

    /// @inheritdoc IKohiPiece
    function kohiRenderPath() external view returns (KohiRenderPath memory) {
        return KohiRenderPath({
            family: family,
            noiseKind: noiseKind,
            runner: runner,
            stepRunner: stepRunner,
            renderer: renderer
        });
    }

    /// @inheritdoc IKohiPiece
    function kohiName(uint256 tokenId) external view returns (string memory) {
        if (!_exists(tokenId)) revert KohiNoSuchToken(tokenId);
        return string.concat(_name, " #", _decimal(tokenId));
    }

    /// @inheritdoc IKohiPiece
    function kohiDescription() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc IKohiPiece
    /// @dev Runs the program on the traits-only interpreter. The run stops
    ///      after the last TRAIT record the traits metadata declares, before
    ///      the program draws, so it costs a small part of a full render.
    function kohiAttributes(uint256 tokenId) external view returns (string memory) {
        int32 seed = kohiSeed(tokenId);
        bytes memory stream =
            IKVMTraitsRunner(traitsRunner).traitsOf(StreamStore.readChunks(_programPtrs), seed, _params, _traitMeta.length);
        return Attributes.toJson(Attributes.extractTraits(stream), _traitMeta);
    }

    // ---- ERC-165 ------------------------------------------------------------

    /// @notice ERC-165 support: ERC-721, ERC-2981, ERC-4906 and IKohiPiece.
    /// @param interfaceId The interface id.
    /// @return True if the contract supports the interface.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == type(IKohiPiece).interfaceId || interfaceId == 0x49064906
            || ERC721.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
    }

    // ---- helpers ------------------------------------------------------------

    /// @dev Reverts UnsafeText for a quote, a backslash or a control byte.
    ///      Such text would break the JSON that it is written into.
    function _requireSafeText(string calldata s) internal pure {
        bytes calldata b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\" || uint8(c) < 0x20 || uint8(c) == 0x7f) revert UnsafeText();
        }
    }

    /// @dev The decimal text of a number.
    function _decimal(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }
}
