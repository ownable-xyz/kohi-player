#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
//
// deploy.mjs: the deploy steps for a piece, as one CLI.
//
//   node tools/deploy.mjs status                      what is recorded, balances, nonce
//   node tools/deploy.mjs preview [--tokens 1,2,17]   local HTML of real tokenURIs (fork simulation)
//   node tools/deploy.mjs player  [--send]            1. the shared PiecePlayer
//   node tools/deploy.mjs piece   [--send]            2. the piece, using the recorded player
//   node tools/deploy.mjs sale    [--send]            3. its HolderSale, for the recorded piece
//   node tools/deploy.mjs player --again [--send]     a new player (e.g. new page chrome) on the
//                                                     recorded BlobStore: only new bytes are stored
//   node tools/deploy.mjs use-player [--send]         point the piece's tokenURI at the recorded
//                                                     player (setTokenURIModule; before lockTokenURI)
//   node tools/deploy.mjs image-player [--send]       a player that adds "image": <pinned works>/<id>.png,
//                                                     on the recorded artifact; recorded, not switched to
//                                                     (then: use-player --image --send)
//   node tools/deploy.mjs image-player --v2 [--send]  a PiecePlayerV2 (the page in a base64 JSON document)
//                                                     with the pinned images, on a new artifact built from the
//                                                     current page template on the recorded store (only new
//                                                     bytes are stored); --artifact <addr> reuses an artifact
//                                                     instead (then: use-player --image --v2 --send)
//   node tools/deploy.mjs image-player --v3 [--send]  a PiecePlayerV3 (the page in base64 inside a base64
//                                                     JSON document) on a new artifact with the template and
//                                                     the raw DEFLATE wasm modules; --artifact <addr> reuses
//                                                     one (then: use-player --image --v3 --send)
//   node tools/deploy.mjs contract-uri [--send]       set the collection metadata (ERC-7572): name,
//                                                     symbol, description, and the pinned logo, banner
//                                                     and featured image; changeable until lockContractURI
//   node tools/deploy.mjs attribute --signature 0x... [--creator 0x...] [--send]
//                                                     record the creator (ERC-7015) with the creator's
//                                                     signature of the typed data (tools/attribution.ts);
//                                                     checked by simulation first; once only
//   node tools/deploy.mjs approve [--revoke] [--seller-path m/...] [--send]
//                                                     the seller approves (or revokes) the recorded sale on
//                                                     the piece; checks the sale's code hash first; signs
//                                                     with the seller's Ledger path (SELLER_HD_PATH)
//
// Without --send a step is a dry run: forge simulates it against the live chain
// and nothing is signed. With --send it asks you to type the step name, then
// broadcasts, signing on the Ledger, and records the new addresses in
// deploy/<network>.json, which the next step reads.
//
// Options: --config pieces/rakel/piece.json   --network mainnet (default)
//          --rpc <url> --unlocked             (a local fork: no Ledger; anvil signs)
//
// The RPC URL comes from MAINNET_RPC_URL in the environment or ./.env, and
// is never printed. This tool never verifies source.

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline/promises";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const cmd = argv[0];
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);

const NETWORK = opt("network", "mainnet");
const CONFIG_PATH = opt("config", "pieces/rakel/piece.json");
const LEDGER_FILE = join(ROOT, "deploy", `${flag("unlocked") ? "fork" : NETWORK}.json`);
const SEND = flag("send");

// The deployer and its Ledger path, kept beside the recorded addresses.
const DEFAULTS = {
  mainnet: { deployer: "0xAFA08732b9A1D334686B0ca5f6D9B9C6953993B0", chainId: 1 },
};

// Errors unwind to main's catch, so Node exits on its own (exiting during an
// open network handle trips an assertion in Node on Windows).
class Fatal extends Error {}
function die(msg) { throw new Fatal(msg); }

function envFromFile(path, key) {
  if (!existsSync(path)) return undefined;
  const m = new RegExp(`^\\s*${key}\\s*=\\s*"?([^"\\r\\n]+)"?`, "m").exec(readFileSync(path, "utf8"));
  return m ? m[1].trim() : undefined;
}

