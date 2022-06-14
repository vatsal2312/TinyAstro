// SPDX-License-Identifier: MIT
//.___________. __  .__   __. ____    ____      ___           _______..___________..______        ______
//|           ||  | |  \ |  | \   \  /   /     /   \         /       ||           ||   _  \      /  __  \
//`---|  |----`|  | |   \|  |  \   \/   /     /  ^  \       |   (----``---|  |----`|  |_)  |    |  |  |  |
//    |  |     |  | |  . `  |   \_    _/     /  /_\  \       \   \        |  |     |      /     |  |  |  |
//    |  |     |  | |  |\   |     |  |      /  _____  \  .----)   |       |  |     |  |\  \----.|  `--'  |
//    |__|     |__| |__| \__|     |__|     /__/     \__\ |_______/        |__|     | _| `._____| \______/

pragma solidity >=0.8.1 <0.9.0;

import "./ERC721AQueryable.sol";
import "./Ownable.sol";
import "./ReentrancyGuard.sol";
import "./ERC2981.sol";

import "./ILeaseController.sol";

error MintingNotStarted();
error IncorrectTierAttempt();
error MaxSupplyExceeded();
error InvalidMintAmount();
error CallerIsAContract();
error IncorrectFundsAmount();
error PublicMintIsNotActivated();
error IncorrectAddress();
error InvalidCoupon();
error PriceIsTooLow();
error TokenIsStaked();

contract TinyAstro is ERC721AQueryable, ERC2981, Ownable, ReentrancyGuard {
  string public baseURI;
  string public hiddenMetadataURI = "ipfs://QmXBcCF8UzbJpNtXksgHZBoa2S663o5WAXvHk7P2R1LNRx/hidden.json";

  uint256 public price = 0.01 ether;
  uint256 public publicSalePrice = 0.02 ether;
  uint256 public constant maxSupply = 100;

  // on deploy make it private;
  address public pubSigner = 0x2D038458B6bD28e75BffcaE90E1B59F8aDB7FEE6;

  //Supporting tiers 1,2,3,4( 3 - raffle, 4 - public sale )
  struct Config {
    uint8 maxMint;
    uint8 tierNumber;
    bool isActive;
  }
  Config private mintConfig;

  address private leaseController;

  constructor() ERC721A("TinyAstro", "TA") {
    mintConfig = Config({maxMint: 0, tierNumber: 0, isActive: false});
  }

  // ==== MODIFIERS ==== //
  modifier mintGeneralCompliance(uint256 _mintAmount, uint8 _tierNumber) {
    // validate contract is active
    // isActive is true
    if (!mintConfig.isActive) {
      revert MintingNotStarted();
    }

    // validate user tier number
    // tier should be equal to current config tier
    if (_tierNumber != mintConfig.tierNumber) {
      revert IncorrectTierAttempt();
    }

    // validate mintAmount
    // should not exceed max allowed mint amount from config per msg sender tier
    // also validating here that maxMint from configs for current tier > 0
    if (_mintAmount > mintConfig.maxMint) {
      revert InvalidMintAmount();
    }

    // caller is user
    if (tx.origin != msg.sender) {
      revert CallerIsAContract();
    }

    // validate totalSupply
    // mintAmount + all minted tokens should be less or equal than maxSupply
    if (_totalMinted() + _mintAmount > maxSupply) {
      revert MaxSupplyExceeded();
    }

    // validate wallet for previous purchases
    // we allow to mint only once per tier
    uint64 tierMintedMask = uint64(1 << (_tierNumber - 1));
    uint64 aux = _getAux(msg.sender);
    if (aux & tierMintedMask > 0) {
      revert InvalidMintAmount();
    }

    _;

    _setAux(msg.sender, aux | tierMintedMask);
  }

  /**
   * @dev See {IERC165-supportsInterface}.
   */
  function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721A, ERC2981) returns (bool) {
    return ERC721A.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
  }

  // ==== MAIN FUNCTIONS ==== //
  // Mint Functions //

  function mintTier(
    uint256 _mintAmount,
    bytes32 _r,
    bytes32 _s,
    uint256 _v,
    uint8 _tierNumber,
    uint8 _maxMintAmount
  ) external payable mintGeneralCompliance(_mintAmount, _tierNumber) nonReentrant {
    // validate msg.value
    // should be == publicSalePrice by quantity of minting tokens
    if (msg.value < (price * _mintAmount)) {
      revert IncorrectFundsAmount();
    }

    // validate couponCode with assigned tier number and max mint amount
    bytes32 digest = keccak256(abi.encode(_tierNumber, _maxMintAmount, msg.sender));
    if (!_isCouponValid(digest, _r, _s, _v)) {
      revert InvalidCoupon();
    }

    if (_mintAmount > _maxMintAmount) {
      revert InvalidMintAmount();
    }

    _safeMint(msg.sender, _mintAmount);
  }

  function mintPublic(uint256 _mintAmount) external payable mintGeneralCompliance(_mintAmount, 4) nonReentrant {
    // validate msg.value
    // should be == publicSalePrice by quantity of minting tokens
    if (msg.value < (publicSalePrice * _mintAmount)) {
      revert IncorrectFundsAmount();
    }

    _safeMint(msg.sender, _mintAmount);
  }

  function burn(uint256 _tokenId) external {
    _burn(_tokenId, true);
  }

  // Public View Functions //

  function tokenURI(uint256 _tokenId) public view virtual override(ERC721A) returns (string memory) {
    string memory _tokenURI = super.tokenURI(_tokenId);
    return bytes(_tokenURI).length != 0 ? _tokenURI : hiddenMetadataURI;
  }

  function getMintData(address _owner)
    public
    view
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    return (numberMinted(_owner), totalSupply(), mintConfig.tierNumber);
  }

  function numberMinted(address owner) public view returns (uint256) {
    return _numberMinted(owner);
  }

  //override renounceOwnership
  function renounceOwnership() public override onlyOwner {}

  // Setters Only Owner //
  function airdrop(uint256 _mintAmount, address _receiver) external onlyOwner {
    // validate totalSupply
    // mintAmount + all minted tokens should be less or equal than maxSupply
    if (_totalMinted() + _mintAmount > maxSupply) {
      revert MaxSupplyExceeded();
    }

    // validate mintAmount
    // should be > 0
    // should not exceed 50 tokens
    if (_mintAmount == 0 || _mintAmount > 50) {
      revert InvalidMintAmount();
    }

    _safeMint(_receiver, _mintAmount);
  }

  function setBaseURI(string memory _baseURIPrefix) external onlyOwner {
    baseURI = _baseURIPrefix;
  }

  function setPrice(uint256 _price) external onlyOwner {
    //validate price to make sure its not less than 0.01 eth
    if (_price < 10000000000000000) {
      revert PriceIsTooLow();
    }
    price = _price;
  }

  function setPublicSalePrice(uint256 _price) external onlyOwner {
    //validate price to make sure its not less than 0.01 eth
    if (_price < 10000000000000000) {
      revert PriceIsTooLow();
    }
    publicSalePrice = _price;
  }

  function setHiddenMetadataURI(string calldata _hiddenMetadataURI) external onlyOwner {
    hiddenMetadataURI = _hiddenMetadataURI;
  }

  function pauseContract() external onlyOwner {
    mintConfig.tierNumber = 0;
    mintConfig.maxMint = 0;
    mintConfig.isActive = false;
  }

  function setActiveTier(uint8 _tierNumber, uint8 _maxMint) external onlyOwner {
    mintConfig.tierNumber = _tierNumber;
    mintConfig.maxMint = _maxMint;
    mintConfig.isActive = true;
  }

  function setGlobalConfig(
    uint8 _maxMint,
    uint8 _tierNumber,
    bool _isActive
  ) external onlyOwner {
    mintConfig = Config({maxMint: _maxMint, tierNumber: _tierNumber, isActive: _isActive});
  }

  function setPubSigner(address _pubSigner) external onlyOwner {
    pubSigner = _pubSigner;
  }

  function withdraw() external onlyOwner {
    (bool success, ) = msg.sender.call{value: address(this).balance}("");
    require(success, "Transfer failed.");
  }

  function showGlobalConfig()
    external
    view
    returns (
      uint8 maxMint,
      uint8 tierNumber,
      bool isActive
    )
  {
    return (mintConfig.maxMint, mintConfig.tierNumber, mintConfig.isActive);
  }

  function getOwnershipData(uint256 tokenId) external view returns (TokenOwnership memory) {
    return _ownershipOf(tokenId);
  }

