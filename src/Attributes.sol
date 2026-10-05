// SPDX-License-Identifier: Apache-2.0
/* Copyright (c) wattsy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. */
pragma solidity ^0.8.13;

/* =============================================================================
 *  ATTRIBUTES · a token's traits, derived from its draw stream
 * =============================================================================
 *
 * Attributes computes the `attributes` array of a token's tokenURI. It is the
 * default path for a piece that supplies no attributes logic. It works in
 * two steps:
 *
 *  1. extractTraits reads a canonical draw-instruction stream (the stream
 *     format the renderer consumes). It collects the payload of each trait
 *     record: a one-byte trait id and an 8-byte signed integer value (9 bytes
 *     in total). It skips every other record by its exact byte width, so a
 *     trait-record marker byte inside coordinate data is never read as a
 *     trait. The scanner depends only on this record format, not on how the
 *     stream was produced.
 *  2. toJson maps the extracted records through the trait metadata of the
 *     piece into the `attributes` array of the tokenURI:
 *     `[{"trait_type":"...","value":...}, ...]`.
 *
 * VALUE FORMAT. Every trait value is a Q31.32 fixed-point number (a "Fix64"):
 * the real number x is stored as the integer x * 2^32. A whole-number trait,
 * such as an index into a small set of options, is an exact multiple of 2^32.
 * A fractional trait, such as a lightness or hue in [0, 1), keeps bits below
 * that point. A numeric trait (kind number or value) renders `value` as a
 * signed decimal, unquoted, as its `decimals` field says:
 *   - `decimals == 0` (the default): the output is the integer part only,
 *     from the arithmetic right shift `value >> 32` (it floors toward
 *     negative infinity). This matches the conversion in the off-chain
 *     renderer exactly.
 *   - `decimals == N > 0`: the output has N fractional digits, from
 *     `_fixedDecimal`. It rounds half-up on the last kept digit (with integer
 *     carry), signs the result as sign-and-magnitude, and suppresses a
 *     negative zero such as `-0.000`. Use it for traits that are fractional,
 *     for example the lightness, chroma or hue of a color, or a knob in
 *     [0, 1). The off-chain renderer has an equivalent routine, and tests
 *     verify that the two agree over a broad range of values. `N` should
 *     stay in [1, 6], the range of fractional digits that a Q31.32 value
 *     shows without rounding artifacts. This contract does not enforce that
 *     range. It is a rule for the trait metadata. (The name and label
 *     safety described below is enforced where traits are added.)
 *   - kind choice or flag: the value selects a label, `labels[value >> 32]`,
 *     quoted as a JSON string. If the index is out of range or negative, the
 *     output is the numeric rendering above.
 *
 * NAME AND LABEL SAFETY. `name` and each entry in `labels` come from the
 * trait metadata the owner adds. The code splices them into the JSON WITHOUT
 * escaping, so they must be valid JSON string contents: no quote, no
 * backslash, no control character. A quote ends the JSON string early. The
 * token document then fails to parse for every token, permanently, because
 * the trait metadata is frozen.
 *
 * KohiPiece ENFORCES this when a trait is added: a control byte, a quote or a
 * backslash in a trait name or label is refused.
 *
 * As an extra safeguard for data URIs, `_san` percent-encodes `#` to `%23`
 * and `%` to `%25` in every name and label it emits. An unescaped `#` starts
 * the URI fragment early and truncates the JSON after it. A stray `%` can be
 * misread during URI decoding.
 *
 * UNCHECKED ARITHMETIC. The scan and format bodies run `unchecked`. An
 * in-memory array length bounds each counter and offset (it cannot reach
 * 2^64, because memory cost grows quadratically in gas), and each steps by
 * small constants. The overflow checks would be dead code that costs bytes of
 * the contract-size budget. `unchecked` does not affect array-index
 * BOUNDS checks: they all still fire. `_fixedDecimal` stays checked: its
 * `10 ** dec` can overflow for an out-of-range `decimals`, and the arithmetic
 * panic there is intended.
 */