function rpcUrl() {
  if (opt("rpc")) return opt("rpc");
  const key = `${NETWORK.toUpperCase()}_RPC_URL`;
  const v = process.env[key] ?? envFromFile(join(ROOT, ".env"), key);
  if (!v) die(`${key} not found in the environment or ./.env`);
  return v;
}

// Ledger derivation paths are local, never committed: --hd-path / --seller-path,
// or DEPLOYER_HD_PATH / SELLER_HD_PATH in the environment or ./.env.
function localEnv(key) {
  return process.env[key] ?? envFromFile(join(ROOT, ".env"), key);
}
function deployerPath() {
  const p = opt("hd-path") ?? localEnv("DEPLOYER_HD_PATH");
  if (!p) die("set DEPLOYER_HD_PATH in ./.env (the deployer's Ledger derivation path) or pass --hd-path");
  return p;
}
function sellerPath() {
  const p = opt("seller-path") ?? localEnv("SELLER_HD_PATH");
  if (!p) die("set SELLER_HD_PATH in ./.env (the seller's Ledger derivation path) or pass --seller-path");
  return p;
}

function loadLedger() {
  const base = { network: NETWORK, ...(DEFAULTS[NETWORK] ?? {}), contracts: {}, history: [] };
  return existsSync(LEDGER_FILE) ? { ...base, ...JSON.parse(readFileSync(LEDGER_FILE, "utf8")) } : base;
}

function saveLedger(l) {
  mkdirSync(dirname(LEDGER_FILE), { recursive: true });
  writeFileSync(LEDGER_FILE, JSON.stringify(l, null, 2) + "\n");
}

async function rpc(url, method, params) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const eth = (hexWei) => (Number(BigInt(hexWei)) / 1e18).toFixed(6);

/** Run forge with arguments (no shell); the RPC URL goes through the env, never argv echo. */
function forge(args, env = {}) {
  const r = spawnSync("forge", args, { cwd: ROOT, env: { ...process.env, ...env }, encoding: "utf8", stdio: ["inherit", "pipe", "pipe"], maxBuffer: 256 << 20 });
  process.stdout.write(r.stdout ?? "");
  process.stderr.write(r.stderr ?? "");
  if (r.status !== 0) die(`forge exited with status ${r.status}`);
  return r.stdout ?? "";
}

function signerArgs(l) {
  if (flag("unlocked")) return ["--unlocked", "--sender", l.deployer];
  return ["--ledger", "--mnemonic-derivation-paths", deployerPath(), "--sender", l.deployer];
}

async function confirm(step, l, url) {
  const chainId = parseInt(await rpc(url, "eth_chainId", []), 16);
  const want = DEFAULTS[NETWORK]?.chainId;
  if (!flag("unlocked") && want && chainId !== want) die(`the RPC is chain ${chainId}, not ${NETWORK} (${want})`);
  const [bal, nonce, gas] = await Promise.all([
    rpc(url, "eth_getBalance", [l.deployer, "latest"]),
    rpc(url, "eth_getTransactionCount", [l.deployer, "latest"]),
    rpc(url, "eth_gasPrice", []),
  ]);
  console.log(`\n  ${step} on ${flag("unlocked") ? "a local fork" : NETWORK} (chain ${chainId})`);
  console.log(`  deployer ${l.deployer}  balance ${eth(bal)} ETH  nonce ${parseInt(nonce, 16)}  gas ${(Number(BigInt(gas)) / 1e9).toFixed(3)} gwei`);
  if (!SEND) { console.log("  dry run: simulating, nothing will be signed or sent (add --send to broadcast)\n"); return; }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const typed = (await rl.question(`  This broadcasts real transactions. Type "${step}" to continue: `)).trim();
  rl.close();
  if (typed !== step) die("not confirmed; nothing sent");
}

function logged(out, name) {
  const m = new RegExp(`${name}\\s+(0x[0-9a-fA-F]{40})`).exec(out);
  return m ? m[1] : undefined;
}

function record(l, step, found) {
  if (!SEND) return;
  Object.assign(l.contracts, found);
  l.history.push({ step, at: new Date().toISOString(), ...found });
  saveLedger(l);
  console.log(`\n  recorded in ${LEDGER_FILE.replace(ROOT + "\\", "").replace(ROOT + "/", "")}: ${JSON.stringify(found)}`);
}

