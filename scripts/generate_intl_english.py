#!/usr/bin/env python3
"""Extract compact English currency/unit tables from ICU 78.3 data sources."""
import argparse
import json
import re
from pathlib import Path

UNITS = "acre bit byte celsius centimeter day degree fahrenheit fluid-ounce foot gallon gigabit gigabyte gram hectare hour inch kilobit kilobyte kilogram kilometer liter megabit megabyte meter microsecond mile mile-scandinavian milliliter millimeter millisecond minute month nanosecond ounce percent petabyte pound second stone terabit terabyte week yard year".split()


def resource(path):
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|//[^\n]*|[{},:]|[^\s{},:]+', path.read_text(encoding="utf-8-sig"))
    tokens = [t for t in tokens if not t.startswith("//")]
    index = 0
    def block():
        nonlocal index
        entries, values = {}, []
        while tokens[index] != "}":
            token = tokens[index]
            index += 1
            if token == ",":
                continue
            if token == "{":
                values.append(block())
                continue
            if tokens[index] == ":":
                index += 2  # resource type
            if tokens[index] == "{":
                index += 1
                entries[token] = block()
            else:
                value = json.loads(token) if token.startswith('"') else token
                if token.startswith('"') and tokens[index].startswith('"'):
                    while tokens[index].startswith('"'):
                        value += json.loads(tokens[index])
                        index += 1
                values.append(value)
        index += 1
        return entries if entries else values
    while tokens[index] != "{":
        index += 1
    index += 1
    return block()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=Path("src/builtins/intl_english_data.c3"))
    args = parser.parse_args()
    version = (args.source / "common/unicode/uvernum.h").read_text()
    if not re.search(r'#define U_ICU_VERSION "78\.3"', version):
        parser.error("Use ICU 78.3 sources for reproducible English tables")
    data = args.source / "data"
    currencies = resource(data / "curr/en.txt")
    root = resource(data / "curr/root.txt")
    meta = resource(data / "curr/supplementalData.txt")["CurrencyMeta"]
    units = resource(data / "unit/en.txt")
    pool = bytearray(b"\0")
    offsets = {"": 0}
    def intern(text):
        if text not in offsets:
            offsets[text] = len(pool)
            pool.extend(text.encode("utf-8") + b"\0")
        return offsets[text]
    def number(code):
        return sum(ord(c) << (8 * (2 - i)) for i, c in enumerate(code))
    rows = []
    for code, strings in sorted(currencies["Currencies"].items()):
        symbol, name = strings[:2]
        names = currencies.get("CurrencyPlurals", {}).get(code, {})
        narrow = currencies.get("Currencies%narrow", {}).get(code,
            root.get("Currencies%narrow", {}).get(code, [symbol]))[0]
        one = names.get("one", [name])[0]
        other = names.get("other", [name])[0]
        digits = int(meta.get(code, meta["DEFAULT"])[0])
        rows.append(f"    {{ 0x{number(code):06x}, {intern(symbol)}, {intern(narrow)}, {intern(one)}, {intern(other)}, {digits} }},")
    unit_rows = []
    for name in UNITS:
        patterns = []
        for width in ("units", "unitsShort", "unitsNarrow"):
            entry = next((group[name] for group in units[width].values() if isinstance(group, dict) and name in group), None)
            if entry is None:
                raise ValueError(f"Missing unit {width}/{name}")
            one = entry.get("one", entry["other"])[0]
            other = entry["other"][0]
            per = entry.get("perUnitPattern", [""])[0]
            patterns += [intern(one), intern(other), intern(per)]
        unit_rows.append("    { " + ", ".join([json.dumps(name)] + list(map(str, patterns))) + " },")
    if len(pool) > 65535:
        raise ValueError("English string pool exceeds 16-bit offsets")
    out = "// Generated from ICU 78.3 / CLDR 48. Unicode License V3: vendor/intl/LICENSE.\n"
    out += "// Regenerate with scripts/generate_intl_english.py --source <icu/source>.\n"
    out += "module boomkat::builtins;\n\n"
    out += "struct IntlCurrencyData { uint code; ushort symbol; ushort narrow; ushort one; ushort other; char digits; }\n"
    out += "struct IntlUnitData { String name; ushort one; ushort other; ushort per; ushort short_one; ushort short_other; ushort short_per; ushort narrow_one; ushort narrow_other; ushort narrow_per; }\n\n"
    out += "const IntlCurrencyData[*] INTL_CURRENCIES = {\n" + "\n".join(rows) + "\n};\n\n"
    out += "const IntlUnitData[*] INTL_UNITS = {\n" + "\n".join(unit_rows) + "\n};\n\n"
    out += "char[*] intl_english_strings @private = {\n"
    for i in range(0, len(pool), 24):
        out += "    " + ", ".join(f"0x{b:02x}" for b in pool[i:i+24]) + ",\n"
    out += "};\n"
    args.out.write_text(out)
    print(f"{len(rows)} currencies, {len(unit_rows)} units, {len(pool)} pooled string bytes")


if __name__ == "__main__":
    main()
