// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Cooperative {

    enum Role { None, Admin, Farmer, Buyer }
    enum MemberStatus { Unregistered, Pending, Active, Trusted }
    enum LoanStatus { None, Pending, Approved, Rejected, Repaid }

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

    struct JoinRequest {
        address requester;
        Role requestedRole;
        uint256 requestTimestamp;
        bool exists;
    }

    IERC20 public usdcToken;
    address public superAdmin;
    uint256 public adminCount;

    address public produceMarketplace;

    mapping(address => Member) public members;
    mapping(uint256 => Loan) public loans;
    uint256 public loanCounter;

    uint256 public minimumDeposit;

    mapping(address => JoinRequest) public joinRequests;
    address[] public pendingRequestAddresses;
    mapping(address => uint256) private pendingRequestIndex;

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

    event MemberOnboarded(address indexed memberAddress, Role role, uint256 timestamp);
    event StatusUpgraded(address indexed memberAddress, MemberStatus newStatus);
    event StatusDowngraded(address indexed memberAddress, MemberStatus newStatus);
    event DepositMade(address indexed member, uint256 amount, uint256 newBalance);
    event WithdrawalMade(address indexed member, uint256 amount, uint256 newBalance);
    event LoanApplied(uint256 indexed loanId, address indexed applicant, uint256 amount, uint256 durationMonths);
    event LoanApproved(uint256 indexed loanId, address indexed applicant, uint256 amount, uint256 dueDate);
    event LoanRejected(uint256 indexed loanId, address indexed applicant);
    event LoanRepaid(uint256 indexed loanId, address indexed applicant, uint256 totalPaid, uint256 penaltyPaid);
    event AdminAdded(address indexed newAdmin, address indexed addedBy);
    event AdminRemoved(address indexed removedAdmin, address indexed removedBy);
    event SuperAdminTransferred(address indexed previousSuperAdmin, address indexed newSuperAdmin);

    event MarketplaceSet(address indexed marketplace, address indexed setBy);
    event SaleProceedsCredited(address indexed farmer, uint256 amount);

    event JoinRequested(address indexed requester, Role requestedRole, uint256 timestamp);
    event JoinRequestApproved(address indexed requester, address indexed approvedBy);
    event JoinRequestRejected(address indexed requester, address indexed rejectedBy);
    event MemberRemoved(address indexed memberAddress, Role previousRole, address indexed removedBy);

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

    modifier onlyMarketplace() {
        require(msg.sender == produceMarketplace, "Not authorized: Marketplace only");
        _;
    }

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

    function setProduceMarketplace(address _marketplace) external onlySuperAdmin {
        require(_marketplace != address(0), "Invalid address");
        produceMarketplace = _marketplace;
        emit MarketplaceSet(_marketplace, msg.sender);
    }

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

    function onboardFarmer(address _farmerAddress) external onlyAdmin {
        _onboardFarmer(_farmerAddress);
    }

    function onboardBuyer(address _buyerAddress) external onlyAdmin {
        _onboardBuyer(_buyerAddress);
    }

    function _onboardFarmer(address _farmerAddress) internal {
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

    function _onboardBuyer(address _buyerAddress) internal {
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

    function requestToJoin(Role _requestedRole) external {
        require(members[msg.sender].role == Role.None, "Already a member");
        require(_requestedRole == Role.Farmer || _requestedRole == Role.Buyer, "Invalid role");
        require(!joinRequests[msg.sender].exists, "Request already pending");

        joinRequests[msg.sender] = JoinRequest({
            requester: msg.sender,
            requestedRole: _requestedRole,
            requestTimestamp: block.timestamp,
            exists: true
        });

        pendingRequestIndex[msg.sender] = pendingRequestAddresses.length;
        pendingRequestAddresses.push(msg.sender);

        emit JoinRequested(msg.sender, _requestedRole, block.timestamp);
    }

    function _clearJoinRequest(address _requester) internal {
        uint256 index = pendingRequestIndex[_requester];
        uint256 lastIndex = pendingRequestAddresses.length - 1;

        if (index != lastIndex) {
            address lastAddress = pendingRequestAddresses[lastIndex];
            pendingRequestAddresses[index] = lastAddress;
            pendingRequestIndex[lastAddress] = index;
        }

        pendingRequestAddresses.pop();
        delete pendingRequestIndex[_requester];
        delete joinRequests[_requester];
    }

    function approveJoinRequest(address _requester) external onlyAdmin {
        require(joinRequests[_requester].exists, "No pending request");
        Role requestedRole = joinRequests[_requester].requestedRole;

        _clearJoinRequest(_requester);

        if (requestedRole == Role.Farmer) {
            _onboardFarmer(_requester);
        } else {
            _onboardBuyer(_requester);
        }

        emit JoinRequestApproved(_requester, msg.sender);
    }

    function rejectJoinRequest(address _requester) external onlyAdmin {
        require(joinRequests[_requester].exists, "No pending request");
        _clearJoinRequest(_requester);
        emit JoinRequestRejected(_requester, msg.sender);
    }

    function getPendingRequests() external view returns (JoinRequest[] memory) {
        JoinRequest[] memory requests = new JoinRequest[](pendingRequestAddresses.length);
        for (uint256 i = 0; i < pendingRequestAddresses.length; i++) {
            requests[i] = joinRequests[pendingRequestAddresses[i]];
        }
        return requests;
    }

    function removeMember(address _memberAddress) external onlyAdmin {
        Member storage member = members[_memberAddress];
        require(
            member.role == Role.Farmer || member.role == Role.Buyer,
            "Can only remove Farmer or Buyer members"
        );
        require(member.currentBalance == 0, "Member must withdraw their balance first");
        require(member.activeLoanId == 0, "Member has an active loan - must be repaid first");

        Role previousRole = member.role;
        delete members[_memberAddress];

        emit MemberRemoved(_memberAddress, previousRole, msg.sender);
    }

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

        if (member.status == MemberStatus.Active && member.currentBalance < minimumDeposit) {
            member.status = MemberStatus.Pending;
            emit StatusDowngraded(msg.sender, MemberStatus.Pending);
        }
    }

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