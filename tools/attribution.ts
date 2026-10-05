// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
//
// attribution.ts: the ERC-7015 creator attribution for a deployed KohiPiece.
//
//   npx tsx tools/attribution.ts --piece 0x... --creator 0x... --rpc <url>
//
// KohiPiece.attributeCreator(creator, signature) takes the creator's EIP-712
// signature of ArtworkCreation(programHash, seedsHash) under the piece's own
// domain (its name, "1", the chain id, its address). The piece reports that
// domain (ERC-5267) and both hashes, which exist only after lockArt and
// lockSeeds.
//
// This tool reads them, writes the typed data to
// dist/attribution/<chain>-<piece>.json, and prints the two commands to run:
// sign as the creator, then send from the piece's owner. It signs nothing and
// sends nothing.

import { writeFileSync, mkdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, getAddress, parseAbi, type Address, type Hex } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const abi = parseAbi([
  "function programHash() view returns (bytes32)",
  "function seedsHash() view returns (bytes32)",
  "function artLocked() view returns (bool)",
  "function seedsLocked() view returns (bool)",
  "function creator() view returns (address)",
  "function eip712Domain() view returns (bytes1, string, string, uint256, address, bytes32, uint256[])",
]);

/** The EIP-712 typed data the creator signs, in the shape cast and viem accept. */
export function artworkTypedData(
  domain: { name: string; version: string; chainId: number; verifyingContract: Address },
  programHash: Hex,
  seedsHash: Hex,
) {
  return {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      ArtworkCreation: [
        { name: "programHash", type: "bytes32" },
        { name: "seedsHash", type: "bytes32" },
      ],
    },
    primaryType: "ArtworkCreation" as const,
    domain,
    message: { programHash, seedsHash },
  };
}

/** Read the domain and the locked hashes from a deployed piece. */
export async function readArtworkTypedData(rpcUrl: string, piece: Address) {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const read = (functionName: any) => client.readContract({ address: piece, abi, functionName } as any) as Promise<any>;
  if (!(await read("artLocked")) || !(await read("seedsLocked"))) {
    throw new Error("the piece is not locked yet: attribution follows lockArt and lockSeeds");
  }
  const already = getAddress(await read("creator"));
  if (already !== "0x0000000000000000000000000000000000000000") throw new Error(`already attributed to ${already}`);
  const [, name, version, chainId, verifyingContract] = await read("eip712Domain");
  return artworkTypedData(
    { name, version, chainId: Number(chainId), verifyingContract: getAddress(verifyingContract) },
    await read("programHash"),
    await read("seedsHash"),
  );
}

async function main() {
  const argv = process.argv.slice(2);
  const val = (n: string) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : undefined; };
  const piece = getAddress(val("piece") ?? "");
  const creator = getAddress(val("creator") ?? "");
  const rpc = val("rpc") ?? process.env.MAINNET_RPC_URL;
  if (!rpc) throw new Error("pass --rpc <url> or set MAINNET_RPC_URL");
  const typed = await readArtworkTypedData(rpc, piece);
  const dir = join(ROOT, "dist/attribution");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${typed.domain.chainId}-${piece}.json`);
  writeFileSync(file, JSON.stringify(typed, null, 2) + "\n");
  console.log(`typed data: ${file}`);
  console.log(`  domain      ${typed.domain.name} v${typed.domain.version}, chain ${typed.domain.chainId}`);
  console.log(`  programHash ${typed.message.programHash}\n  seedsHash   ${typed.message.seedsHash}`);
  console.log(`\n1. sign as the creator (${creator}), for example on a Ledger:`);
  console.log(`   cast wallet sign --ledger --data --from-file "${file}"`);
  console.log(`\n2. send from the piece's owner, with the signature from step 1:`);
  console.log(`   cast send ${piece} "attributeCreator(address,bytes)" ${creator} <signature> --ledger --rpc-url <url>`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(e.message ?? e); process.exit(1); });
}
