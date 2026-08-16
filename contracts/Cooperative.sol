// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Cooperative
 * @notice Core contract: membership, admin hierarchy, savings, and lending.
 * @dev Produce registration and escrow sales live in a separate
 *      ProduceMarketplace contract (see ProduceMarketplace.sol) to keep
 *      this contract under Ethereum's 24KB contract size limit.
 *      ProduceMarketplace is granted limited write access via the
 *      onlyMarketplace modifier - it can credit sale proceeds to a
 *      farmer's balance, but cannot touch anything else.
 */
contract Cooperative {

    // ============ ENUMS ============

    enum Role { None, Admin, Farmer, Buyer }
    enum MemberStatus { Unregistered, Pending, Active, Trusted }
    enum LoanStatus { None, Pending, Approved, Rejected, Repaid }

    // ============ STRUCTS ============

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

    struct Loan {
        uint256 loanId;
        address borrower;
        uint256 principal;
        uint256 durationMonths;
        uint256 interestRate;
        LoanStatus status;
        uint256 requestTimestamp;
        uint256 approvalTimestamp;
        uint256 dueDate;
        uint256 repaymentTimestamp;
    }

    // ============ STATE VARIABLES ============

    IERC20 public usdcToken;
    address public superAdmin;
    uint256 public adminCount;

    /// @notice The single ProduceMarketplace contract allowed to credit sale proceeds
    address public produceMarketplace;

    mapping(address => Member) public members;
    mapping(uint256 => Loan) public loans;
    uint256 public loanCounter;

    uint256 public minimumDeposit;

    uint256 public constant ACTIVE_LOAN_MULTIPLIER = 2;
    uint256 public constant TRUSTED_LOAN_MULTIPLIER = 3;
    uint256 public constant ACTIVE_LOAN_CAP = 50 * 10**6;
    uint256 public constant TRUSTED_TREASURY_PERCENT = 10;
    uint256 public constant AUTO_APPROVE_THRESHOLD = 20 * 10**6;
    uint256 public constant SALES_FOR_TRUSTED_STATUS = 1;

    uint256 public constant SHORT_TERM_RATE = 10;
    uint256 public constant LONG_TERM_RATE = 15;
    uint256 public constant SHORT_TERM_MAX_MONTHS = 6;
    uint256 public constant LATE_PENALTY_PER_MONTH = 2;
    uint256 public constant SECONDS_PER_MONTH = 30 days;

    // ============ EVENTS ============

    event MemberOnboarded(address indexed memberAddress, Role role, uint256 timestamp);
    event StatusUpgraded(address indexed memberAddress, MemberStatus newStatus);
    event DepositMade(address indexed member, uint256 amount, uint256 newBalance);
    event WithdrawalMade(address indexed member, uint256 amount, uint256 newBalance);
    event LoanApplied(uint256 indexed loanId, address indexed applicant, uint256 amount, uint256 durationMonths);
    event LoanApproved(uint256 indexed loanId, address indexed applicant, uint256 amount, uint256 dueDate);
    event LoanRejected(uint256 indexed loanId, address indexed applicant);
    event LoanRepaid(uint256 indexed loanId, address indexed applicant, uint256 totalPaid, uint256 penaltyPaid);
    event AdminAdded(address indexed newAdmin, address indexed addedBy);
    event AdminRemoved(address indexed removedAdmin, address indexed removedBy);
    event SuperAdminTransferred(address indexed previousSuperAdmin, address indexed newSuperAdmin);

    /// @notice Emitted when the ProduceMarketplace contract address is set/updated
    event MarketplaceSet(address indexed marketplace, address indexed setBy);

    /// @notice Emitted when sale proceeds are credited to a farmer by the marketplace
    event SaleProceedsCredited(address indexed farmer, uint256 amount);

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        require(members[msg.sender].role == Role.Admin, "Not authorized: Admin only");
        _;
    }

    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Not authorized: Super Admin only");
        _;
    }

    modifier onlyFarmer() {
        require(members[msg.sender].role == Role.Farmer, "Not authorized: Farmer only");
        _;
    }

    modifier onlyActiveOrTrusted() {
        require(
            members[msg.sender].status == MemberStatus.Active ||
            members[msg.sender].status == MemberStatus.Trusted,
            "Member must be Active or Trusted"
        );
        _;
    }

    /// @dev Restricts a function so only the registered ProduceMarketplace contract can call it
    modifier onlyMarketplace() {
        require(msg.sender == produceMarketplace, "Not authorized: Marketplace only");
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _usdcAddress, uint256 _minimumDeposit) {
        superAdmin = msg.sender;
        usdcToken = IERC20(_usdcAddress);
        minimumDeposit = _minimumDeposit;

        members[msg.sender] = Member({
            memberAddress: msg.sender,
            role: Role.Admin,
            status: MemberStatus.Trusted,
            totalDeposits: 0,
            currentBalance: 0,
            successfulSales: 0,
            joinDate: block.timestamp,
            activeLoanId: 0
        });

        adminCount = 1;

        emit MemberOnboarded(msg.sender, Role.Admin, block.timestamp);
    }

    // ============ MARKETPLACE WIRING (Super Admin only) ============

    /**
     * @notice Registers the ProduceMarketplace contract allowed to credit
     *         sale proceeds to farmers. Must be set after both contracts
     *         are deployed.
     * @param _marketplace Address of the deployed ProduceMarketplace contract
     */
    function setProduceMarketplace(address _marketplace) external onlySuperAdmin {
        require(_marketplace != address(0), "Invalid address");
        produceMarketplace = _marketplace;
        emit MarketplaceSet(_marketplace, msg.sender);
    }

    /**
     * @notice Called by ProduceMarketplace after a completed sale to credit
     *         the farmer's withdrawable balance and record the sale toward
     *         their Trusted-tier progress.
     * @dev The marketplace must have already transferred the corresponding
     *      USDC into this contract before calling this - this function only
     *      updates internal accounting, it does not move funds itself.
     * @param _farmer The farmer to credit
     * @param _amount The farmer's payout amount, in raw USDC units
     */
    function creditSaleProceeds(address _farmer, uint256 _amount) external onlyMarketplace {
        require(members[_farmer].role == Role.Farmer, "Not a registered farmer");

        Member storage member = members[_farmer];
        member.currentBalance += _amount;
        member.successfulSales += 1;

        if (member.successfulSales >= SALES_FOR_TRUSTED_STATUS && member.status == MemberStatus.Active) {
            member.status = MemberStatus.Trusted;
            emit StatusUpgraded(_farmer, MemberStatus.Trusted);
        }

        emit SaleProceedsCredited(_farmer, _amount);
    }

    // ============ ADMIN MANAGEMENT (Super Admin only) ============

    function addAdmin(address _newAdmin) external onlySuperAdmin {
        require(_newAdmin != address(0), "Invalid address");
        require(members[_newAdmin].role == Role.None, "Address already has a role");

        members[_newAdmin] = Member({
            memberAddress: _newAdmin,
            role: Role.Admin,
            status: MemberStatus.Trusted,
            totalDeposits: 0,
            currentBalance: 0,
            successfulSales: 0,
            joinDate: block.timestamp,
            activeLoanId: 0
        });

        adminCount++;

        emit AdminAdded(_newAdmin, msg.sender);
        emit MemberOnboarded(_newAdmin, Role.Admin, block.timestamp);
    }

    function removeAdmin(address _adminToRemove) external onlySuperAdmin {
        require(members[_adminToRemove].role == Role.Admin, "Address is not an admin");
        require(_adminToRemove != superAdmin, "Cannot remove the Super Admin - transfer the role first");
        require(adminCount > 1, "Cannot remove the last remaining admin");

        members[_adminToRemove].role = Role.None;
        members[_adminToRemove].status = MemberStatus.Unregistered;

        adminCount--;

        emit AdminRemoved(_adminToRemove, msg.sender);
    }

    function transferSuperAdmin(address _newSuperAdmin) external onlySuperAdmin {
        require(members[_newSuperAdmin].role == Role.Admin, "New Super Admin must already be an Admin");
        require(_newSuperAdmin != superAdmin, "Already the Super Admin");

        address previousSuperAdmin = superAdmin;
        superAdmin = _newSuperAdmin;

        emit SuperAdminTransferred(previousSuperAdmin, _newSuperAdmin);
    }

    // ============ MEMBER ONBOARDING ============

    function onboardFarmer(address _farmerAddress) external onlyAdmin {
        require(_farmerAddress != address(0), "Invalid address");
        require(members[_farmerAddress].role == Role.None, "Already a member");

        members[_farmerAddress] = Member({
            memberAddress: _farmerAddress,
            role: Role.Farmer,
            status: MemberStatus.Pending,
            totalDeposits: 0,
            currentBalance: 0,
            successfulSales: 0,
            joinDate: block.timestamp,
            activeLoanId: 0
        });

        emit MemberOnboarded(_farmerAddress, Role.Farmer, block.timestamp);
    }

    function onboardBuyer(address _buyerAddress) external onlyAdmin {
        require(_buyerAddress != address(0), "Invalid address");
        require(members[_buyerAddress].role == Role.None, "Already a member");

        members[_buyerAddress] = Member({
            memberAddress: _buyerAddress,
            role: Role.Buyer,
            status: MemberStatus.Pending,
            totalDeposits: 0,
            currentBalance: 0,
            successfulSales: 0,
            joinDate: block.timestamp,
            activeLoanId: 0
        });

        emit MemberOnboarded(_buyerAddress, Role.Buyer, block.timestamp);
    }

    // ============ DEPOSITS & WITHDRAWALS (USDC) ============

    function deposit(uint256 _amount) external {
        require(members[msg.sender].role != Role.None, "Not a registered member");
        require(_amount > 0, "Deposit must be greater than 0");

        bool success = usdcToken.transferFrom(msg.sender, address(this), _amount);
        require(success, "USDC transfer failed - did you approve first?");

        Member storage member = members[msg.sender];
        member.totalDeposits += _amount;
        member.currentBalance += _amount;

        emit DepositMade(msg.sender, _amount, member.currentBalance);

        if (member.status == MemberStatus.Pending && member.totalDeposits >= minimumDeposit) {
            member.status = MemberStatus.Active;
            emit StatusUpgraded(msg.sender, MemberStatus.Active);
        }
    }

    function withdraw(uint256 _amount) external {
        Member storage member = members[msg.sender];
        require(member.role != Role.None, "Not a registered member");
        require(_amount > 0, "Amount must be greater than 0");
        require(member.currentBalance >= _amount, "Insufficient balance");

        member.currentBalance -= _amount;

        bool success = usdcToken.transfer(msg.sender, _amount);
        require(success, "Withdrawal transfer failed");

        emit WithdrawalMade(msg.sender, _amount, member.currentBalance);
    }

    // ============ LOANS ============

    function applyForLoan(uint256 _amount, uint256 _durationMonths) external onlyFarmer onlyActiveOrTrusted {
        require(_amount > 0, "Loan amount must be greater than 0");
        require(_durationMonths >= 1, "Duration must be at least 1 month");

        Member storage member = members[msg.sender];
        require(member.activeLoanId == 0, "You already have an active loan");

        uint256 maxLoan = _calculateMaxLoan(msg.sender);
        require(_amount <= maxLoan, "Amount exceeds your loan limit");

        uint256 rate = _durationMonths <= SHORT_TERM_MAX_MONTHS ? SHORT_TERM_RATE : LONG_TERM_RATE;

        loanCounter++;
        uint256 currentLoanId = loanCounter;

        loans[currentLoanId] = Loan({
            loanId: currentLoanId,
            borrower: msg.sender,
            principal: _amount,
            durationMonths: _durationMonths,
            interestRate: rate,
            status: LoanStatus.Pending,
            requestTimestamp: block.timestamp,
            approvalTimestamp: 0,
            dueDate: 0,
            repaymentTimestamp: 0
        });

        member.activeLoanId = currentLoanId;

        emit LoanApplied(currentLoanId, msg.sender, _amount, _durationMonths);

        if (_amount <= AUTO_APPROVE_THRESHOLD) {
            _approveLoan(currentLoanId);
        }
    }

    function approveLoan(uint256 _loanId) external onlyAdmin {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.Pending, "Loan not pending");
        _approveLoan(_loanId);
    }

    function _approveLoan(uint256 _loanId) internal {
        Loan storage loan = loans[_loanId];
        require(usdcToken.balanceOf(address(this)) >= loan.principal, "Insufficient pool liquidity");

        loan.status = LoanStatus.Approved;
        loan.approvalTimestamp = block.timestamp;
        loan.dueDate = block.timestamp + (loan.durationMonths * SECONDS_PER_MONTH);

        bool success = usdcToken.transfer(loan.borrower, loan.principal);
        require(success, "USDC payout failed");

        emit LoanApproved(_loanId, loan.borrower, loan.principal, loan.dueDate);
    }

    function rejectLoan(uint256 _loanId) external onlyAdmin {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.Pending, "Loan not pending");

        loan.status = LoanStatus.Rejected;
        members[loan.borrower].activeLoanId = 0;

        emit LoanRejected(_loanId, loan.borrower);
    }

    function repayLoan(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];
        require(loan.borrower == msg.sender, "Not your loan");
        require(loan.status == LoanStatus.Approved, "Loan not in approved state");

        (uint256 totalOwed, uint256 penalty) = _calculateRepaymentAmount(_loanId);

        bool success = usdcToken.transferFrom(msg.sender, address(this), totalOwed);
        require(success, "Repayment transfer failed - did you approve first?");

        loan.status = LoanStatus.Repaid;
        loan.repaymentTimestamp = block.timestamp;
        members[msg.sender].activeLoanId = 0;

        emit LoanRepaid(_loanId, msg.sender, totalOwed, penalty);
    }

    // ============ INTERNAL LOGIC ============

    function _calculateMaxLoan(address _member) internal view returns (uint256) {
        Member storage member = members[_member];

        if (member.status == MemberStatus.Trusted) {
            uint256 depositBased = member.totalDeposits * TRUSTED_LOAN_MULTIPLIER;
            uint256 treasuryBased = (usdcToken.balanceOf(address(this)) * TRUSTED_TREASURY_PERCENT) / 100;
            return depositBased < treasuryBased ? depositBased : treasuryBased;
        } else {
            uint256 depositBased = member.totalDeposits * ACTIVE_LOAN_MULTIPLIER;
            return depositBased < ACTIVE_LOAN_CAP ? depositBased : ACTIVE_LOAN_CAP;
        }
    }

    function _calculateRepaymentAmount(uint256 _loanId) internal view returns (uint256, uint256) {
        Loan storage loan = loans[_loanId];

        uint256 interest = (loan.principal * loan.interestRate) / 100;
        uint256 baseTotal = loan.principal + interest;

        uint256 penalty = 0;
        if (block.timestamp > loan.dueDate) {
            uint256 secondsLate = block.timestamp - loan.dueDate;
            uint256 monthsLate = (secondsLate / SECONDS_PER_MONTH) + 1;
            penalty = (baseTotal * LATE_PENALTY_PER_MONTH * monthsLate) / 100;
        }

        return (baseTotal + penalty, penalty);
    }

    // ============ VIEW FUNCTIONS ============

    function getMember(address _member) external view returns (Member memory) {
        return members[_member];
    }

    function getLoan(uint256 _loanId) external view returns (Loan memory) {
        return loans[_loanId];
    }

    function getMaxLoanAmount(address _member) external view returns (uint256) {
        return _calculateMaxLoan(_member);
    }

    function previewRepaymentAmount(uint256 _loanId) external view returns (uint256 totalOwed, uint256 penalty) {
        return _calculateRepaymentAmount(_loanId);
    }

    function getContractUsdcBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }
}