// SPDX-License-Identifier: MIT
//.___________. __  .__   __. ____    ____      ___           _______..___________..______        ______
//|           ||  | |  \ |  | \   \  /   /     /   \         /       ||           ||   _  \      /  __  \
//`---|  |----`|  | |   \|  |  \   \/   /     /  ^  \       |   (----``---|  |----`|  |_)  |    |  |  |  |
//    |  |     |  | |  . `  |   \_    _/     /  /_\  \       \   \        |  |     |      /     |  |  |  |
//    |  |     |  | |  |\   |     |  |      /  _____  \  .----)   |       |  |     |  |\  \----.|  `--'  |
//    |__|     |__| |__| \__|     |__|     /__/     \__\ |_______/        |__|     | _| `._____| \______/

pragma solidity ^0.8.15;

import "./Initializable.sol";
import "./UUPSUpgradeable.sol";
import "./OwnableUpgradeable.sol";

// Minimum ERC721 & ERC20 interface
interface IERC721 {
  function ownerOf(uint256 tokenId) external view returns (address owner);

  function balanceOf(address owner) external view returns (uint256 balance);
}

interface IERC20 {
  function mint(address to, uint256 amount) external;
}

contract AstroStakingControllerV1 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
  // Data related to staked NFT tokens
  struct StakedToken {
    // Owner of the NFT
    address owner;
    // Timestamp when the NFT was staked
    uint32 timestamp;
    // Flag indicating whether it's the first staked NFT
    // First staked NFT cannot be unstaked unless all other NFTs are unstaked
    // First staked NFT will only get one rental pass
    bool isFirstStaked;
    uint256 emissionRate;
    // Rental recipients and expirations
    address recipient1;
    uint32 expiration1;
    address recipient2;
    uint32 expiration2;
  }

  // Data related to token owners
  struct TokenOwner {
    // Token ids of currently staked NFT
    uint256[] stakedTokenIds;
    // Total amount of ERC20 tokens minted by the address
    uint256 amountMinted;
  }

  // Events
  event Staked(address indexed owner, uint256 indexed tokenId, uint256 emissionRate, bool isFirstStaked);

  event Unstaked(address indexed owner, uint256 indexed tokenId, uint256 amountMinted);

  event Claimed(address indexed owner, uint256 amountMinted);

  event Rented(
    address indexed owner,
    address indexed recipient,
    uint256 indexed tokenId,
    bool isFirstPass,
    uint32 expiration
  );

  uint256 public constant WAD = 1e18; // Scalar for the ERC20 token

  // Contract address of TinyAstro NFT
  address public tinyAstro;

  // Contract address of AstroToken
  address public astroToken;

  bool public isPaused;

  // Mapping token id to rarity ranking
  // Rarity 0 = NFT ranking from 1501 - 3000 (Don't have to update the mappings for these tokens as default is 0)
  // Rarity 1 = NFT ranking from 501  - 1500
  // Rarity 2 = NFT ranking from 101  - 500
  // Rarity 3 = NFT ranking from 11   - 100
  // Rarity 4 = NFT ranking from 1    - 10
  mapping(uint256 => uint256) public tokenRarities;

  // Mapping token rarity to emission rate per day;
  mapping(uint256 => uint256) public emissionRates;

  // Valid rental durations (in days)
  mapping(uint256 => bool) public rentalDurations;

  // Mapping token id to staked data
  mapping(uint256 => StakedToken) public stakedTokens;

  // Mapping owner address to address data
  mapping(address => TokenOwner) public tokenOwners;

  // Mapping rental recipient address to token id
  mapping(address => uint256) private _recipientToTokenId;

  function initialize(address _tinyAstro, address _astroToken) public initializer {
    tinyAstro = _tinyAstro;
    astroToken = _astroToken;

    // Rarity 0 - Token ranking from 1501 - 3000, 8 tokens per day
    emissionRates[0] = 8;
    // Rarity 1 - Token ranking from 501 - 1500, 12 tokens per day
    emissionRates[1] = 12;
    // Rarity 2 - Token ranking from 101 - 500, 15 tokens per day
    emissionRates[2] = 15;
    // Rarity 3 - Token ranking from 11 - 100, 20 tokens per day
    emissionRates[3] = 20;
    // Rarity 4  - Token ranking from 1 - 10, 100 tokens per day
    emissionRates[4] = 100;

    // Add rental durations of 1 day, 14 days and 30 days
    rentalDurations[1] = true;
    rentalDurations[14] = true;
    rentalDurations[30] = true;

    __Ownable_init();
  }

  function setPaused(bool status) external onlyOwner {
    isPaused = status;
  }

  function updateTokenRarity(uint256 rarity, uint256[] calldata tokenIds) external onlyOwner {
    unchecked {
      for (uint256 i = 0; i < tokenIds.length; i++) {
        tokenRarities[tokenIds[i]] = rarity;
      }
    }
  }

  function updateRentalDurations(uint256[] calldata toAdd, uint256[] calldata toRemove) external onlyOwner {
    unchecked {
      for (uint256 i = 0; i < toAdd.length; i++) {
        rentalDurations[toAdd[i]] = true;
      }

      for (uint256 i = 0; i < toRemove.length; i++) {
        delete rentalDurations[toRemove[i]];
      }
    }
  }

  function updateEmissionRates(uint256[] calldata rarities, uint256[] calldata rates) external onlyOwner {
    require(rarities.length > 0 && rarities.length == rates.length, "Invalid parameters");

    unchecked {
      for (uint256 i = 0; i < rarities.length; i++) {
        emissionRates[rarities[i]] = rates[i];
      }
    }
  }

  modifier whenNotPaused() {
    require(!isPaused, "Contract is paused");
    _;
  }

  /**
   * @notice NFT holders use this function to stake their tokens.
   * @dev Emission rate is set at the time of staking.
   *      Future changes of the corresponding multiplier will not apply to staked tokens.
   *      Staked NFT tokens are blocked from transfers.
   * @param tokenIds List of token id to be staked.
   */
  function stake(uint256[] calldata tokenIds) external whenNotPaused {
    unchecked {
      for (uint256 i = 0; i < tokenIds.length; i++) {
        _stake(tokenIds[i]);
      }
    }
  }

  function _stake(uint256 tokenId) internal {
    require(IERC721(tinyAstro).ownerOf(tokenId) == msg.sender, "Not the token owner");

    StakedToken storage stakedToken = stakedTokens[tokenId];
    require(stakedToken.owner == address(0), "Token is already staked");

    uint256 emissionRate = emissionRates[tokenRarities[tokenId]];
    require(emissionRate > 0, "Zero emission rate");

    stakedToken.owner = msg.sender;
    stakedToken.emissionRate = emissionRate * WAD;
    stakedToken.timestamp = uint32(block.timestamp);

    uint256[] storage stakedTokenIds = tokenOwners[msg.sender].stakedTokenIds;
    stakedToken.isFirstStaked = stakedTokenIds.length == 0;
    stakedTokenIds.push(tokenId);

    emit Staked(msg.sender, tokenId, stakedToken.emissionRate, stakedToken.isFirstStaked);
  }

  /**
   * @notice NFT token holders use this function to unstake their tokens and mint ERC20 tokens for rewards.
   * @dev First staked NFT can't be unstaked unless all other NFTs are unstaked.
   * @param tokenIds NFT tokens to be unstaked.
   */
  function unstake(uint256[] calldata tokenIds) external whenNotPaused {
    require(tokenIds.length > 0, "Empty token ids");

    TokenOwner storage tokenOwner = tokenOwners[msg.sender];
    require(tokenOwner.stakedTokenIds.length > 0, "No staked tokens");

    // Ensure first token is not unstaked unless no more staked tokens
    bool validatesFirstToken = tokenIds.length < tokenOwner.stakedTokenIds.length;
    uint256 amountToMint = 0;

    unchecked {
      for (uint256 i = 0; i < tokenIds.length; i++) {
        amountToMint += _unstake(tokenIds[i]);
      }

      if (validatesFirstToken) {
        require(stakedTokens[tokenOwner.stakedTokenIds[0]].isFirstStaked, "First token cannot be unstaked yet");
      }

      if (amountToMint > 0) {
        IERC20(astroToken).mint(msg.sender, amountToMint);
        tokenOwner.amountMinted += amountToMint;
      }
    }
  }

  function _unstake(uint256 tokenId) internal returns (uint256 amount) {
    StakedToken memory stakedToken = stakedTokens[tokenId];

    require(stakedToken.owner == msg.sender, "Not the token owner");

    // Check if there is any active rental pass
    require(
      stakedToken.expiration1 < block.timestamp && stakedToken.expiration2 < block.timestamp,
      "Unstake with active rental pass"
    );

    uint256 numberOfDays = _numberOfDaysSince(stakedToken.timestamp);
    amount = numberOfDays * stakedToken.emissionRate;

    // Free storage
    delete stakedTokens[tokenId];
    _removeStakedTokenId(msg.sender, tokenId);

    emit Unstaked(msg.sender, tokenId, amount);
  }

  /**
   * @notice NFT token holders use this function to claim/mint the ERC20 tokens without unstaking.
   * @dev The amount of ERC20 tokens is calculated on a daily basis.
   */
  function claim() external whenNotPaused {
    uint256[] memory tokenIds = tokenOwners[msg.sender].stakedTokenIds;
    require(tokenIds.length > 0, "No staked tokens");

    uint256 amountToMint = 0;

    unchecked {
      for (uint256 i = 0; i < tokenIds.length; i++) {
        uint256 tokenId = tokenIds[i];

        StakedToken storage stakedToken = stakedTokens[tokenId];

        require(stakedToken.owner == msg.sender, "Not the token owner");

        uint256 numberOfDays = _numberOfDaysSince(stakedToken.timestamp);

        if (numberOfDays > 0) {
          amountToMint += numberOfDays * stakedToken.emissionRate;
          stakedToken.timestamp += uint32(numberOfDays * _secondsPerDay());
        }
      }

      require(amountToMint > 0, "Zero mint amount");

      IERC20(astroToken).mint(msg.sender, amountToMint);
      tokenOwners[msg.sender].amountMinted += amountToMint;

      emit Claimed(msg.sender, amountToMint);
    }
  }

  /**
   * @notice Owner can rent staked NFT to other users for a certian period time so that they will gain access to the analytics platform.
   * @dev First staked NFT only has a single rental pass, while others have two.
   * @param tokenId NFT token to be rented out, must be a staked token.
   * @param recipient Pass recipient, must not be a NFT owner or an active pass holder.
   * @param firstPass Flag indicating wheter to rent the first or the second pass.
   * @param duration Rent duration measured in number of days.
   */
  function rent(
    uint256 tokenId,
    address recipient,
    bool firstPass,
    uint256 duration
  ) external whenNotPaused {
    require(rentalDurations[duration], "Invalid duration");

    StakedToken storage stakedToken = stakedTokens[tokenId];
    require(stakedToken.owner == msg.sender, "Not the token owner");

    // Ensure recipient is not holding any active pass
    _verifyRentalRecipient(recipient);

    uint32 expiration = uint32(block.timestamp + duration * _secondsPerDay());

    if (firstPass) {
      require(stakedToken.expiration1 < block.timestamp, "Pass is rent to someone else");
      stakedToken.recipient1 = recipient;
      stakedToken.expiration1 = expiration;
    } else {
      require(!stakedToken.isFirstStaked && stakedToken.expiration2 < block.timestamp, "Pass is rent to someone else");
      stakedToken.recipient2 = recipient;
      stakedToken.expiration2 = expiration;
    }

    _recipientToTokenId[recipient] = tokenId;

    emit Rented(msg.sender, recipient, tokenId, firstPass, expiration);
  }

  /**
   * @notice Check a owner's staking status.
   * @dev `amountToMint` is calculated on a daily basis.
   */
  function stakingStatus(address addr)
    external
    view
    returns (
      uint256[] memory stakedTokenIds,
      uint256 dailyYield,
      uint256 amountToMint,
      uint256 amountMinted
    )
  {
    TokenOwner memory tokenOwner = tokenOwners[addr];
    stakedTokenIds = tokenOwner.stakedTokenIds;
    amountMinted = tokenOwner.amountMinted;

    unchecked {
      for (uint256 i = 0; i < stakedTokenIds.length; i++) {
        StakedToken memory stakedToken = stakedTokens[stakedTokenIds[i]];
        dailyYield += stakedToken.emissionRate;

        uint256 numberOfDays = _numberOfDaysSince(stakedToken.timestamp);
        if (numberOfDays > 0) {
          amountToMint += numberOfDays * stakedToken.emissionRate;
        }
      }
    }
  }

  /**
   * @notice Check the rental status for a given address.
   */
  function rentalRecipientStatus(address recipient) external view returns (bool isValid, uint32 expiration) {
    uint256 tokenId = _recipientToTokenId[recipient];

    StakedToken memory stakedToken = stakedTokens[tokenId];
    if (stakedToken.recipient1 == recipient) {
      expiration = stakedToken.expiration1;
    } else if (stakedToken.recipient2 == recipient) {
      expiration = stakedToken.expiration2;
    }
    isValid = expiration >= block.timestamp;
  }

  /**
   * @notice Check whether a token is currently staked.
   * @dev This function is needed for `ILeaseController` interface conformance in the NFT contract.
   */
  function isTokenStaked(uint256 tokenId) external view returns (bool) {
    return stakedTokens[tokenId].owner != address(0);
  }

  /**
   * @notice Verify the recipient is not a NFT owner, and is not holding any active rental pass.
   */
  function _verifyRentalRecipient(address recipient) internal view {
    require(IERC721(tinyAstro).balanceOf(recipient) == 0, "Recipient is a NFT owner");

    StakedToken memory stakedToken = stakedTokens[_recipientToTokenId[recipient]];

    uint256 expiration;
    if (stakedToken.recipient1 == recipient) {
      expiration = stakedToken.expiration1;
    } else if (stakedToken.recipient2 == recipient) {
      expiration = stakedToken.expiration2;
    }
    require(expiration < block.timestamp, "Recipient is in possession of an active rental pass");
  }

  /**
   * @dev Remove a NFT token id from staked tokens.
   */
  function _removeStakedTokenId(address addr, uint256 tokenId) internal {
    uint256[] storage tokenIds = tokenOwners[addr].stakedTokenIds;

    unchecked {
      for (uint256 i = 0; i < tokenIds.length; i++) {
        if (tokenIds[i] == tokenId) {
          return _remove(tokenIds, i);
        }
      }
    }
  }

  /**
   * @dev Remove the element at given index in an array without preserving order.
   */
  function _remove(uint256[] storage tokenIds, uint256 index) internal {
    if (index < tokenIds.length - 1) {
      tokenIds[index] = tokenIds[tokenIds.length - 1];
    }
    tokenIds.pop();
  }

  /**
   * @dev Test contracts can override this function to speed up the process.
   */
  function _secondsPerDay() internal pure virtual returns (uint256) {
    return 1 days;
  }

  /**
   * @notice Calculate how many days has passed between the given timestamp and the block's current timestamp.
   */
  function _numberOfDaysSince(uint256 timestamp) internal view returns (uint256) {
    return (block.timestamp - timestamp) / _secondsPerDay();
  }

  /**
   * @dev Required by UUPS upgradeable proxy
   */
  function _authorizeUpgrade(address) internal override onlyOwner {}
}
