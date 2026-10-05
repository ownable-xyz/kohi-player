# Solady (vendored, unmodified)

Source: https://github.com/Vectorized/solady, tag **v0.1.26**. MIT.

Only the files the contracts import are vendored, byte-identical to the tag:

| File | Used by |
|---|---|
| `src/tokens/ERC721.sol` | `KohiPiece` |
| `src/tokens/ERC2981.sol` | `KohiPiece` (royalties) |
| `src/utils/EIP712.sol` | `KohiPiece` (ERC-7015 typed data, ERC-5267) |
| `src/utils/ECDSA.sol` | `KohiPiece` (ERC-7015 signature by a key) |
| `src/utils/SignatureCheckerLib.sol` | `KohiPiece` (ERC-7015 signature by an ERC-1271 account) |

Never edit these files. To update, fetch them from a newer tag and update this note.
