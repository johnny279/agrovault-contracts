# AgroVault — Smart Contracts

Solidity smart contracts powering AgroVault, a blockchain-based cooperative platform for farmers and buyers. Deployed and verified on the Sepolia testnet.

🔗 **Live App:** [https://agrovault-eight.vercel.app](https://agrovault-eight.vercel.app)
💻 **Frontend Repo:** [https://github.com/johnny279/Agrovault](https://github.com/johnny279/Agrovault)

## Contracts

- **`Cooperative.sol`** — Core contract handling membership, admin hierarchy, savings deposits/withdrawals, and lending
- **`ProduceMarketplace.sol`** — Produce batch registration, admin approval, and escrow-based purchasing between farmers and buyers
- **`MockUSDC.sol`** — Test ERC20 token (6 decimals) standing in for USDC on Sepolia

## Deployed Addresses (Sepolia)

See `ignition/deployments/chain-11155111/deployed_addresses.json` for the current deployment addresses.

## Tech Stack

- Solidity ^0.8.28
- Hardhat + Hardhat Ignition
- OpenZeppelin Contracts

## Testing

```bash
npx hardhat test
```

26 passing tests covering membership, deposits/withdrawals, loan approval/repayment, and produce sale flows.

## Local Development

```bash
npm install
npx hardhat compile
npx hardhat test
```
