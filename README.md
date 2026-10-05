# kohi-player

Generative artworks stored on Ethereum as programs, with a tokenURI that
renders them in the browser from on-chain bytes.

A **KohiPiece** is an ERC-721 collection whose artwork is one program for the
KVM, a bytecode virtual machine for generative art, plus one seed per token.
The program and seeds live in the contract. The live Kohi engine on mainnet
renders any token in a view call, and the **PiecePlayer** returns a tokenURI
whose `animation_url` is a self-contained page that renders the same pixels in
the browser, with no server.

## Contracts (`src/`)

| Contract | What it does |
|---|---|
| `player/KohiPiece.sol` | The collection: program, params, traits, description (frozen by `lockArt`); artist-chosen seeds (frozen by `lockSeeds`); minting only after both locks; a replaceable, lockable tokenURI module; ERC-2981, ERC-4906, ERC-7572 `contractURI`, ERC-7015 creator attribution. |
| `player/PiecePlayer.sol` | The tokenURI module: the JSON and the player page, from one `PieceArtifact`. Optionally an `image` field from an image base URI. No owner, no storage beyond its constructor arguments. |
| `player/PiecePlayerV2.sol` | The same page as `PiecePlayer`, in a `data:application/json;base64,` document whose `animation_url` is the page as `data:text/html,` text. Some consumers (Rarible, ownable.art) do not decode that `animation_url`, so Rakel does not use it. |
| `player/PiecePlayerV3.sol` | The same page in a `data:application/json;base64,` document whose `animation_url` is `data:text/html;base64,`. Every byte after each prefix is a base64 character, so the tokenURI holds nothing to escape. Paired with an artifact that stores the two wasm modules compressed with raw DEFLATE (the page decompresses them), a Rakel tokenURI is about 350 KB and 30.3M gas, under the 50M of a default geth `eth_call`. |
| `player/PieceArtifact.sol` | One immutable version of the page: 7 HTML template segments and two wasm blobs, the render core and the LGPL noise module it imports. |
| `player/HolderSale.sol` | A walk-up sale of tokens the seller still holds, for current holders of a list of collections (directly or through a delegate.xyz v2 delegation). Each holder token buys once and each buying wallet buys once. The seller approves it once and signs nothing per sale. |
| `BlobStore.sol` | Content-addressed SSTORE2 storage for the page and the wasm. |

## Deployed contracts

Each link opens the contract on Etherscan. Rakel serves its tokenURI from
`PiecePlayerV3` (with image base). Every contract below has verified source
on Etherscan. The V3 artifact has the same code as the first
`PieceArtifact`, so Etherscan shows it as a similar match of it. An earlier
V3 pair, built before the page declared `color-scheme`, is also deployed and
not in use: player `0xd12F45B49191efd55a7FCEA819434f29F3815603` and artifact
`0x3D697e39fc7770419F2e173d1bd183cB733a071C`. Etherscan shows both as
similar matches.