library Attributes {
    /// Per-piece trait metadata: for each trait id that the program of a
    /// piece can emit, how to label and render it in the `attributes` array
    /// of the tokenURI. An off-chain manifest entry can name an arbitrary
    /// formatting function. On-chain, the `kind` and `labels` fields replace
    /// it and cover every format in use.
    struct TraitMeta {
        uint8 id; // trait record id this entry describes
        uint8 kind; // 0 number, 1 choice, 2 flag, 3 value
        bool hidden; // omit from display (still recorded in the stream)
        // Numeric kinds: how many fractional digits to render (0 = integer
        // part only, the default; N > 0 = a fixed N-digit decimal; see
        // _fixedDecimal and VALUE FORMAT above). It shares a storage slot
        // with id, kind and hidden. An entry that never sets it reads 0.
        uint8 decimals;
        string name; // trait_type
        string[] labels; // choice/flag: index -> label; empty for number/value
    }

    // ---- extract ------------------------------------------------------------

    /// Concatenate the (id, value) payload of every trait record (tag byte
    /// 0x02) in a canonical draw-instruction stream. Each trait yields 9
    /// bytes of output: a 1-byte unsigned id and an 8-byte signed
    /// (big-endian) value. The function skips every other record by its exact
    /// byte width, so a 0x02 byte inside unrelated data (such as coordinate
    /// data) is never read as a trait record.
    function extractTraits(bytes memory stream) internal pure returns (bytes memory out) {
        unchecked {
        uint256 n = 0;
        uint256 i = 0;
        while (i < stream.length) {
            uint8 tag = uint8(stream[i]);
            if (tag == 0x02) {
                n++;
                i += 10;
            } else {
                i = _skip(stream, i, tag);
            }
        }
        out = new bytes(n * 9);
        uint256 w = 0;
        i = 0;
        while (i < stream.length) {
            uint8 tag = uint8(stream[i]);
            if (tag == 0x02) {
                // id + i64 value
                for (uint256 j = 0; j < 9; j++) out[w + j] = stream[i + 1 + j];
                w += 9;
                i += 10;
            } else {
                i = _skip(stream, i, tag);
            }
        }
        }
    }

    /// Return the offset after one non-trait record that starts at `i` (the
    /// caller already read the tag).
    function _skip(bytes memory stream, uint256 i, uint8 tag) private pure returns (uint256) {
        unchecked {
        if (tag == 0xb0) return i + 5; // begin: u16 w | u16 h
        if (tag == 0x00) return i + 5; // background: u32 argb
        if (tag == 0xb1) return stream.length; // end
        if (tag == 0x06) {
            // field: u8 kind | u32 | u32
            //   (+ kind 1: i64 scale | i64 warp | i32 seed)
            return i + (uint8(stream[i + 1]) == 1 ? 30 : 10);
        }
        if (tag == 0x07) return i + 2; // aliased: u8
        if (tag == 0x04) return i + 55; // stamp: u32 | u8 | u8 | 6*i64
        if (tag == 0x08) return i + 25; // cam: 3*i64
        if (tag == 0x09) return i + 50; // light: u8 | 6*i64
        if (tag == 0x0a) return i + 161; // mesh: 18*i64 | u32 | u32 | i64
        if (tag == 0x01) return _skipPaint(stream, i);
        revert("Attributes: unknown stream tag");
        }
    }

    /// Paint (0x01): u8 hasFill | u32 | u8 hasStroke | u32 | i64 strokeW |
    /// u8 flags | (u8 cap, u8 join if bit1) | (u8 blend if bit2) | (u8 kind |
    /// 4*i64 | u8 n | 6n stop bytes if bit3, a gradient fill) | (u8 kind |
    /// 2*i64 | 2*u32 | i32 = 29 bytes if bit4, a field fill) | u8 hasClip |
    /// (8*i64 if clip) | u16 segCount | segs.
    function _skipPaint(bytes memory stream, uint256 i) private pure returns (uint256) {
        unchecked {
        uint256 p = i + 1 + 1 + 4 + 1 + 4 + 8; // at the flags byte
        uint8 flags = uint8(stream[p]);
        p += 1; // past flags: at cap/blend/gradient/field/hasClip
        // An unrecognized paint-flag bit is a hard error, not a silent
        // misparse: a format extension must fail here, not read as valid
        // data. Bits 5..7 (mask 0xe0) are unrecognized. The code below
        // handles bit4 (the field-fill extension).
        if (flags & 0xe0 != 0) revert("Attributes: unknown paint flags");
        if (flags & 2 != 0) p += 2; // skip cap + join
        if (flags & 4 != 0) p += 1; // skip blend
        // skip the GFILL ext
        if (flags & 8 != 0) p += 34 + uint256(uint8(stream[p + 33])) * 6;
        // skip the FFILL field ext (bit3/bit4 exclusive)
        if (flags & 16 != 0) p += 29;
        uint8 hasClip = uint8(stream[p]);
        p += 1;
        if (hasClip == 1) p += 64; // 8 * i64
        uint256 segCount = (uint256(uint8(stream[p])) << 8) | uint256(uint8(stream[p + 1]));
        p += 2;
        for (uint256 s = 0; s < segCount; s++) {
            uint8 seg = uint8(stream[p]);
            if (seg == 0x01 || seg == 0x02) p += 17; // M/L: tag + 2*i64
            else if (seg == 0x03) p += 49; // C: tag + 6*i64
            else if (seg == 0x04) p += 1; // Z
            else revert("Attributes: bad seg tag");
        }
        return p;
        }
    }

    // ---- json ---------------------------------------------------------------

    /// Map the extracted (id|value) records through `meta` into the tokenURI
    /// `attributes` array. A record is omitted if its id has no metadata
    /// entry or its entry is `hidden`. Reads storage, so it is `view`.
    function toJson(bytes memory records, TraitMeta[] storage meta) internal view returns (string memory) {
        unchecked {
        bytes memory out = "[";
        bool first = true;
        // Each record is 9 bytes (u8 id | i64 value).
        for (uint256 off = 0; off + 9 <= records.length; off += 9) {
            (bool found, uint256 mi) = _find(meta, uint8(records[off]));
            if (!found || meta[mi].hidden) continue;
            // The per-entry JSON has its own frame (_entryJson), so its
            // locals do not share the stack with the loop locals.
            bytes memory entry = _entryJson(meta[mi], _readI64(records, off + 1));
            out = abi.encodePacked(out, first ? "" : ",", entry);
            first = false;
        }
        return string(abi.encodePacked(out, "]"));
        }
    }

    /// One `{"trait_type":"...","value":...}` object.
    function _entryJson(TraitMeta storage m, int64 value) private view returns (bytes memory) {
        bytes memory nameJson = _san(m.name);
        bytes memory valueJson = _valueJson(m, value);
        return abi.encodePacked('{"trait_type":"', nameJson, '","value":', valueJson, "}");
    }

    /// The JSON `value` token for one record: a quoted label for a
    /// choice/flag with an in-range index. Otherwise the unquoted decimal
    /// (number/value, or a label with an out-of-range or negative index).
    function _valueJson(TraitMeta storage m, int64 value) private view returns (bytes memory) {
        int64 idx = value >> 32; // Fix64 -> integer part (floor)
        if ((m.kind == 1 || m.kind == 2) && idx >= 0 && uint256(uint64(idx)) < m.labels.length) {
            bytes memory label = _san(m.labels[uint256(uint64(idx))]);
            return abi.encodePacked('"', label, '"');
        }
        if (m.decimals > 0) return bytes(_fixedDecimal(value, m.decimals));
        return bytes(_i64ToString(idx));
    }

    /// Linear scan for the metadata entry with trait id `id`. A piece
    /// declares few traits.
    function _find(TraitMeta[] storage meta, uint8 id) private view returns (bool, uint256) {
        unchecked {
        for (uint256 k = 0; k < meta.length; k++) {
            if (meta[k].id == id) return (true, k);
        }
        return (false, 0);
        }
    }

    /// Read a big-endian i64 at `off` from a 9-byte-record buffer.
    function _readI64(bytes memory b, uint256 off) private pure returns (int64) {
        unchecked {
        uint64 u = 0;
        for (uint256 i = 0; i < 8; i++) {
            u = (u << 8) | uint8(b[off + i]);
        }
        return int64(u);
        }
    }

    /// Percent-encode the `;utf8,` URI hazards `#`->`%23` and `%`->`%25` in a
    /// controlled name or label. JSON-string safety is enforced where traits
    /// are added.
    function _san(string memory s) private pure returns (bytes memory) {
        unchecked {
        bytes memory b = bytes(s);
        uint256 extra = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "#" || b[i] == "%") extra += 2;
        }
        if (extra == 0) return b;
        bytes memory o = new bytes(b.length + extra);
        uint256 w = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "#") {
                o[w++] = "%";
                o[w++] = "2";
                o[w++] = "3";
            } else if (b[i] == "%") {
                o[w++] = "%";
                o[w++] = "2";
                o[w++] = "5";
            } else {
                o[w++] = b[i];
            }
        }
        return o;
        }
    }

    /// Signed base-10 decimal of an int64.
    function _i64ToString(int64 v) private pure returns (string memory) {
        unchecked {
        if (v == 0) return "0";
        bool neg = v < 0;
        uint256 u = neg ? uint256(-int256(v)) : uint256(int256(v));
        bytes memory tmp = new bytes(20);
        uint256 n = 0;
        while (u != 0) {
            tmp[n++] = bytes1(uint8(48 + (u % 10)));
            u /= 10;
        }
        bytes memory out = new bytes(n + (neg ? 1 : 0));
        uint256 j = 0;
        if (neg) out[j++] = "-";
        for (uint256 k = 0; k < n; k++) {
            out[j++] = tmp[n - 1 - k];
        }
        return string(out);
        }
    }

    /// Render a Fix64 (Q31.32) `value` as a decimal string with `dec`
    /// fractional digits. It rounds half-up on the last kept digit (with
    /// integer carry), signs the result as sign-and-magnitude, and renders a
    /// negative zero such as `-0.000` as a clean zero. `dec` should stay in
    /// [1, 6]. This function does not enforce that range; it is a rule for
    /// the published trait metadata. The off-chain renderer has an equivalent
    /// routine, and tests verify that the two agree over a range of values.
    function _fixedDecimal(int64 value, uint8 dec) private pure returns (string memory) {
        bool neg = value < 0;
        uint64 mag = neg ? uint64(uint256(-int256(value))) : uint64(uint256(int256(value)));
        uint256 intPart = mag >> 32; // integer part
        uint256 frac = mag & 0xffffffff; // Q0.32 fraction
        uint256 pow = 10 ** dec;
        // `1 << 31` is half of 2^32, so the `>> 32` rounds to nearest
        // (half-up on the last kept digit). `scaled` is the fraction as an
        // integer in [0, 10^dec).
        uint256 scaled = (frac * pow + (1 << 31)) >> 32;
        if (scaled >= pow) {
            intPart += 1; // carry: 0.9996 -> 1.000
            scaled = 0;
        }
        bool isZero = intPart == 0 && scaled == 0;
        // Left-zero-pad `scaled` to `dec` digits.
        bytes memory fracStr = new bytes(dec);
        for (uint256 k = dec; k > 0; k--) {
            fracStr[k - 1] = bytes1(uint8(48 + (scaled % 10)));
            scaled /= 10;
        }
        // Suppress a lone `-` on a value that rounded to zero (e.g. -0.00001).
        bytes memory sign = (neg && !isZero) ? bytes("-") : bytes("");
        return string(abi.encodePacked(sign, _i64ToString(int64(uint64(intPart))), ".", fracStr));
    }
}
