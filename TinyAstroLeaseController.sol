// SPDX-License-Identifier: MIT
//.___________. __  .__   __. ____    ____      ___           _______..___________..______        ______
//|           ||  | |  \ |  | \   \  /   /     /   \         /       ||           ||   _  \      /  __  \
//`---|  |----`|  | |   \|  |  \   \/   /     /  ^  \       |   (----``---|  |----`|  |_)  |    |  |  |  |
//    |  |     |  | |  . `  |   \_    _/     /  /_\  \       \   \        |  |     |      /     |  |  |  |
//    |  |     |  | |  |\   |     |  |      /  _____  \  .----)   |       |  |     |  |\  \----.|  `--'  |
//    |__|     |__| |__| \__|     |__|     /__/     \__\ |_______/        |__|     | _| `._____| \______/

pragma solidity >=0.8.1 <0.9.0;

import "./ILeaseController.sol";
import "./IERC721.sol";
import "./ReentrancyGuard.sol";
import "./Ownable.sol";
import "./Address.sol";

error NotATokenOwner();
error NotTheLessor();
error InvalidLessee();
error InvalidLease();
error LeaseAlreadySigned();
error TokenIsStaked();
error HasActiveLease();
error InvalidLeaseDuration();
error IncorrectFundsAmount();
error InvalidEarningFraction();

/*
 * TinyAstro lease controller
 */