//  function firstTokenURI(address owner) external view onlyOwner returns (string memory) {
//    if (owner == address(0)) revert IncorrectAddress();
//
//    uint256 curr = 0;
//
//    unchecked {
//      while (curr < _currentIndex) {
//        TokenOwnership memory ownership = _ownerships[curr];
//        if (ownership.addr == owner && !ownership.burned) {
//          break;
//        }
//        curr++;
//      }
//    }
//
//    return curr == _currentIndex ? "" : tokenURI(curr);
//  }

  // EIP-2981 //

  function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
    _setDefaultRoyalty(receiver, feeNumerator);
  }

  function deleteDefaultRoyalty() external onlyOwner {
    _deleteDefaultRoyalty();
  }

  function setTokenRoyalty(
    uint256 tokenId,
    address receiver,
    uint96 feeNumerator
  ) external onlyOwner {
    _setTokenRoyalty(tokenId, receiver, feeNumerator);
  }

  function resetTokenRoyalty(uint256 tokenId) external onlyOwner {
    _resetTokenRoyalty(tokenId);
  }

  // Internal Functions //
  function _baseURI() internal view virtual override returns (string memory) {
    return baseURI;
  }

  function _isCouponValid(
    bytes32 digest,
    bytes32 _r,
    bytes32 _s,
    uint256 _v
  ) internal view returns (bool) {
    address signer = ecrecover(digest, uint8(_v), _r, _s);
    if (signer == address(0)) {
      revert IncorrectAddress();
    }
    return signer == pubSigner;
  }

  function _beforeTokenTransfers(
    address from,
    address, /* to */
    uint256 startTokenId,
    uint256 quantity
  ) internal view override {
    if (from != address(0) && quantity == 1) {
      // Before transfer or burn, verify the token is not staked.
      if (leaseController != address(0) && ILeaseController(leaseController).isTokenStaked(startTokenId)) {
        revert TokenIsStaked();
      }
    }
  }

  // Lease //

  function _setLeaseController(address _leaseController) internal {
    leaseController = _leaseController;
  }

  function setLeaseController(address _leaseController) external onlyOwner {
    _setLeaseController(_leaseController);
  }
}
