// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal interface into Cooperative - only the pieces ProduceMarketplace needs.
 *      The Member struct here must exactly match Cooperative.sol's Member struct
 *      (same field order) for cross-contract calls to decode correctly.
 */
interface ICooperative {
    enum Role { None, Admin, Farmer, Buyer }
    enum MemberStatus { Unregistered, Pending, Active, Trusted }

    struct Member {
        address memberAddress;
        Role role;
        MemberStatus status;
        uint256 totalDeposits;
        uint256 currentBalance;
        uint256 successfulSales;
        uint256 joinDate;
        uint256 activeLoanId;
    }

    function getMember(address _member) external view returns (Member memory);
    function creditSaleProceeds(address _farmer, uint256 _amount) external;
}

/**
 * @title ProduceMarketplace
 * @notice Handles produce batch registration, admin approval, and
 *         escrow-based purchasing. Split out from Cooperative.sol to stay
 *         under Ethereum's 24KB contract size limit.
 * @dev Reads membership/role data from Cooperative via the ICooperative
 *      interface. All USDC collected from buyers is immediately forwarded
 *      to the Cooperative contract, which is the single source of truth
 *      for balances and pool liquidity - this contract never holds funds
 *      itself beyond the span of a single transaction.
 */
contract ProduceMarketplace {

    enum BatchStatus { Pending, Available, Sold }

    struct ProduceBatch {
        uint256 batchId;
        address farmerAddress;
        string cropVariety;
        uint256 weightKg;
        uint256 price;
        BatchStatus status;
        uint256 listedTimestamp;
        uint256 approvedTimestamp;
        address buyerAddress;
        uint256 saleTimestamp;
    }

    IERC20 public usdcToken;
    ICooperative public cooperative;

    mapping(uint256 => ProduceBatch) public produceBatches;
    mapping(address => uint256[]) public farmerBatchIds;
    uint256 public batchCounter;

    /// @notice Percentage of each sale kept by the cooperative as pool liquidity
    uint256 public constant COOPERATIVE_COMMISSION_PERCENT = 7;

    event ProduceRegistered(uint256 indexed batchId, address indexed farmer, string cropVariety, uint256 weightKg, uint256 price);
    event ProduceApproved(uint256 indexed batchId, address indexed approvedBy);
    event ProduceSold(uint256 indexed batchId, address indexed buyer, address indexed farmer, uint256 price);
    event FundsDistributed(uint256 indexed batchId, address indexed farmer, uint256 farmerPayout, uint256 cooperativeCommission);

    constructor(address _usdcAddress, address _cooperativeAddress) {
        usdcToken = IERC20(_usdcAddress);
        cooperative = ICooperative(_cooperativeAddress);
    }

    modifier onlyAdmin() {
        ICooperative.Member memory member = cooperative.getMember(msg.sender);
        require(member.role == ICooperative.Role.Admin, "Not authorized: Admin only");
        _;
    }

    modifier onlyFarmer() {
        ICooperative.Member memory member = cooperative.getMember(msg.sender);
        require(member.role == ICooperative.Role.Farmer, "Not authorized: Farmer only");
        _;
    }

    modifier onlyBuyer() {
        ICooperative.Member memory member = cooperative.getMember(msg.sender);
        require(member.role == ICooperative.Role.Buyer, "Not authorized: Buyer only");
        _;
    }

    modifier onlyActiveOrTrusted() {
        ICooperative.Member memory member = cooperative.getMember(msg.sender);
        require(
            member.status == ICooperative.MemberStatus.Active ||
            member.status == ICooperative.MemberStatus.Trusted,
            "Member must be Active or Trusted"
        );
        _;
    }

    function logProduce(
        string calldata _cropVariety,
        uint256 _weightKg,
        uint256 _price
    ) external onlyFarmer onlyActiveOrTrusted {
        require(bytes(_cropVariety).length > 0, "Crop variety is required");
        require(_weightKg > 0, "Weight must be greater than 0");
        require(_price > 0, "Price must be greater than 0");

        batchCounter++;
        uint256 currentBatchId = batchCounter;

        produceBatches[currentBatchId] = ProduceBatch({
            batchId: currentBatchId,
            farmerAddress: msg.sender,
            cropVariety: _cropVariety,
            weightKg: _weightKg,
            price: _price,
            status: BatchStatus.Pending,
            listedTimestamp: block.timestamp,
            approvedTimestamp: 0,
            buyerAddress: address(0),
            saleTimestamp: 0
        });

        farmerBatchIds[msg.sender].push(currentBatchId);

        emit ProduceRegistered(currentBatchId, msg.sender, _cropVariety, _weightKg, _price);
    }

    function approveBatch(uint256 _batchId) external onlyAdmin {
        ProduceBatch storage batch = produceBatches[_batchId];
        require(batch.batchId != 0, "Batch does not exist");
        require(batch.status == BatchStatus.Pending, "Batch is not pending approval");

        batch.status = BatchStatus.Available;
        batch.approvedTimestamp = block.timestamp;

        emit ProduceApproved(_batchId, msg.sender);
    }

    /**
     * @notice Purchase an Available batch. Pulls the full price from the
     *         buyer, forwards all of it to the Cooperative contract (so it
     *         backs the farmer's withdrawable balance and adds to pool
     *         liquidity), then tells Cooperative to credit the farmer's
     *         portion.
     */
    function purchaseBatch(uint256 _batchId) external onlyBuyer {
        ProduceBatch storage batch = produceBatches[_batchId];
        require(batch.batchId != 0, "Batch does not exist");
        require(batch.status == BatchStatus.Available, "Batch is not available for sale");

        uint256 price = batch.price;
        uint256 commission = (price * COOPERATIVE_COMMISSION_PERCENT) / 100;
        uint256 farmerPayout = price - commission;

        bool pulled = usdcToken.transferFrom(msg.sender, address(this), price);
        require(pulled, "USDC transfer failed - did you approve first?");

        // Forward the entire price to Cooperative - it holds all funds and
        // tracks balances. The commission portion simply isn't credited to
        // anyone, which increases the cooperative's available pool liquidity.
        bool forwarded = usdcToken.transfer(address(cooperative), price);
        require(forwarded, "Forwarding funds to Cooperative failed");

        batch.status = BatchStatus.Sold;
        batch.buyerAddress = msg.sender;
        batch.saleTimestamp = block.timestamp;

        cooperative.creditSaleProceeds(batch.farmerAddress, farmerPayout);

        emit ProduceSold(_batchId, msg.sender, batch.farmerAddress, price);
        emit FundsDistributed(_batchId, batch.farmerAddress, farmerPayout, commission);
    }

    function getBatch(uint256 _batchId) external view returns (ProduceBatch memory) {
        return produceBatches[_batchId];
    }

    function getFarmerBatchIds(address _farmer) external view returns (uint256[] memory) {
        return farmerBatchIds[_farmer];
    }
}