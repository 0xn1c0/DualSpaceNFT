// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// import "@openzepplin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// import "OpenZeppelin/openzeppelin-contracts@4.9.0/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EvmMetatransactionVerifier.sol";
import "./DualSpaceGeneral.sol";
import "./DualSpaceNFTEvm.sol";
import "../interfaces/ICrossSpaceCall.sol";

// deployment
// firstly core side contract
// then deploy espace contract with core side contract mapping address (bind from espace->core)
// finally bind from core (bind from core->espace)
contract DualSpaceNFTCore is DualSpaceGeneral, Ownable, EvmMetatransactionVerifier {
    bytes20 _evmContractAddress;
    // only for debug
    // DualSpaceNFTEvm evmContractForDebug;
    CrossSpaceCall _crossSpaceCall;
    uint _defaultOracleBlockLife;

    struct MintOracleSetting {
        address signer;
        uint expiration;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // 20230523 => address
    // mint oracle is a centralized server to prove the user owns the Github token
    mapping (uint128=>MintOracleSetting) _mintOracleSignerSetting;
    // batchNbr => usernameHash => rarityCouldMint
    mapping (uint128=>mapping(bytes32=>uint8)) _authorizedRarityMintPermission;

    mapping (uint128=>uint16) _batchInternalIdCounter;

    constructor(string memory name_, string memory symbol_, address crossSpaceCallAddress)
        ERC721(name_, symbol_)
        EvmMetatransactionVerifier(name_, "v1")
        Ownable() 
    {
        // _crossSpaceCall = CrossSpaceCall(0x0888000000000000000000000000000000000006);
        _crossSpaceCall = CrossSpaceCall(crossSpaceCallAddress);
        _defaultOracleBlockLife = 30 days * 2; // 30 days, 2 block per second
    }

    function setEvmContractAddress(bytes20 evmContractAddress_) public onlyOwner {
        require(_evmContractAddress == bytes20(0), "setEvmContractAddress should only be invoked once");
        _evmContractAddress = evmContractAddress_;
        // evmContractForDebug = DualSpaceNFTEvm(address(evmContractAddress_));
    }

    function startBatch(uint128 batchNbr, address signer, uint8 ratio) public onlyOwner {
        require(batchNbr < 99999999, "invalid batch nbr");
        _mintOracleSignerSetting[batchNbr].signer = signer;
        _mintOracleSignerSetting[batchNbr].expiration = block.number + _defaultOracleBlockLife;
        _crossSpaceCall.callEVM(_evmContractAddress, 
            abi.encodeWithSignature("startBatch(uint128,uint8)", batchNbr, ratio)
        );
        emit BatchStart(block.number, batchNbr, ratio);
    }

    function _isValidMintOracleSigner(address signer, uint128 batchNbr) internal view returns (bool) {
        return signer == _mintOracleSignerSetting[batchNbr].signer && _mintOracleSignerSetting[batchNbr].expiration > block.number;
    }

    function batchAuthorizeMintPermission(uint128 batchNbr, string[] memory usernames, uint8 rarity) public {
        // owner or mint oracle
        if (msg.sender == owner()) {
            // do nothing
        } else if (
            _isValidMintOracleSigner(msg.sender, batchNbr)
        ) {
            // do nothing
        }
        else {
            revert("msg sender is not authorized to set mint permission");
        }
        for (uint256 i = 0; i < usernames.length; i++) {
            _authorizeMintPermission(batchNbr, usernames[i], rarity);
        }
    }

    function _authorizeMintPermission(uint128 batchNbr, string memory username, uint8 rarity) internal {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        _authorizedRarityMintPermission[batchNbr][usernameHash] = rarity;
    }

    // hashToSign = keccak(batchNbr, usernameHash, ownerCoreAddress, ownerEvmAddress)
    function mint(uint128 batchNbr, string memory username, address ownerCoreAddress, bytes20 ownerEvmAddress, Signature memory oracleSignature) public returns (uint256) {
        require(_mintOracleSignerSetting[batchNbr].expiration > block.number, "no available mint oracle at present");
        bytes32 usernameHash = keccak256(abi.encodePacked(username));

        // check mint permission
        uint8 rarity = _authorizedRarityMintPermission[batchNbr][usernameHash];
        require(rarity != 0, "no permission to mint");
        delete _authorizedRarityMintPermission[batchNbr][usernameHash];

        require(
            ecrecover(
                // hash to sign. cannot be replayed, or replay will not bring benefit
                keccak256(
                    abi.encodePacked(batchNbr, usernameHash, ownerCoreAddress, ownerEvmAddress)
                ),
                oracleSignature.v, oracleSignature.r, oracleSignature.s
            ) == _mintOracleSignerSetting[batchNbr].signer,
            "should be signed by signer"
        );


        _batchInternalIdCounter[batchNbr] += 1;
        uint256 tokenId = _nextTokenId(batchNbr, rarity, _batchInternalIdCounter[batchNbr]);
        // if mint to zero, mint to self
        if (ownerCoreAddress == address(0)) {
            ownerCoreAddress = address(this);
        }
        if (ownerEvmAddress == bytes20(0)) {
            ownerEvmAddress = _evmContractAddress;
        }
        // update transferable state
        if (ownerCoreAddress == address(this)) {
            _crossSpaceCall.callEVM(_evmContractAddress, 
                abi.encodeWithSignature("setTransferableTable(uint256,bool)", tokenId, true)
            );
        }
        _crossSpaceCall.callEVM(_evmContractAddress,
            abi.encodeWithSignature("mint(bytes20,uint256)", ownerEvmAddress, tokenId)
        );
        _mint(ownerCoreAddress, tokenId);
        return tokenId;
    }

    function getExpiration(uint256 tokenId) public view override returns (uint256 exp){
        return uint256(bytes32(_crossSpaceCall.staticCallEVM(_evmContractAddress, 
            abi.encodeWithSignature("getExpiration(uint256)", tokenId)
        )));
    }

    function _isCoreTransferable(uint256 tokenId) internal view returns (bool) {
        bytes20 currentEvmOwner = evmOwnerOf(tokenId);
        return currentEvmOwner == _evmContractAddress;
    }

    function evmOwnerOf(uint256 tokenId) public view returns (bytes20){
        bytes20 currentEvmOwner = bytes20(uint160(uint256(bytes32(_crossSpaceCall.staticCallEVM(_evmContractAddress, 
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        )))));
        return currentEvmOwner;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(msg.sender == ownerOf(tokenId), "caller is not core token owner");
        _;
    }

    function clearEvmOwner(uint256 tokenId) public onlyTokenOwner(tokenId) {
        _setEvmOwner(tokenId, _evmContractAddress);
    }

    // only core owner can set evm owner
    function setEvmOwner(uint256 tokenId, bytes20 ownerEvmAddress) public onlyTokenOwner(tokenId) {
        _setEvmOwner(tokenId, ownerEvmAddress);
    }

    function _setEvmOwner(uint256 tokenId, bytes20 ownerEvmAddress) internal {
        
        _crossSpaceCall.callEVM(_evmContractAddress, 
            abi.encodeWithSignature("setEvmOwner(uint256,bytes20)", tokenId, ownerEvmAddress)
        );
        // evmContractForDebug.setEvmOwner(ownerEvmAddress, tokenId);
    }

    function clearCoreOwner(bytes20 evmSigner, uint256 tokenId, bytes memory signatureFromEvmSigner) public {

        setCoreOwner(evmSigner, tokenId, address(this), signatureFromEvmSigner);
    }

    function setCoreOwner(bytes20 evmSigner, uint256 tokenId, address newCoreOwner, bytes memory signatureFromEvmSigner) public {
        
        _recoverWithNonceChange(signatureFromEvmSigner, evmSigner, tokenId, newCoreOwner);
        require(evmSigner == evmOwnerOf(tokenId), "do not have permission to set core owner");
        _transfer(ownerOf(tokenId), newCoreOwner, tokenId);
    }


    function safeTransferFrom(address from, address to, uint256 tokenId) public override {
        if (to != address(this)) {
            require(_isCoreTransferable(tokenId), "This token is not transferable because its evm space owner is set. Clear evm space owner and try again");   
        }
        super.safeTransferFrom(from, to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal override {
        if (from == address(this) && from != to) {
            _crossSpaceCall.callEVM(_evmContractAddress, 
                abi.encodeWithSignature("setTransferableTable(uint256,bool)", tokenId, false)
            );
        }
        if (to == address(this)) {
            _crossSpaceCall.callEVM(_evmContractAddress, 
                abi.encodeWithSignature("setTransferableTable(uint256,bool)", tokenId, true)
            );
        }
        super._transfer(from, to, tokenId);
    }
}
