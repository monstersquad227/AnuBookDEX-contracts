/**
 * 将编译产物中的 ABI 复制到 Go 项目的 contracts/abi/ 目录
 * 用法: npx hardhat run scripts/export-abi.ts
 */
import * as fs from "fs";
import * as path from "path";

const ARTIFACTS_DIR = path.join(__dirname, "..", "artifacts", "contracts");
const GO_ABI_DIR = path.join(__dirname, "..", "..", "AnuBookDEX", "contracts", "abi");

const contracts = [
  "OrderBookRegistry",
  "Settlement",
  "LeverageManager",
  "DarkPoolRouter",
  "ZKKYC",
  "LiquidityRouter",
  "LPMiningRewards",
];

async function main() {
  if (!fs.existsSync(GO_ABI_DIR)) {
    fs.mkdirSync(GO_ABI_DIR, { recursive: true });
  }

  console.log("Exporting ABIs to:", GO_ABI_DIR, "\n");

  for (const name of contracts) {
    const artifactPath = path.join(ARTIFACTS_DIR, `${name}.sol`, `${name}.json`);
    if (!fs.existsSync(artifactPath)) {
      console.error(`  SKIP: artifact not found: ${artifactPath}`);
      continue;
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
    const abiPath = path.join(GO_ABI_DIR, `${name}.json`);
    fs.writeFileSync(abiPath, JSON.stringify(artifact.abi, null, 2));
    console.log(`  Exported: ${name}.json`);
  }

  console.log("\nABI export complete.");
  console.log("\nGenerate Go bindings:");
  for (const name of contracts) {
    const goFile = name
      .replace(/([A-Z])/g, "_$1")
      .toLowerCase()
      .replace(/^_/, "");
    console.log(
      `  abigen --abi=contracts/abi/${name}.json --pkg=bindings --out=contracts/bindings/${goFile}.go`
    );
  }
}

main().catch(console.error);