function scriptArgs(script, url, l, sig) {
  const a = ["script", `script/${script}.s.sol:${script}`, "--rpc-url", url, "--slow"];
  if (sig) a.push("--sig", sig);
  if (SEND) a.push("--broadcast", ...signerArgs(l));
  else a.push("--sender", l.deployer);
  return a;
}

async function main() {
  const l = loadLedger();
  if (!l.deployer && !flag("unlocked")) die(`no deployer known for network ${NETWORK}`);

  if (cmd === "status") {
    const url = rpcUrl();
    const [bal, nonce] = await Promise.all([rpc(url, "eth_getBalance", [l.deployer, "latest"]), rpc(url, "eth_getTransactionCount", [l.deployer, "latest"])]);
    console.log(`\n  network ${NETWORK}   deployer ${l.deployer}   balance ${eth(bal)} ETH   nonce ${parseInt(nonce, 16)}`);
    console.log(`  recorded: ${JSON.stringify(l.contracts, null, 2)}\n`);
    return;
  }

  if (cmd === "preview") {
    const url = rpcUrl();
    const env = { PIECE_CONFIG: CONFIG_PATH };
    if (opt("tokens")) env.PREVIEW_TOKENS = opt("tokens");
    forge(["script", "script/PreviewPiece.s.sol:PreviewPiece", "--sig", "preview()", "--fork-url", url], env);
    console.log(`\n  open ${join(ROOT, "preview", "index.html")}\n`);
    return;
  }

  if (cmd === "player") {
    const url = rpcUrl();
    if (l.contracts.PiecePlayer && SEND && !flag("again")) die(`a PiecePlayer is already recorded (${l.contracts.PiecePlayer}); pass --again to deploy another`);
    // A second player reuses the recorded store, so the wasm is not stored again.
    const env = l.contracts.BlobStore ? { BLOB_STORE: l.contracts.BlobStore } : {};
    if (env.BLOB_STORE) console.log(`
  reusing BlobStore ${env.BLOB_STORE}: bytes it already holds are skipped`);
    await confirm("player", l, url);
    const out = forge(scriptArgs("DeployPlayer", url, l), env);
    record(l, "player", { BlobStore: logged(out, "BlobStore"), PieceArtifact: logged(out, "PieceArtifact"), PiecePlayer: logged(out, "PiecePlayer") });
    if (SEND && l.contracts.KohiPiece) console.log("  the piece still uses its current player until you run: node tools/deploy.mjs use-player --send");
    return;
  }

  if (cmd === "piece") {
    const url = rpcUrl();
    const player = opt("player", l.contracts.PiecePlayer);
    if (!player) die("no PiecePlayer recorded: run the player step first (or pass --player <address>)");
    if (l.contracts.KohiPiece && SEND && !flag("again")) die(`a piece is already recorded (${l.contracts.KohiPiece}); pass --again to deploy another`);
    const config = JSON.parse(readFileSync(join(ROOT, CONFIG_PATH), "utf8"));
    console.log(`\n  piece ${config.name} (${config.symbol}), ${config.maxSupply} tokens, player ${player}`);
    console.log(`  mint: ${config.mintTo.map((a, i) => `${config.mintCount[i]} to ${a}`).join(", ")}; royalty ${config.royaltyBps / 100}% to ${config.royaltyReceiver}`);
    await confirm("piece", l, url);
    const tmp = join(dirname(CONFIG_PATH), ".deploy-piece.json");
    writeFileSync(join(ROOT, tmp), JSON.stringify({ ...config, player }, null, 2));
    let out;
    try { out = forge(scriptArgs("DeployPiece", url, l), { PIECE_CONFIG: tmp }); }
    finally { rmSync(join(ROOT, tmp), { force: true }); }
    record(l, "piece", { KohiPiece: logged(out, "KohiPiece"), PiecePlayer: player });
    return;
  }

  if (cmd === "use-player") {
    const url = rpcUrl();
    const piece = opt("piece", l.contracts.KohiPiece);
    const player = opt("player", flag("image") ? (flag("v3") ? l.contracts.ImagePlayerV3 : flag("v2") ? l.contracts.ImagePlayerV2 : l.contracts.ImagePlayer) : l.contracts.PiecePlayer);
    if (!piece || !player) die("need a recorded piece and player (or --piece and --player)");
    const current = await rpc(url, "eth_call", [{ to: piece, data: "0x4defe028" }, "latest"]).catch(() => null);
    const locked = await rpc(url, "eth_call", [{ to: piece, data: "0xac998f45" }, "latest"]).catch(() => null);
    if (locked && BigInt(locked) === 1n) die("the piece's tokenURI is locked; its player can no longer change");
    console.log(`
  piece ${piece}
  tokenURI module now ${current ? "0x" + current.slice(26) : "(unknown)"}  ->  ${player}`);
    await confirm("use-player", l, url);
    const args = ["send", piece, "setTokenURIModule(address)", player, "--rpc-url", url];
    if (!SEND) { console.log(`  dry run: would send setTokenURIModule(${player}) from ${l.deployer}\n`); return; }
    args.push(...(flag("unlocked") ? ["--unlocked", "--from", l.deployer] : ["--ledger", "--mnemonic-derivation-path", deployerPath(), "--from", l.deployer]));
    const r = spawnSync("cast", args, { cwd: ROOT, encoding: "utf8", stdio: ["inherit", "pipe", "pipe"] });
    process.stdout.write(r.stdout ?? ""); process.stderr.write(r.stderr ?? "");
    if (r.status !== 0) die(`cast exited with status ${r.status}`);
    l.history.push({ step: "use-player", at: new Date().toISOString(), KohiPiece: piece, PiecePlayer: player });
    saveLedger(l);
    console.log(`
  the piece now serves its tokenURI from ${player}`);
    return;
  }

  if (cmd === "image-player") {
    const url = rpcUrl();
    const v3 = flag("v3");
    const v2 = !v3 && flag("v2");
    const name = v3 ? "PiecePlayerV3" : v2 ? "PiecePlayerV2" : "PiecePlayer";
    // V2 and V3 build a new artifact from the current template unless --artifact is given.
    const artifact = v2 || v3 ? opt("artifact", null) : opt("artifact", l.contracts.PieceArtifact);
    if (!artifact && !v2 && !v3) die("no PieceArtifact recorded: run the player step first (or pass --artifact)");
    if (!artifact && !l.contracts.BlobStore) die("no BlobStore recorded: run the player step first");
    const pins = existsSync(join(ROOT, "deploy", "pins.json")) ? JSON.parse(readFileSync(join(ROOT, "deploy", "pins.json"), "utf8")) : {};
    const base = opt("image-base", pins[opt("pin", "rakel-works")]?.base);
    if (!base) die("no image base: pin the works first (node tools/pin.mjs --dir <pngs> --name rakel-works --send) or pass --image-base ipfs://<cid>/");
    console.log(`
  image ${name} on ${artifact ? "artifact " + artifact : "a new artifact from the current template" + (v3 ? " and the raw DEFLATE wasm" : "") + " on BlobStore " + l.contracts.BlobStore}; token images at ${base}<id>.png`);
    await confirm("image-player", l, url);
    const env = { IMAGE_BASE: base, PLAYER_V2: v2 ? "true" : "false", PLAYER_V3: v3 ? "true" : "false" };
    if (artifact) env.PIECE_ARTIFACT = artifact;
    else env.BLOB_STORE = l.contracts.BlobStore;
    const out = forge(scriptArgs("DeployPlayer", url, l), env);
    if (v3) record(l, "image-player-v3", { ...(artifact ? {} : { ArtifactV3: logged(out, "PieceArtifact") }), ImagePlayerV3: logged(out, "PiecePlayerV3") });
    else if (v2) record(l, "image-player-v2", { ...(artifact ? {} : { ArtifactV2: logged(out, "PieceArtifact") }), ImagePlayerV2: logged(out, "PiecePlayerV2") });
    else record(l, "image-player", { ImagePlayer: logged(out, "PiecePlayer") });
    if (SEND) console.log(`  ready; the piece keeps its current player until: node tools/deploy.mjs use-player --image${v3 ? " --v3" : v2 ? " --v2" : ""} --send`);
    return;
  }

  if (cmd === "contract-uri") {
    const url = rpcUrl();
    const piece = opt("piece", l.contracts.KohiPiece);
    if (!piece) die("no piece recorded (or pass --piece)");
    const config = JSON.parse(readFileSync(join(ROOT, CONFIG_PATH), "utf8"));
    const pins = existsSync(join(ROOT, "deploy", "pins.json")) ? JSON.parse(readFileSync(join(ROOT, "deploy", "pins.json"), "utf8")) : {};
    const art = pins[opt("pin", "rakel-collection")]?.base;
    const meta = { name: config.name, symbol: config.symbol, description: config.description };
    if (art) Object.assign(meta, { image: art + "logo.jpg", banner_image: art + "banner.jpg", featured_image: art + "featured.jpg" });
    if (opt("link")) meta.external_link = opt("link");
    const uri = "data:application/json;base64," + Buffer.from(JSON.stringify(meta)).toString("base64");
    console.log(`\n  contractURI for ${piece}:\n  ${JSON.stringify(meta, null, 2).replace(/\n/g, "\n  ")}`);
    if (!art) console.log("  (no pinned collection images found: text only. Pin them as rakel-collection to include them.)");
    await confirm("contract-uri", l, url);
    if (!SEND) { console.log(`  dry run: would send setContractURI(<${uri.length} chars>) from ${l.deployer}
`); return; }
    const args = ["send", piece, "setContractURI(string)", uri, "--rpc-url", url,
      ...(flag("unlocked") ? ["--unlocked", "--from", l.deployer] : ["--ledger", "--mnemonic-derivation-path", deployerPath(), "--from", l.deployer])];
    const r = spawnSync("cast", args, { cwd: ROOT, encoding: "utf8", stdio: ["inherit", "pipe", "pipe"] });
    process.stdout.write(r.stdout ?? ""); process.stderr.write(r.stderr ?? "");
    if (r.status !== 0) die(`cast exited with status ${r.status}`);
    l.history.push({ step: "contract-uri", at: new Date().toISOString(), meta });
    saveLedger(l);
    console.log("\n  collection metadata updated (marketplaces are told through ContractURIUpdated)");
    return;
  }

  if (cmd === "attribute") {
    const url = rpcUrl();
    const piece = opt("piece", l.contracts.KohiPiece);
    if (!piece) die("no piece recorded (or pass --piece)");
    const config = JSON.parse(readFileSync(join(ROOT, CONFIG_PATH), "utf8"));
    const creator = opt("creator", config.creator);
    const signature = opt("signature");
    if (!/^0x[0-9a-fA-F]{40}$/.test(creator ?? "")) die("pass --creator 0x... (or set \"creator\" in the piece config)");
    if (!/^0x[0-9a-fA-F]{130}$/.test(signature ?? "")) die("pass --signature 0x... (65 bytes, from cast wallet sign --data)");
    // creator() must still be zero.
    const current = await rpc(url, "eth_call", [{ to: piece, data: "0x02d05d3f" }, "latest"]);
    if (BigInt(current) !== 0n) die(`already attributed to 0x${current.slice(26)}`);
    // Simulate attributeCreator(creator, signature) from the owner: it reverts unless the signature verifies.
    const data = await (async () => {
      const r = spawnSync("cast", ["calldata", "attributeCreator(address,bytes)", creator, signature], { encoding: "utf8" });
      if (r.status !== 0) die(`cast calldata failed: ${r.stderr}`);
      return r.stdout.trim();
    })();
    try {
      await rpc(url, "eth_call", [{ from: l.deployer, to: piece, data }, "latest"]);
    } catch (e) {
      die(`simulation reverts, nothing sent: ${e.message} (wrong signer, wrong typed data, or not the owner)`);
    }
    console.log(`\n  piece ${piece}\n  creator ${creator}\n  signature verified by simulation from the owner ${l.deployer}`);
    await confirm("attribute", l, url);
    if (!SEND) { console.log("  dry run: nothing sent (add --send to record the attribution)\n"); return; }
    const args = ["send", piece, "attributeCreator(address,bytes)", creator, signature, "--rpc-url", url,
      ...(flag("unlocked") ? ["--unlocked", "--from", l.deployer] : ["--ledger", "--mnemonic-derivation-path", deployerPath(), "--from", l.deployer])];
    const r = spawnSync("cast", args, { cwd: ROOT, encoding: "utf8", stdio: ["inherit", "pipe", "pipe"] });
    process.stdout.write(r.stdout ?? ""); process.stderr.write(r.stderr ?? "");
    if (r.status !== 0) die(`cast exited with status ${r.status}`);
    l.history.push({ step: "attribute", at: new Date().toISOString(), KohiPiece: piece, creator, signature });
    saveLedger(l);
    console.log(`\n  attributed: creator() is now ${creator}`);
    return;
  }

  if (cmd === "verify-args") {
    // Source verification needs each contract's exact constructor arguments.
    // Read them from the real creation transaction on chain: its input is the
    // creation code followed by the ABI-encoded arguments. Writes nothing to
    // the chain and verifies nothing.
    const url = rpcUrl();
    const ALIAS = { ImagePlayer: "PiecePlayer", ImagePlayerV2: "PiecePlayerV2", ArtifactV2: "PieceArtifact", ImagePlayerV3: "PiecePlayerV3", ArtifactV3: "PieceArtifact" };
    const { readdirSync } = await import("node:fs");
    const runs = [];
    for (const d of readdirSync(join(ROOT, "broadcast"), { withFileTypes: true })) {
      const dir = join(ROOT, "broadcast", d.name, String(DEFAULTS[NETWORK]?.chainId ?? 1));
      if (!d.isDirectory() || !existsSync(dir)) continue;
      for (const f of readdirSync(dir)) if (/^run-\d+\.json$/.test(f)) runs.push(JSON.parse(readFileSync(join(dir, f), "utf8")));
    }
    l.verify = l.verify ?? {};
    for (const [key, address] of Object.entries(l.contracts)) {
      const contract = ALIAS[key] ?? key;
      const art = JSON.parse(readFileSync(join(ROOT, "out", `${contract}.sol`, `${contract}.json`), "utf8"));
      const creation = art.bytecode.object.replace(/^0x/, "").toLowerCase();
      // Candidate transactions from the broadcast records, kept only if mainnet agrees.
      const hashes = [...new Set(runs.flatMap((r) => (r.receipts ?? []).filter((x) => x.contractAddress?.toLowerCase() === address.toLowerCase()).map((x) => x.transactionHash)))];
      let found = null;
      for (const h of hashes) {
        const rc = await rpc(url, "eth_getTransactionReceipt", [h]).catch(() => null);
        if (!rc || rc.contractAddress?.toLowerCase() !== address.toLowerCase() || rc.status !== "0x1") continue;
        const tx = await rpc(url, "eth_getTransactionByHash", [h]);
        const input = tx.input.replace(/^0x/, "").toLowerCase();
        if (!input.startsWith(creation)) die(`${key}: the creation transaction ${h} does not start with the ${contract} creation code`);
        found = { contract, address, txHash: h, block: parseInt(rc.blockNumber, 16), constructorArgs: "0x" + input.slice(creation.length) };
        break;
      }
      if (!found) die(`${key} ${address}: no successful creation transaction on ${NETWORK} in the broadcast records`);
      l.verify[key] = found;
      console.log(`  ${key.padEnd(14)} ${contract.padEnd(14)} ${address}  tx ${found.txHash.slice(0, 12)}...  constructor args ${(found.constructorArgs.length - 2) / 2} bytes`);
    }
    saveLedger(l);
    console.log(`\n  recorded under "verify" in ${LEDGER_FILE.replace(ROOT, "").replace(/^[\\/]/, "")}\n`);
    return;
  }

  if (cmd === "approve") {
    const url = rpcUrl();
    const piece = opt("piece", l.contracts.KohiPiece);
    const sale = opt("sale", l.contracts.HolderSale);
    if (!piece || !sale) die("need a recorded piece and sale (or --piece and --sale)");
    const config = JSON.parse(readFileSync(join(ROOT, CONFIG_PATH), "utf8"));
    const seller = config.saleSeller;
    const sellerHd = flag("unlocked") ? "(fork)" : sellerPath();
    const on = !flag("revoke");
    const call = (to, sig, ...args) => {
      const r = spawnSync("cast", ["call", to, sig, ...args, "--rpc-url", url], { encoding: "utf8" });
      if (r.status !== 0) die(`cast call failed: ${r.stderr}`);
      return r.stdout.trim();
    };
    // The approval exposes every token the seller holds to this contract: check it is the audited code.
    const code = spawnSync("cast", ["code", sale, "--rpc-url", url], { encoding: "utf8" }).stdout.trim();
    const hash = spawnSync("cast", ["keccak", code], { encoding: "utf8" }).stdout.trim();
    const expected = opt("expect-code-hash", l.saleCodeHash ?? "0xfde1108af00d1b41d0553673bac4b1dd6bf39b57c0019fb36e50ddd720e59886");
    if (hash.toLowerCase() !== expected.toLowerCase()) die(`the sale's runtime code hash is ${hash}, not the audited ${expected}; not approving`);
    const salePiece = call(sale, "piece()(address)"), saleSeller = call(sale, "seller()(address)");
    if (salePiece.toLowerCase() !== piece.toLowerCase() || saleSeller.toLowerCase() !== seller.toLowerCase()) die(`the sale is for piece ${salePiece} and seller ${saleSeller}, not ${piece} and ${seller}`);
    const before = call(piece, "isApprovedForAll(address,address)(bool)", seller, sale);
    console.log(`\n  ${on ? "approve" : "revoke"}: seller ${seller} -> sale ${sale} on piece ${piece}`);
    console.log(`  sale code hash ${hash} (audited); currently approved: ${before}`);
    console.log(`  signs with the seller's Ledger path ${sellerHd}`);
    if ((before === "true") === on) { console.log(`  nothing to do: already ${on ? "approved" : "revoked"}\n`); return; }
    if (!SEND) { console.log(`  dry run: nothing sent (add --send)\n`); return; }
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const step = on ? "approve" : "revoke";
    const typed = (await rl.question(`  This sends a real transaction from the seller. Type "${step}" to continue: `)).trim();
    rl.close();
    if (typed !== step) die("not confirmed; nothing sent");
    const args = ["send", piece, "setApprovalForAll(address,bool)", sale, on ? "true" : "false", "--rpc-url", url,
      ...(flag("unlocked") ? ["--unlocked", "--from", seller] : ["--ledger", "--mnemonic-derivation-path", sellerHd, "--from", seller])];
    const r = spawnSync("cast", args, { cwd: ROOT, encoding: "utf8", stdio: ["inherit", "pipe", "pipe"] });
    process.stdout.write(r.stdout ?? ""); process.stderr.write(r.stderr ?? "");
    if (r.status !== 0) die(`cast exited with status ${r.status}`);
    const after = call(piece, "isApprovedForAll(address,address)(bool)", seller, sale);
    l.history.push({ step, at: new Date().toISOString(), KohiPiece: piece, HolderSale: sale, approved: after === "true" });
    saveLedger(l);
    console.log(`\n  isApprovedForAll(seller, sale) is now ${after}`);
    return;
  }

  if (cmd === "sale") {
    const url = rpcUrl();
    const piece = opt("piece", l.contracts.KohiPiece);
    if (!piece) die("no piece recorded: run the piece step first (or pass --piece <address>)");
    if (l.contracts.HolderSale && SEND && !flag("again")) die(`a sale is already recorded (${l.contracts.HolderSale}); pass --again to deploy another`);
    const config = JSON.parse(readFileSync(join(ROOT, CONFIG_PATH), "utf8"));
    console.log(`\n  sale for ${piece}: seller ${config.saleSeller}, ${Number(BigInt(config.salePrice)) / 1e18} ETH, opens ${new Date(config.saleStart * 1000).toISOString()}`);
    await confirm("sale", l, url);
    const out = forge(scriptArgs("DeploySale", url, l), { PIECE_CONFIG: CONFIG_PATH, PIECE: piece });
    record(l, "sale", { HolderSale: logged(out, "HolderSale") });
    if (SEND) console.log(`  next: the seller approves it on the piece: setApprovalForAll(${logged(out, "HolderSale")}, true)`);
    return;
  }

  console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(5, 24).map((s) => s.replace(/^\/\/ ?/, "")).join("\n"));
}

main().catch((e) => { console.error(`\n  ${e.message ?? String(e)}\n`); process.exitCode = 1; });