| Contract | Mainnet |
|---|---|
| `KohiPiece` (Rakel) | [`0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18`](https://etherscan.io/address/0xe56522Ebaf8E19c7E2B9468Cbef8aF14773F5F18#code) |
| `HolderSale` (Rakel) | [`0x4eF9B15bf8525f8ad619Bd3d963Dd5ACe09f5b07`](https://etherscan.io/address/0x4eF9B15bf8525f8ad619Bd3d963Dd5ACe09f5b07#code) |
| `PiecePlayer` | [`0x178B2419627e4319e2383Ed7802d26eBDa206Cb3`](https://etherscan.io/address/0x178B2419627e4319e2383Ed7802d26eBDa206Cb3#code) |
| `PiecePlayer` (with image base) | [`0x5B01D7BD6f13506da108A5224d3D3Ff1DF80685B`](https://etherscan.io/address/0x5B01D7BD6f13506da108A5224d3D3Ff1DF80685B#code) |
| `PieceArtifact` | [`0x089C7092C284dE7068Ea322b0F9a293148796B32`](https://etherscan.io/address/0x089C7092C284dE7068Ea322b0F9a293148796B32#code) |
| `PiecePlayerV3` (with image base) | [`0x5cf3D9EcDB7501899692c8F4273E2Ea4D1338624`](https://etherscan.io/address/0x5cf3D9EcDB7501899692c8F4273E2Ea4D1338624#code) |
| `PieceArtifact` (V3 page, DEFLATE wasm) | [`0xB0e19C43673c281f594CBcDA85b9Ac3f199F9D64`](https://etherscan.io/address/0xB0e19C43673c281f594CBcDA85b9Ac3f199F9D64#code) |
| `BlobStore` | [`0x3f89D4cc734f90BE2dAd9d8A2e92681761607192`](https://etherscan.io/address/0x3f89D4cc734f90BE2dAd9d8A2e92681761607192#code) |

Rakel on OpenSea: [opensea.io/collection/rakel-art](https://opensea.io/collection/rakel-art).

## Build and test

```bash
forge build
MAINNET_RPC_URL=<url> forge test   # some suites run on a mainnet fork, against the live engine
```

Compiler settings are pinned in `foundry.toml` (solc 0.8.37, Cancun,
optimizer 200, no bytecode metadata), so the deployed code depends only on the
source.

## Deploy

The CLI runs the steps in order and remembers what it deployed (in
`deploy/<network>.json`). It reads `MAINNET_RPC_URL` from the environment,
or `./.env`. Every step is a dry run unless you add `--send`,
which asks you to type the step name, then signs on the Ledger. The Ledger
derivation paths stay local: set `DEPLOYER_HD_PATH` (and, for the seller's
approval, `SELLER_HD_PATH`) in `./.env`, or pass `--hd-path` / `--seller-path`.

```bash
node tools/deploy.mjs status                     # balances, nonce, recorded addresses
node tools/deploy.mjs preview                    # preview/index.html: real tokenURIs, simulated on a fork
node tools/deploy.mjs player --send              # 1. the shared PiecePlayer
node tools/deploy.mjs piece  --send              # 2. the piece, using the recorded player
node tools/deploy.mjs sale   --send              # 3. its HolderSale, when you are ready
```

To change the page around the work (background, loading note, layout) without
touching anything else: edit the page template, preview it, deploy a new player
on the recorded store (only the changed template segments are stored, about
3.5M gas), then point the piece at it. This works until `lockTokenURI`.

```bash
node tools/deploy.mjs player --again --send      # new artifact and player; the wasm is reused
node tools/deploy.mjs use-player --send          # setTokenURIModule(new player) on the piece
```

To serve the page from a `PiecePlayerV3` with the pinned token images: this
builds a new artifact on the recorded store from the current page template and
the raw DEFLATE wasm modules (`assets/*.deflate.hex`; only bytes the store does
not hold are stored), deploys the player on it, and records both
(`ArtifactV3`, `ImagePlayerV3`). Pass `--artifact <addr>` to reuse an artifact
instead. Preview the page in marketplace-like frames first with
`script/PreviewFrame.s.sol`, and check it against the live piece on a fork with
`test/PiecePlayerV3Fork.t.sol`.

```bash
node tools/deploy.mjs image-player --v3 --send   # deploy and record ArtifactV3 + ImagePlayerV3
node tools/deploy.mjs use-player --image --v3 --send
```

`--v2` does the same for `PiecePlayerV2` on the uncompressed modules.

The page has a transparent background and scales the work to fit its frame,
so a marketplace frame of any size or shape shows the work with the
marketplace's own background around it.

The same steps with forge directly:

```bash
# The player, once per chain. Every piece can share it.
forge script script/DeployPlayer.s.sol:DeployPlayer --rpc-url <url> --broadcast

# One piece, from its config (set "player" to the PiecePlayer above).
PIECE_CONFIG=pieces/<piece>/piece.json \
  forge script script/DeployPiece.s.sol:DeployPiece --rpc-url <url> --broadcast --slow

# Its sale, when you are ready (optional).
PIECE_CONFIG=pieces/<piece>/piece.json PIECE=<piece address> \
  forge script script/DeploySale.s.sol:DeploySale --rpc-url <url> --broadcast
```

A plain `forge script` only simulates. `DeployPiece` reads the config
(`pieces/rakel/piece.json` is a complete example): name, symbol, supply,
family, program, params, trait manifest, seeds, description, mint split and
royalty. With `"player"` set to the zero address it deploys a player too.
`DeploySale` reads the sale keys of the same config.

After the deploy:

1. **Creator attribution (ERC-7015).** `npx tsx tools/attribution.ts --piece
   <address> --creator <address> --rpc <url>` writes the typed data and prints
   the sign and send commands.
2. **Sale.** The seller calls `setApprovalForAll(<HolderSale>, true)` on the
   piece. Revoking it stops the sale.
3. **Image fallback, if a marketplace shows a blank tile.** Render one PNG per
   token, upload them, deploy a player with an image base on the same artifact
   (`PIECE_ARTIFACT=<artifact> IMAGE_BASE=ipfs://<cid>/ forge script
   script/DeployPlayer.s.sol:DeployPlayer ...`), and set it as the tokenURI
   module.
4. **Locks.** When the metadata is final: `lockTokenURI()` and
   `lockContractURI()`.

## Rakel

`pieces/rakel/` is Rakel by wattsy: 64 works, family 3 (stamps). Tokens 1 to
15 go to wattsy.eth, 16 to 64 to the sale address. The sale opens on
2026-10-08 at 11:44:42 UTC, five years after the first Kintsugi mint, for
holders of Kintsugi, City Lights and The Universe Machine, at 0.05 ETH, one per
wallet; each Kohi piece can be used once. See it on
[OpenSea](https://opensea.io/collection/rakel-art).

## Licensing

Mixed: see [`LICENSING.md`](LICENSING.md). The SPDX header in each file
governs.
