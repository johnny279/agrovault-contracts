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
});