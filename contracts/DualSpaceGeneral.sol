// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

abstract contract DualSpaceGeneral is ERC721 {

    event BatchStart(uint256 startBlock, uint128 batchNbr, uint8 ratio);

    struct TokenMeta {
        // date + category
        uint128 batchNbr; // 20230401+01. can be easily extended
        uint8 rarity;      // <= 99
        uint16 batchInternalId; // <= 999
    }

    // token example 2023040101010001
    // token batch * 10^8 + category * 10^6 + rarity * 10^4 + batch internal id
    function _resolveTokenId(uint256 tokenId) internal pure returns (TokenMeta memory) {
        uint256 batchNbr = tokenId/(10**6);
        uint256 rarity = (tokenId - batchNbr * 10**6 )/10**4;
        uint256 batchInternalId = tokenId - batchNbr * 10**6 - rarity * 10**4;
        return TokenMeta(uint128(batchNbr), uint8(rarity), uint16(batchInternalId));
    }

    function _nextTokenId(uint128 batchNbr, uint8 rarity, uint16 batchInternalId) pure internal returns (uint256) {
        return uint256(batchNbr) * 10**6 + uint256(rarity) * 10**4 + uint256(batchInternalId);
    }

    // TODO: rename to isPrivilegeExpired
    function isExpired(uint256 tokenId) public view returns (bool){
        return block.number > getExpiration(tokenId);
    }

    // should add?
    // function lock(uint256 tokenId, uint256 period) public 

    function getExpiration(uint256 tokenId) public virtual view returns (uint256);
}