contract TinyAstroLeaseController is Ownable, ReentrancyGuard {
  // Address of TA contract
  address tokenContract;

  struct Lease {
    uint256 price; // If price is 0 and lessee is not ZERO then it's a gifted lease
    address lessee; // If lessee is ZERO address then anyone can sign the lease
    uint64 listedTime;
    uint64 duration;
    uint64 signedTime;
  }

  event LeaseCreated(
    uint256 indexed tokenId,
    address indexed lessor,
    address indexed lessee,
    uint256 duration,
    uint256 price
  );

  event LeaseUpdated(
    uint256 indexed tokenId,
    address indexed lessor,
    address indexed lessee,
    uint256 duration,
    uint256 price
  );

  event LeaseCancelled(uint256 indexed tokenId, address indexed lessor);

  event LeaseSigned(uint256 indexed tokenId, address indexed lessor, address indexed lessee);

  mapping(uint256 => Lease) private leaseByToken;

  mapping(address => uint256) private tokenByLessee;

  uint64 public maxLeaseDuration = 31536000;

  // Basic unit points (out of 10000) of how much listing price goes to the lessor, default to 80%
  uint16 public earningFraction = 8000;

  uint16 private constant FEE_DENOMINATOR = 10000;

  constructor(address _tokenContract) {
    tokenContract = _tokenContract;
  }

  // External

  /**
   *  Create a lease that can be later signed by another party.
   *  A lease is considered a gift when listingPrice is 0 and lessee is not zero address.
   *  A gifted lease will be signed upon creation to avoid further gas cost.
   */
  function createLease(
    uint256 tokenId,
    uint64 duration,
    uint256 listingPrice,
    address lessee
  ) external {
    address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);

    if (tokenOwner != msg.sender) revert NotATokenOwner();

    if (duration == 0 || duration > maxLeaseDuration) revert InvalidLeaseDuration();

    if (lessee != address(0)) {
      // Lessee cannot be token owner
      if (lessee == tokenOwner) {
        revert InvalidLessee();
      }

      // Cannot gift to a lesse with active lease with other tokens
      if (listingPrice == 0 && isActiveLessee(lessee)) {
        revert InvalidLessee();
      }
    }

    Lease storage lease = leaseByToken[tokenId];

    if (_isLeaseActive(lease) || _isLeaseListed(lease)) {
      revert TokenIsStaked();
    }

    uint64 _now = uint64(block.timestamp);

    lease.listedTime = _now;
    lease.price = listingPrice;
    lease.duration = duration;
    lease.lessee = lessee;

    emit LeaseCreated(tokenId, msg.sender, lessee, duration, listingPrice);

    if (listingPrice == 0 && lessee != address(0)) {
      // The lease is considered a gift and will be signed automatically
      lease.signedTime = _now;
      tokenByLessee[lessee] = tokenId;

      emit LeaseSigned(tokenId, msg.sender, lessee);
    }
  }

  /**
   *  Update a lease that is listed but not signed.
   *  @dev When listingPrice is 0 and lessee is not zero address, the lease is considered a gift
   *  and will be signed automatically.
   */
  function updateLease(
    uint256 tokenId,
    uint64 duration,
    uint256 listingPrice,
    address lessee
  ) external verifyLeaseUpdatable(tokenId) {
    if (lessee == msg.sender) revert InvalidLessee();
    if (duration == 0 || duration > maxLeaseDuration) revert InvalidLeaseDuration();

    Lease storage lease = leaseByToken[tokenId];
    lease.duration = duration;
    lease.price = listingPrice;
    lease.lessee = lessee;

    emit LeaseUpdated(tokenId, msg.sender, lessee, duration, listingPrice);

    if (listingPrice == 0 && lessee != address(0)) {
      lease.signedTime = uint64(block.timestamp);
      tokenByLessee[lessee] = tokenId;
      emit LeaseSigned(tokenId, msg.sender, lessee);
    }
  }

  /**
   *  Cancel a listed or gifted lease.
   */
  function cancelLease(uint256 tokenId) external verifyLeaseUpdatable(tokenId) {
    delete leaseByToken[tokenId];
    emit LeaseCancelled(tokenId, msg.sender);
  }

  /**
   *  Sign a listed lease
   */
  function signLease(uint256 tokenId) external payable nonReentrant {
    Lease storage lease = leaseByToken[tokenId];

    if (lease.listedTime == 0) revert InvalidLease();
    if (lease.signedTime != 0) revert LeaseAlreadySigned();
    if (msg.value != lease.price) revert IncorrectFundsAmount();
    if (isActiveLessee(msg.sender)) revert HasActiveLease();

    address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);

    if (msg.sender == tokenOwner) revert InvalidLessee();
    if (lease.lessee != address(0) && lease.lessee != msg.sender) revert InvalidLessee();

    lease.lessee = msg.sender;
    lease.signedTime = uint64(block.timestamp);

    tokenByLessee[msg.sender] = tokenId;

    if (lease.price > 0) {
      uint256 amountToLessor = (lease.price * earningFraction) / FEE_DENOMINATOR;
      Address.sendValue(payable(tokenOwner), amountToLessor);
    }

    emit LeaseSigned(tokenId, tokenOwner, msg.sender);
  }

  /**
   *  Returns whether the given user is an active lessee, i.e. signed a lease that has not expired.
   */
  function isActiveLessee(address user) public view returns (bool) {
    if (user == address(0)) revert InvalidLessee();

    uint256 tokenId = tokenByLessee[user];

    Lease storage lease = leaseByToken[tokenId];

    return _isLeaseActive(lease) && lease.lessee == user;
  }

  function isTokenStaked(uint256 tokenId) external view returns (bool) {
    return _isLeaseListed(leaseByToken[tokenId]) || _isLeaseActive(leaseByToken[tokenId]);
  }

  function getLease(uint256 tokenId) external view returns (Lease memory) {
    return leaseByToken[tokenId];
  }

  function withdraw() external onlyOwner {
    Address.sendValue(payable(msg.sender), address(this).balance);
  }

  function setEarningFraction(uint16 value) external onlyOwner {
    if (value > FEE_DENOMINATOR) revert InvalidEarningFraction();
    earningFraction = value;
  }

  function setMaxLeaseDuration(uint64 value) external onlyOwner {
    if (value == 0) revert InvalidLeaseDuration();
    maxLeaseDuration = value;
  }

  // Internal

  /**
   *  Returns whether a given lease is been listed
   */
  function _isLeaseListed(Lease storage lease) internal view returns (bool) {
    return lease.listedTime > 0 && lease.signedTime == 0;
  }

  /**
   *  Returns whether a given lease is signed and not expired
   */
  function _isLeaseActive(Lease storage lease) internal view returns (bool) {
    return lease.signedTime > 0 && lease.lessee != address(0) && block.timestamp < (lease.signedTime + lease.duration);
  }

  // Modifiers

  /**
   *  A lease can be updated when:
   *  1. It's listed but not signed
   *  2. It's a gift to someone else
   */
  modifier verifyLeaseUpdatable(uint256 tokenId) {
    address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);

    Lease storage lease = leaseByToken[tokenId];

    if (tokenOwner != msg.sender) revert NotATokenOwner();
    if (lease.listedTime == 0) revert InvalidLease();

    // Owner can cancel a gifted lease
    if (lease.signedTime != 0 && lease.price > 0) revert LeaseAlreadySigned();

    _;
  }
}
