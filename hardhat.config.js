require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1
      },
      viaIR: true
    }
  },
  networks: {
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL,
      accounts: [
        process.env.PRIVATE_KEY,
        process.env.FARMER_PRIVATE_KEY,
        process.env.BUYER_PRIVATE_KEY
      ],
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY
  },
};