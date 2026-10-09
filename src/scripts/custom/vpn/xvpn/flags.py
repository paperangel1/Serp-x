"""Country flags from node names (Happ-style: the flag emoji is part of the subscription name)."""

_RI_A = 0x1F1E6
_RI_Z = 0x1F1FF

# name (lower-case, ru/en) -> ISO country code; used only when a name has no flag emoji
_NAMES = {
    "netherlands": "NL", "нидерланды": "NL", "голландия": "NL", "germany": "DE", "германия": "DE",
    "finland": "FI", "финляндия": "FI", "sweden": "SE", "швеция": "SE", "usa": "US", "сша": "US",
    "united states": "US", "japan": "JP", "япония": "JP", "france": "FR", "франция": "FR",
    "united kingdom": "GB", "uk": "GB", "великобритания": "GB", "англия": "GB", "poland": "PL",
    "польша": "PL", "turkey": "TR", "турция": "TR", "kazakhstan": "KZ", "казахстан": "KZ",
    "latvia": "LV", "латвия": "LV", "lithuania": "LT", "литва": "LT", "estonia": "EE", "эстония": "EE",
    "singapore": "SG", "сингапур": "SG", "hong kong": "HK", "гонконг": "HK", "switzerland": "CH",
    "швейцария": "CH", "austria": "AT", "австрия": "AT", "canada": "CA", "канада": "CA", "italy": "IT",
    "италия": "IT", "spain": "ES", "испания": "ES", "czech": "CZ", "чехия": "CZ", "romania": "RO",
    "румыния": "RO", "bulgaria": "BG", "болгария": "BG", "ukraine": "UA", "украина": "UA",
    "georgia": "GE", "грузия": "GE", "armenia": "AM", "армения": "AM", "uae": "AE", "оаэ": "AE",
    "india": "IN", "индия": "IN", "israel": "IL", "израиль": "IL", "norway": "NO", "норвегия": "NO",
    "denmark": "DK", "дания": "DK", "ireland": "IE", "ирландия": "IE", "portugal": "PT",
    "португалия": "PT", "serbia": "RS", "сербия": "RS", "moldova": "MD", "молдова": "MD",
    "russia": "RU", "россия": "RU", "brazil": "BR", "бразилия": "BR", "australia": "AU",
    "австралия": "AU", "korea": "KR", "корея": "KR", "taiwan": "TW", "тайвань": "TW",
    "belgium": "BE", "бельгия": "BE", "luxembourg": "LU", "люксембург": "LU", "iceland": "IS",
    "исландия": "IS", "greece": "GR", "греция": "GR", "hungary": "HU", "венгрия": "HU",
    "cyprus": "CY", "кипр": "CY", "mexico": "MX", "мексика": "MX", "argentina": "AR", "аргентина": "AR",
    "south africa": "ZA", "юар": "ZA", "thailand": "TH", "таиланд": "TH", "vietnam": "VN", "вьетнам": "VN",
}


def cc_to_flag(cc):
    cc = (cc or "").upper()
    if len(cc) != 2 or not cc.isalpha() or not cc.isascii():
        return ""
    return "".join(chr(_RI_A + ord(c) - ord("A")) for c in cc)


def flag_to_cc(flag):
    cps = [ord(c) for c in flag]
    if len(cps) >= 2 and all(_RI_A <= c <= _RI_Z for c in cps[:2]):
        return "".join(chr(ord("A") + c - _RI_A) for c in cps[:2])
    return ""


def _find_flag(s):
    """-> (start, end, cc) of the first regional-indicator pair, or None."""
    for i in range(len(s) - 1):
        a, b = ord(s[i]), ord(s[i + 1])
        if _RI_A <= a <= _RI_Z and _RI_A <= b <= _RI_Z:
            return i, i + 2, flag_to_cc(s[i:i + 2])
    return None


def _contains_word(low, word):
    """Substring match; short codes (uk, usa, оаэ ...) must stand alone, not sit inside another word."""
    if len(word) > 4:
        return word in low
    import re
    return re.search(r"(?<![\w])" + re.escape(word) + r"(?![\w])", low) is not None


def split_name(name):
    """name -> (flag emoji, ISO code, label without the flag). Falls back to country words in the name."""
    name = (name or "").strip()
    found = _find_flag(name)
    if found:
        i, j, cc = found
        label = (name[:i] + name[j:]).strip(" \t-–—|·:")
        return cc_to_flag(cc), cc, (label or name)
    low = name.lower()
    best = ""
    for word in _NAMES:
        if len(word) > len(best) and _contains_word(low, word):
            best = word
    if best:
        cc = _NAMES[best]
        return cc_to_flag(cc), cc, name
    return "", "", name
