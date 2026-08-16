const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

// Official Circle USDC contract address on Ethereum Sepolia testnet
const SEPOLIA_USDC_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

// Minimum deposit required for a Pending member to become Active (10 USDC)
const MINIMUM_DEPOSIT = 10 * 10**6;

module.exports = buildModule("CooperativeModule", (m) => {
  // 1. Deploy the core Cooperative contract
  const cooperative = m.contract("Cooperative", [
    SEPOLIA_USDC_ADDRESS,
    MINIMUM_DEPOSIT,
  ]);

  // 2. Deploy ProduceMarketplace, pointing it at Cooperative's address
  const marketplace = m.contract("ProduceMarketplace", [
    SEPOLIA_USDC_ADDRESS,
    cooperative,
  ]);

  // 3. Wire them together - tell Cooperative which marketplace is authorized
  //    to call creditSaleProceeds()
  m.call(cooperative, "setProduceMarketplace", [marketplace]);

  return { cooperative, marketplace };
});