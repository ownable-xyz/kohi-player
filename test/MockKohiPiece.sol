// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
pragma solidity ^0.8.13;

import "../src/StreamStore.sol";
import {IKohiPiece, KohiRenderPath} from "../src/player/IKohiPiece.sol";
import {IKohiLiving} from "../src/player/IKohiLiving.sol";

/// A minimal piece behind IKohiPiece + IKohiLiving for tests: the program in
/// SSTORE2 chunks (one SSTORE2 contract holds at most 24,575 bytes; Rakel at
/// 1080 is 57,603), per-token seed and mint time, and setters for the fields a
/// test varies (description, attributes, family, params, living support).
contract MockKohiPiece is IKohiPiece, IKohiLiving {
    address[] internal programPtrs;
    KohiRenderPath internal path;
    int64[] internal params;
    string internal description = "A test piece.";
    string internal attributes = '[{"trait_type":"Ink","value":"100%"}]';
    bool internal living = true;
    mapping(uint256 => int32) internal seedOf;
    mapping(uint256 => uint64) internal mintedAtOf;
    mapping(uint256 => bool) internal exists;

    constructor(bytes memory program, int64[] memory params_, KohiRenderPath memory path_) {
        programPtrs = StreamStore.writeChunks(program);
        params = params_;
        path = path_;
    }

    function mint(uint256 tokenId, int32 seed) external {
        exists[tokenId] = true;
        seedOf[tokenId] = seed;
        mintedAtOf[tokenId] = uint64(block.timestamp);
    }

    function setDescription(string calldata d) external { description = d; }
    function setFamily(uint8 f) external { path.family = f; }
    function setLiving(bool on) external { living = on; }
    function setParams(int64[] calldata p) external { params = p; }
    function setAttributes(string calldata a) external { attributes = a; }

    function _token(uint256 tokenId) internal view {
        if (!exists[tokenId]) revert KohiNoSuchToken(tokenId);
    }

    function kohiProgram() external view returns (bytes memory) { return StreamStore.readChunks(programPtrs); }
    function kohiParams() external view returns (int64[] memory) { return params; }
    function kohiSeed(uint256 tokenId) external view returns (int32) { _token(tokenId); return seedOf[tokenId]; }
    function kohiRenderPath() external view returns (KohiRenderPath memory) { return path; }
    function kohiName(uint256 tokenId) external view returns (string memory) { _token(tokenId); return string.concat("Mock #", _dec(tokenId)); }
    function kohiDescription() external view returns (string memory) { return description; }
    function kohiAttributes(uint256 tokenId) external view returns (string memory) {
        _token(tokenId);
        return attributes;
    }
    function kohiMintedAt(uint256 tokenId) external view returns (uint64) { _token(tokenId); return mintedAtOf[tokenId]; }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return id == type(IKohiPiece).interfaceId || (living && id == type(IKohiLiving).interfaceId) || id == 0x01ffc9a7;
    }

    function _dec(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) { b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b); v /= 10; }
        return string(b);
    }
}
