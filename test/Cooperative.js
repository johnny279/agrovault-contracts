const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Cooperative + ProduceMarketplace", function () {
  let cooperative, marketplace, usdc;
  let admin, farmer, buyer, randomUser;

  const MINIMUM_DEPOSIT = 10 * 10**6; // 10 USDC

  beforeEach(async function () {
    [admin, farmer, buyer, randomUser] = await ethers.getSigners();

    // 1. Deploy mock USDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();

    // 2. Deploy Cooperative (core contract)
    const Cooperative = await ethers.getContractFactory("Cooperative");
    cooperative = await Cooperative.deploy(usdc.target, MINIMUM_DEPOSIT);

    // 3. Deploy ProduceMarketplace, pointing at Cooperative's address
    const ProduceMarketplace = await ethers.getContractFactory("ProduceMarketplace");
    marketplace = await ProduceMarketplace.deploy(usdc.target, cooperative.target);

    // 4. Wire them together - tell Cooperative which marketplace is authorized
    //    to credit sale proceeds
    await cooperative.setProduceMarketplace(marketplace.target);

    await usdc.mint(farmer.address, 200 * 10**6);
  });

  // ============ MEMBERSHIP & ADMIN ============

  it("should set the deployer as Super Admin", async function () {
    const superAdminAddr = await cooperative.superAdmin();
    expect(superAdminAddr).to.equal(admin.address);

    const adminData = await cooperative.getMember(admin.address);
    expect(adminData.role).to.equal(1); // Admin
    expect(adminData.status).to.equal(3); // Trusted
  });

  it("should allow Super Admin to add a new admin", async function () {
    await cooperative.addAdmin(randomUser.address);
    const newAdminData = await cooperative.getMember(randomUser.address);
    expect(newAdminData.role).to.equal(1); // Admin

    const count = await cooperative.adminCount();
    expect(count).to.equal(2);
  });

  it("should NOT allow a regular admin to add another admin", async function () {
    await cooperative.addAdmin(randomUser.address); // randomUser is now a regular admin

    await expect(
      cooperative.connect(randomUser).addAdmin(buyer.address)
    ).to.be.revertedWith("Not authorized: Super Admin only");
  });

  it("should allow Super Admin to remove a regular admin", async function () {
    await cooperative.addAdmin(randomUser.address);
    await cooperative.removeAdmin(randomUser.address);

    const removedData = await cooperative.getMember(randomUser.address);
    expect(removedData.role).to.equal(0); // Role.None

    const count = await cooperative.adminCount();
    expect(count).to.equal(1);
  });

  it("should NOT allow removing the last remaining admin", async function () {
    await expect(
      cooperative.removeAdmin(admin.address)
    ).to.be.revertedWith("Cannot remove the Super Admin - transfer the role first");
  });

  it("should allow Super Admin to transfer the role to another admin", async function () {
    await cooperative.addAdmin(randomUser.address);
    await cooperative.transferSuperAdmin(randomUser.address);

    const newSuperAdmin = await cooperative.superAdmin();
    expect(newSuperAdmin).to.equal(randomUser.address);

    // Old super admin should still be a regular admin
    const oldSuperAdminData = await cooperative.getMember(admin.address);
    expect(oldSuperAdminData.role).to.equal(1); // still Admin
  });

  it("should allow admin to onboard a farmer", async function () {
    await cooperative.onboardFarmer(farmer.address);
    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.role).to.equal(2); // Farmer
    expect(farmerData.status).to.equal(1); // Pending
  });

  // ============ DEPOSITS & LOANS (unchanged behavior, same contract) ============

  it("should let a farmer deposit USDC and become Active", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(2); // Active
  });

  it("should auto-approve a small loan and lock in 10% interest", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 30 * 10**6);
    await cooperative.connect(farmer).deposit(30 * 10**6);
    await usdc.mint(cooperative.target, 500 * 10**6);

    await cooperative.connect(farmer).applyForLoan(15 * 10**6, 3);

    const loan = await cooperative.getLoan(1);
    expect(loan.interestRate).to.equal(10);
  });

  // ============ PRODUCE MARKETPLACE (now cross-contract) ============

  it("should let an Active farmer register produce via the marketplace", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    await marketplace.connect(farmer).logProduce("Maize", 500, 100 * 10**6);

    const batch = await marketplace.getBatch(1);
    expect(batch.farmerAddress).to.equal(farmer.address);
    expect(batch.status).to.equal(0); // Pending
  });

  it("should NOT let a Pending (unfunded) farmer register produce", async function () {
    await cooperative.onboardFarmer(farmer.address);

    await expect(
      marketplace.connect(farmer).logProduce("Maize", 500, 100 * 10**6)
    ).to.be.revertedWith("Member must be Active or Trusted");
  });

  it("should let admin approve a batch via the marketplace", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);
    await marketplace.connect(farmer).logProduce("Cassava", 300, 60 * 10**6);

    await marketplace.approveBatch(1);

    const batch = await marketplace.getBatch(1);
    expect(batch.status).to.equal(1); // Available
  });

  it("should let a buyer purchase a batch, crediting the farmer via Cooperative", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await cooperative.onboardBuyer(buyer.address);

    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    await marketplace.connect(farmer).logProduce("Maize", 500, 100 * 10**6);
    await marketplace.approveBatch(1);

    await usdc.mint(buyer.address, 100 * 10**6);
    await usdc.connect(buyer).approve(marketplace.target, 100 * 10**6);

    await marketplace.connect(buyer).purchaseBatch(1);

    const batch = await marketplace.getBatch(1);
    expect(batch.status).to.equal(2); // Sold

    // Farmer's balance lives in Cooperative, credited via creditSaleProceeds
    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.currentBalance).to.equal(15 * 10**6 + 93 * 10**6); // deposit + 93% payout
    expect(farmerData.status).to.equal(3); // Trusted (first sale)
  });

  it("should NOT let a non-marketplace address call creditSaleProceeds directly", async function () {
    await cooperative.onboardFarmer(farmer.address);

    await expect(
      cooperative.connect(randomUser).creditSaleProceeds(farmer.address, 10 * 10**6)
    ).to.be.revertedWith("Not authorized: Marketplace only");
  });

  it("should give a Trusted farmer a loan cap based on 10% of treasury", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await cooperative.onboardBuyer(buyer.address);

    await usdc.mint(farmer.address, 1000 * 10**6);
    await usdc.connect(farmer).approve(cooperative.target, 500 * 10**6);
    await cooperative.connect(farmer).deposit(500 * 10**6);

    await marketplace.connect(farmer).logProduce("Maize", 500, 100 * 10**6);
    await marketplace.approveBatch(1);
    await usdc.mint(buyer.address, 100 * 10**6);
    await usdc.connect(buyer).approve(marketplace.target, 100 * 10**6);
    await marketplace.connect(buyer).purchaseBatch(1);

    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(3); // Trusted

    const treasuryBalance = await cooperative.getContractUsdcBalance();
    const expectedCap = (treasuryBalance * 10n) / 100n;

    const maxLoan = await cooperative.getMaxLoanAmount(farmer.address);
    expect(maxLoan).to.equal(expectedCap);
  });
    // ============ REQUEST TO JOIN ============

  it("should let an unregistered address request to join as a Farmer", async function () {
    await cooperative.connect(randomUser).requestToJoin(2); // Role.Farmer

    const request = await cooperative.joinRequests(randomUser.address);
    expect(request.exists).to.equal(true);
    expect(request.requestedRole).to.equal(2); // Farmer
  });

  it("should NOT let an existing member request to join", async function () {
    await cooperative.onboardFarmer(farmer.address);

    await expect(
      cooperative.connect(farmer).requestToJoin(2)
    ).to.be.revertedWith("Already a member");
  });

  it("should NOT let the same address submit two pending requests", async function () {
    await cooperative.connect(randomUser).requestToJoin(2); // Farmer

    await expect(
      cooperative.connect(randomUser).requestToJoin(3) // Buyer
    ).to.be.revertedWith("Request already pending");
  });

  it("should NOT allow requesting the Admin or None role", async function () {
    await expect(
      cooperative.connect(randomUser).requestToJoin(1) // Role.Admin
    ).to.be.revertedWith("Invalid role");
  });

  it("should let an admin approve a join request, onboarding the requester", async function () {
    await cooperative.connect(randomUser).requestToJoin(2); // Farmer
    await cooperative.approveJoinRequest(randomUser.address);

    const memberData = await cooperative.getMember(randomUser.address);
    expect(memberData.role).to.equal(2); // Farmer
    expect(memberData.status).to.equal(1); // Pending

    const request = await cooperative.joinRequests(randomUser.address);
    expect(request.exists).to.equal(false);
  });

  it("should let an admin reject a join request without onboarding", async function () {
    await cooperative.connect(randomUser).requestToJoin(3); // Buyer
    await cooperative.rejectJoinRequest(randomUser.address);

    const memberData = await cooperative.getMember(randomUser.address);
    expect(memberData.role).to.equal(0); // Role.None

    const request = await cooperative.joinRequests(randomUser.address);
    expect(request.exists).to.equal(false);
  });

  it("should NOT let a non-admin approve or reject a join request", async function () {
    await cooperative.connect(randomUser).requestToJoin(2);

    await expect(
      cooperative.connect(buyer).approveJoinRequest(randomUser.address)
    ).to.be.revertedWith("Not authorized: Admin only");
  });

  it("should keep the pending list consistent after approving a middle request", async function () {
    // Three separate wallets request to join
    await cooperative.connect(randomUser).requestToJoin(2);
    await cooperative.connect(farmer).requestToJoin(2);
    await cooperative.connect(buyer).requestToJoin(3);

    // Approve the middle one - this exercises the swap-and-pop logic
    await cooperative.approveJoinRequest(farmer.address);

    const remaining = await cooperative.getPendingRequests();
    expect(remaining.length).to.equal(2);

    const remainingAddresses = remaining.map((r) => r.requester);
    expect(remainingAddresses).to.include(randomUser.address);
    expect(remainingAddresses).to.include(buyer.address);
    expect(remainingAddresses).to.not.include(farmer.address);
  });

  // ============ WITHDRAWAL STATUS DOWNGRADE ============

  it("should downgrade an Active member back to Pending if balance drops below minimumDeposit", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    let farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(2); // Active

    // Withdraw enough to drop below the 10 USDC minimum
    await cooperative.connect(farmer).withdraw(10 * 10**6);

    farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.currentBalance).to.equal(5 * 10**6);
    expect(farmerData.status).to.equal(1); // Pending
  });

  it("should emit StatusDowngraded when balance drops below minimumDeposit", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    await expect(cooperative.connect(farmer).withdraw(10 * 10**6))
      .to.emit(cooperative, "StatusDowngraded")
      .withArgs(farmer.address, 1); // MemberStatus.Pending
  });

  it("should NOT downgrade if balance stays at or above minimumDeposit", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 20 * 10**6);
    await cooperative.connect(farmer).deposit(20 * 10**6);

    await cooperative.connect(farmer).withdraw(5 * 10**6); // still 15 left, above 10 minimum

    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(2); // still Active
  });

  it("should NOT downgrade a Trusted member on withdrawal (only Active is checked)", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await cooperative.onboardBuyer(buyer.address);

    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    await marketplace.connect(farmer).logProduce("Maize", 500, 100 * 10**6);
    await marketplace.approveBatch(1);
    await usdc.mint(buyer.address, 100 * 10**6);
    await usdc.connect(buyer).approve(marketplace.target, 100 * 10**6);
    await marketplace.connect(buyer).purchaseBatch(1);

    let farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(3); // Trusted after first sale

    // Withdraw almost everything, well below minimumDeposit
    await cooperative.connect(farmer).withdraw(farmerData.currentBalance - 1n);

    farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.status).to.equal(3); // still Trusted - downgrade only applies to Active
  });

  // ============ REMOVE MEMBER ============

  it("should let an admin remove a Farmer with zero balance and no active loan", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await cooperative.removeMember(farmer.address);

    const farmerData = await cooperative.getMember(farmer.address);
    expect(farmerData.role).to.equal(0); // Role.None
  });

  it("should NOT let an admin remove a member with a nonzero balance", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 15 * 10**6);
    await cooperative.connect(farmer).deposit(15 * 10**6);

    await expect(
      cooperative.removeMember(farmer.address)
    ).to.be.revertedWith("Member must withdraw their balance first");
  });

  it("should NOT let an admin remove a member with an active loan", async function () {
    await cooperative.onboardFarmer(farmer.address);
    await usdc.connect(farmer).approve(cooperative.target, 30 * 10**6);
    await cooperative.connect(farmer).deposit(30 * 10**6);
    await usdc.mint(cooperative.target, 500 * 10**6);
    await cooperative.connect(farmer).applyForLoan(15 * 10**6, 3);

    // Withdraw the deposit back down to zero so only the loan blocks removal
    const farmerData = await cooperative.getMember(farmer.address);
    await cooperative.connect(farmer).withdraw(farmerData.currentBalance);

    await expect(
      cooperative.removeMember(farmer.address)
    ).to.be.revertedWith("Member has an active loan - must be repaid first");
  });

  it("should NOT let removeMember target an Admin", async function () {
    await expect(
      cooperative.removeMember(admin.address)
    ).to.be.revertedWith("Can only remove Farmer or Buyer members");
  });

  it("should NOT let a non-admin call removeMember", async function () {
    await cooperative.onboardFarmer(farmer.address);

    await expect(
      cooperative.connect(randomUser).removeMember(farmer.address)
    ).to.be.revertedWith("Not authorized: Admin only");
  });
});