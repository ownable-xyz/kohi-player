#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) wattsy. Licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0).
//
// pin.mjs: pin a directory of files to IPFS through Pinata, as one directory CID.
//
//   node tools/pin.mjs --dir <path> --name <label>            dry run: lists what would be pinned
//   node tools/pin.mjs --dir <path> --name <label> --send     uploads (asks you to type the label)
//
// The files are reachable afterwards as ipfs://<cid>/<file name>. Pinning
// publishes them: anyone with the CID can fetch them, forever. The CID is
// recorded in deploy/pins.json.
//
// Credentials come from the environment or ./.env, and are
// never printed: PINATA_JWT or PINATA_JWT_SECRET, or PINATA_API_KEY and PINATA_API_SECRET.

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, mkdirSync } from "node:fs";
import { join, dirname, resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline/promises";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);
function die(msg) { console.error(`\n  ${msg}\n`); process.exit(1); }

function envFromFile(path, key) {
  if (!existsSync(path)) return undefined;
  const m = new RegExp(`^\\s*${key}\\s*=\\s*"?([^"\\r\\n]+)"?`, "m").exec(readFileSync(path, "utf8"));
  return m ? m[1].trim() : undefined;
}

const dir = opt("dir");
const name = opt("name");
if (!dir || !name) die("usage: node tools/pin.mjs --dir <path> --name <label> [--send]");
const abs = resolve(process.cwd(), dir);
const files = readdirSync(abs).filter((f) => statSync(join(abs, f)).isFile() && !f.startsWith(".")).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
if (files.length === 0) die(`no files in ${abs}`);
const total = files.reduce((n, f) => n + statSync(join(abs, f)).size, 0);
console.log(`\n  ${files.length} files from ${abs}, ${(total / 1048576).toFixed(1)} MB, as "${name}"`);
console.log(`  ${files.slice(0, 6).join(", ")}${files.length > 6 ? `, ... ${files[files.length - 1]}` : ""}`);

const env = (k) => process.env[k] ?? envFromFile(join(ROOT, ".env"), k);
function authHeaders() {
  const jwt = flag("keys") ? undefined : env("PINATA_JWT") ?? env("PINATA_JWT_SECRET");
  if (jwt) return { Authorization: `Bearer ${jwt}` };
  const key = env("PINATA_API_KEY"), secret = env("PINATA_API_SECRET");
  if (key && secret) return { pinata_api_key: key, pinata_secret_api_key: secret };
  die("no Pinata credentials: set PINATA_JWT (or PINATA_JWT_SECRET), or PINATA_API_KEY and PINATA_API_SECRET");
}

if (flag("check")) {
  const r = await fetch("https://api.pinata.cloud/data/testAuthentication", { headers: authHeaders() });
  console.log(`  Pinata credentials: ${r.ok ? "accepted" : `refused (HTTP ${r.status})`}\n`);
  await new Promise((done) => setTimeout(done, 100));
  process.exit(r.ok ? 0 : 1);
}

if (!flag("send")) {
  console.log("  dry run: nothing uploaded (add --send to pin, or --check to test the credentials)\n");
  process.exit(0);
}

const rl = createInterface({ input: process.stdin, output: process.stdout });
const typed = (await rl.question(`  Pinning publishes these files permanently. Type "${name}" to continue: `)).trim();
rl.close();
if (typed !== name) die("not confirmed; nothing uploaded");

// One multipart request; each part's filename is "<label>/<file>", which
// Pinata turns into one directory with the files inside it.
const form = new FormData();
for (const f of files) {
  form.append("file", new Blob([readFileSync(join(abs, f))]), `${name}/${f}`);
}
form.append("pinataMetadata", JSON.stringify({ name }));
form.append("pinataOptions", JSON.stringify({ cidVersion: 1 }));

const res = await fetch("https://api.pinata.cloud/pinning/pinFileToIPFS", {
  method: "POST",
  headers: authHeaders(),
  body: form,
});
const body = await res.json().catch(() => ({}));
if (!res.ok || !body.IpfsHash) die(`Pinata refused: HTTP ${res.status} ${JSON.stringify(body).slice(0, 300)}`);

const cid = body.IpfsHash;
const pinsFile = join(ROOT, "deploy", "pins.json");
mkdirSync(dirname(pinsFile), { recursive: true });
const pins = existsSync(pinsFile) ? JSON.parse(readFileSync(pinsFile, "utf8")) : {};
pins[name] = { cid, base: `ipfs://${cid}/`, files: files.length, bytes: total, from: basename(abs), at: new Date().toISOString() };
writeFileSync(pinsFile, JSON.stringify(pins, null, 2) + "\n");
console.log(`\n  pinned: ipfs://${cid}/  (${files.length} files)  recorded in deploy/pins.json`);
console.log(`  check one: https://gateway.pinata.cloud/ipfs/${cid}/${files[0]}\n`);
