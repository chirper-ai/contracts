// hardhat.config.js
require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("@openzeppelin/hardhat-upgrades");

// Load environment variables if needed
// require('dotenv').config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  // Solidity compiler configuration
  solidity: {
    version: "0.8.22",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      // Required for OpenZeppelin 5.0
      evmVersion: "paris",
      viaIR: true,
    }
  },

  // Network configurations
  networks: {
    // Local network
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    // Add other networks as needed
    // mainnet: {
    //   url: `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
    //   accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    // },
  },

  // Path configuration
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },

  // Mocha configuration for testing
  mocha: {
    timeout: 40000
  }
};