import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-contract-sizer";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 1000 },
      evmVersion: "cancun",
    },
  },

  networks: {
    // Anubis Chain 测试网
    anubisTestnet: {
      url: process.env.ANUBIS_TESTNET_RPC || "https://testnet-rpc.anubis.network",
      chainId: Number(process.env.ANUBIS_TESTNET_CHAIN_ID) || 0,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    // Anubis Chain 主网
    anubisMainnet: {
      url: process.env.ANUBIS_MAINNET_RPC || "https://rpc.anubis.network",
      chainId: Number(process.env.ANUBIS_MAINNET_CHAIN_ID) || 0,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    // 本地开发
    hardhat: {
      chainId: 31337,
    },
  },

  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
  },

  paths: {
    sources: "./contracts",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
