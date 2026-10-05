# Licensing

This repository is mixed-license, so there is deliberately no bare `LICENSE`
at the root. **The `SPDX-License-Identifier` header in each file governs.**
This document summarizes those headers; where they disagree, the header wins.

## Apache-2.0

Full text: [`LICENSE-APACHE`](LICENSE-APACHE).

Everything under `src/`, `script/`, `test/` and `tools/` except the MIT files
listed below. The Apache grant is reproduced inline in each contract, because
a block explorer publishes the `.sol` file without a companion `LICENSE`.

`assets/player-wasm.hex` is the wasm build of the Kohi render core
(Apache-2.0).

## MIT

- `src/SSTORE2.sol`: adapted from Solady, with attribution in the file
- `src/StreamStore.sol`, `src/RegistryOwnable.sol`
- `lib/solady/` (Solady v0.1.26) and `lib/openzeppelin/` (OpenZeppelin
  Contracts v5.6.1): vendored, unmodified subsets; see each `PROVENANCE.md`
- `lib/forge-std/`: test and script support, MIT or Apache-2.0 (its own
  license files)

## LGPL-2.1-only

`assets/player-noise-wasm.hex` is the noise module the player page carries
beside the render core. It derives from the noise function of p5.js and is
licensed under the GNU Lesser General Public License 2.1
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Its source is
public at https://github.com/ownable-xyz/kohi-noise-lgpl (`rust/`). The render
core imports it when the page loads; it is never compiled into the render
core, and a viewer can replace it in the page.

## Trademarks

Apache-2.0 section 6 grants no trademark rights. The code is open; the names
Kohi and Ownable are not.
