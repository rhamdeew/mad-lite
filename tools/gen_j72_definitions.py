#!/usr/bin/env python3
"""Generate a VazCore calibration definition for Январь 7.2 I205DO54.

Shapes come from the firmware. `MOV DPTR,#addr` into the calibration area is
classified by the instructions that follow. The interpolators are the same
routines as in J5V05L19 (2D map, 32-point curve, 1D lerp); they are found by
byte signature because the code sits at different addresses.

Names, scales and units come from the TunerPro XDF
`cmgt/ecusystems` `i205do54.xdf` (cp1251, written 17.06.2011) when the address
matches. That file is not in git; it lives in `docs/vendor/git/ecusystems/`.

Confidence:
    confirmed — traced: the result is stored in the RAM cell the name claims
    likely    — XDF name, and the code's shape agrees (or the XDF size fits)
    auto      — shape only, no name

Usage:
    gen_j72_definitions.py FIRMWARE.bin i205do54.xdf OUT.json
"""
import json
import re
import sys
import xml.etree.ElementTree as ET

# First bytes of the J5V05L19 interpolators. The 2D routine also matches an
# XRAM twin (MOVX instead of MOVC); the real one has MOVC (0x93) at +24.
SIG_MAP = bytes.fromhex("eb54f0f5f0ea54f0c425f0fcea540ffa")
SIG_LINE32 = bytes.fromhex("eac423541ffbeac42354e0fa")
SIG_LERP = bytes.fromhex("ea93f8ea0493c398400a8bf0")
SIG_LINE16 = bytes.fromhex("f9c4540ff5f093f8e5f00493")

CAL_LO = 0x5F00
HEADER_LO, HEADER_HI = 0x6000, 0x6050  # platform / software id / date / model

EQ_RE = re.compile(
    r"^\(\(x & 0x[0-9A-Fa-f]+\) >> (-?\d+) - (-?\d+)\) \* ([0-9.]+) / ([0-9.]+) - (-?[0-9.]+)$"
)

# Traced in I205DO54. Notes are what the code does, not a guess from the title.
CONFIRMED = {
    0x613C: dict(
        name="Сетка оборотов: (обороты/30) → индекс столбца",
        group="Сетки",
        notes="Код 0x2DEB: [613C + 54h] → 57h, из него 58h (32 точки) и 59h (16 точек). "
              "Байты сетки совпадают с J5V05L19. Узел k — там, где значение достигает 16·k; "
              "обороты узла = позиция · 30.",
    ),
    0x7208: dict(
        name="Сетка дросселя: ДЗ % → индекс строки",
        group="Сетки",
        notes="Код читает [7208 + 52h] (52h — положение ДЗ, %, тот же байт, что в кадре KWP) "
              "и кладёт результат в R3 перед интерполяцией карт «обороты × дроссель».",
    ),
    0x6104: dict(
        name="Характеристика ДТОЖ",
        group="Датчики",
        notes="Код 0x28F1: индекс 0…31 (5 младших бит) и дробь в R3, 32 точки. "
              "Результат − 20, не ниже 0, пишется в 49h (ТОЖ кадра KWP, °C = E − 40), "
              "значит в ячейке лежит T+60: 20 °C хранится как 80. "
              "Кривые по температуре ОЖ — другие таблицы, их индекс 4Eh.",
    ),
    0x6613: dict(
        name="Состав смеси, экономичный режим",
        group="Топливо",
        notes="Код 0x44E4: ячейка 5Fh (16×16 без интерполяции) → 60h, желаемый AFR. "
              "Формула XDF 14,7·(E+128)/256 — та же, что байт AFR в кадре KWP.",
    ),
    0x6953: dict(
        name="Состав смеси, мощностной режим",
        group="Топливо",
        notes="Код 0xB118: интерполяция 57h×5Ch → 60h (AFR). В других местах результат смешивается с текущим составом.",
    ),
    0x6AC8: dict(
        name="УОЗ, экономичный режим",
        group="Зажигание",
        notes="Код 0x44F4 и 0x469C: интерполяция 57h×5Ch → 62h (УОЗ, в кадре KWP это E/2). "
              "Выбирается, когда сброшены флаги неисправности ДМРВ 23h.6 и 24h.6; иначе карта 7877.",
    ),
    0x6CC8: dict(
        name="УОЗ в зоне регулирования по ДК",
        group="Зажигание",
        notes="Код 0x4EE3: интерполяция 57h×5Ch → 62h.",
    ),
    0x6DC8: dict(
        name="УОЗ, мощностной режим",
        group="Зажигание",
        notes="Код 0xB0F7: интерполяция 57h×5Ch → 62h. Рядом результат смешивается с добавкой из XRAM.",
    ),
    0x7877: dict(
        name="УОЗ при неисправности ДМРВ",
        group="Зажигание",
        xAxis="rpm16",
        yAxis="load16",
        notes="Код 0x4693: DPTR остаётся 7877, если установлен 23h.6 или 24h.6 (флаги ДМРВ, те же биты, что в кадре KWP); "
              "иначе подменяется на 6AC8. Дальше интерполяция 57h×5Ch → 62h.",
    ),
    0x9D3C: dict(
        name="Замена положения ДЗ при неисправности ДПДЗ",
        group="Аварийные режимы",
        notes="Код 0x3C4D: интерполяция 57h×5Ch, результат пишется в 52h — байт положения дросселя.",
    ),
}

# Notes that do not change the name. The address was still read in the code.
EXTRA_NOTES = {
    0x726D: "Столбец — индекс оборотов 57h, строка — индекс дросселя из сетки 7208 по байту 52h (код 0x176A).",
    0x75EF: "Вызов 0x1AED берёт строку из сетки дросселя; вызов 0x3C7D пользуется индексами, которые уже стоят в регистрах.",
    0x6713: "Вызов 0x45DC — карта 16×16, результат пишется в XRAM FF4F, не в байт состава смеси. "
            "Температура из названия XDF осями карты не является.",
    0x8E2A: "Код 0x509E: после интерполяции значение ограничивается 0x0F…0xF0 и пишется в 4Fh. "
            "Масштаб (E+128)/256 — тот же, что у коэффициента коррекции впрыска в кадре KWP.",
}


def find_proc(rom, sig, movc_at=None):
    hits = []
    start = 0
    while True:
        i = rom.find(sig, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1
    if movc_at is not None:
        hits = [i for i in hits if i + movc_at < len(rom) and rom[i + movc_at] == 0x93]
    if len(hits) != 1:
        raise SystemExit(f"signature {sig[:4].hex()}… matched {hits}, expected one")
    return hits[0]


def parse_equation(eq):
    """TunerPro stored form → (scale, offset) for `raw * scale + offset`."""
    m = EQ_RE.match((eq or "").strip())
    if not m:
        return None
    shift, off, num, den, sub = m.groups()
    shift, off = int(shift), int(off)
    num, den, sub = float(num), float(den), float(sub)
    if den == 0 or shift < 0:
        return None
    mag = (num / den) / (2 ** shift)
    # ((x >> shift) - off) * num/den - sub
    offset = -off * (num / den) - sub
    return mag, offset


def clean_num(x):
    if x is None:
        return None
    if abs(x) < 1e-9:
        return 0.0
    return round(x, 10)


def clean_title(text):
    text = (text or "").strip().strip('"').strip()
    # The XDF mixes Latin H into Cyrillic words ("ЦH", "КОHДИЦ").
    text = re.sub(r"(?<=[А-Яа-я])H", "Н", text)
    text = text.replace("Hеравномерность", "Неравномерность")
    return re.sub(r"\s+", " ", text)


def clean_unit(text):
    """Value unit. `$0A` is a TunerPro newline left in axis captions."""
    text = (text or "").replace("$0A", " ").replace("$0D", " ")
    text = text.replace('"', "").replace("«", "").replace("»", "")
    text = re.sub(r"\s+", " ", text).strip(" ,")
    if not text:
        return None
    low = text.lower().replace(" ", "")
    if "п.к.в" in low:
        return "°"
    if low in ("град.", "град", "гр."):
        return "°"
    if "сек" in low and "град" in low:
        return "°/с"
    if low in ("град.с", "град.с.") or (low.startswith("температура") and "град" in low):
        return "°C"
    folded = {
        "об./мин": "об/мин",
        "об/мин.": "об/мин",
        "обороты,об/мин": "об/мин",
        "мг./цикл": "мг/цикл",
    }
    return folded.get(low, text)


def group_of(title):
    t = title.lower().replace("ё", "е")
    if "квантован" in t:
        return "Сетки"
    if "неравномер" in t:
        return "Пропуски воспламенения"
    if "детонац" in t or "шум" in t:
        return "Детонация"
    if any(s in t for s in ("уоз", "зажиган", "накоплен")):
        return "Зажигание"
    if "рхх" in t or "холост" in t or "частот" in t or re.search(r"(^|[^а-яa-z])хх([^а-яa-z]|$)", t):
        return "Холостой ход"
    if "пуск" in t:
        return "Пуск"
    if "прогрев" in t:
        return "Топливо: прогрев"
    if "наполн" in t or re.search(r"(^|[^а-яa-z])цн([^а-яa-z]|$)", t) or "расход воздуха" in t or "разряжен" in t:
        return "Наполнение"
    if "продув" in t or "адсорб" in t:
        return "Адсорбер"
    if any(s in t for s in ("впрыск", "смес", "топлив", "форсун", "экономич", "мощност", "барокорр")):
        return "Топливо"
    if "лямб" in t or "кислород" in t or "lean" in t or "rich" in t:
        return "Лямбда"
    if any(s in t for s in ("дтож", "дпдз", "дмрв", "датчик", "твозд")):
        return "Датчики"
    if "авар" in t or "имитат" in t or "иммитат" in t:
        return "Аварийные режимы"
    return ""


def load_xdf(path):
    raw = open(path, "rb").read()
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", raw.decode("cp1251"))
    root = ET.fromstring(text)
    tables = {}
    flags = {}

    def take_addr(el):
        e = el.find("EMBEDDEDDATA")
        if e is not None and e.get("mmedaddress"):
            return int(e.get("mmedaddress"), 16), int(e.get("mmedelementsizebits") or "8")
        for ax in el.findall("XDFAXIS"):
            if ax.get("id") == "z":
                ee = ax.find("EMBEDDEDDATA")
                if ee is not None and ee.get("mmedaddress"):
                    return int(ee.get("mmedaddress"), 16), int(ee.get("mmedelementsizebits") or "8")
        return None, None

    for el in list(root.findall("XDFTABLE")) + list(root.findall("XDFCONSTANT")):
        addr, bits = take_addr(el)
        if addr is None:
            continue
        title = clean_title(el.findtext("title"))
        math = ""
        for m in el.iter("MATH"):
            if m.get("equation") and m.get("equation") not in ("x", "INDEX()"):
                math = m.get("equation")
                break
        units = ""
        if el.tag == "XDFCONSTANT":
            units = clean_unit(el.findtext("units")) or ""
            rows, cols = 1, 1
        else:
            counts = {}
            y_units = ""
            for ax in el.findall("XDFAXIS"):
                counts[ax.get("id")] = int(ax.findtext("indexcount") or "0")
                if ax.get("id") == "z":
                    units = clean_unit(ax.findtext("units")) or units
                if ax.get("id") == "y":
                    y_units = clean_unit(ax.findtext("units")) or ""
            cols = counts.get("x") or 1
            rows = counts.get("y") or 1
            # On a curve the Y axis caption is the value. On a map it is the row axis.
            if rows <= 1 and not units:
                units = y_units
        rec = tables.setdefault(addr, {"titles": [], "bits": bits, "rows": rows, "cols": cols, "math": math, "units": units})
        if title and title not in rec["titles"]:
            rec["titles"].append(title)
        rec["bits"] = max(rec["bits"], bits)
        if rows * cols > rec["rows"] * rec["cols"]:
            rec["rows"], rec["cols"] = rows, cols
        if math and not rec["math"]:
            rec["math"] = math
        if units and not rec["units"]:
            rec["units"] = units

    for el in root.findall("XDFFLAG"):
        e = el.find("EMBEDDEDDATA")
        if e is None or not e.get("mmedaddress"):
            continue
        addr = int(e.get("mmedaddress"), 16)
        mask_txt = (el.findtext("mask") or "0").strip()
        mask = int(mask_txt, 16)
        if mask == 0 or mask & (mask - 1):
            continue  # not a single bit
        bit = mask.bit_length() - 1
        flags.setdefault(addr, []).append((bit, clean_title(el.findtext("title"))))
    for addr in flags:
        flags[addr].sort()
    return tables, flags


def classify(rom, i, procs):
    """What the code does with the DPTR loaded at `i`. Stops at the next MOV DPTR."""
    MAP, LINE32, LERP = procs
    window = rom[i + 3:i + 22]
    # Cut the window at a following immediate load so we don't steal the next table.
    cut = len(window)
    for k in range(len(window) - 2):
        if window[k] == 0x90:
            cut = k
            break
    w = window[:cut]
    blob = bytes(w)

    def has(seq):
        return blob.find(bytes(seq)) >= 0

    map_call = bytes([0x12, MAP >> 8, MAP & 0xFF])
    line_call = bytes([0x12, LINE32 >> 8, LINE32 & 0xFF])
    lerp_call = bytes([0x12, LERP >> 8, LERP & 0xFF])
    kinds = set()
    if has([0xAA, 0x57, 0xAB, 0x5C]) and map_call in blob:
        kinds.add("map")
    elif has([0xAA, 0x57]) and map_call in blob:
        kinds.add("map-rpm")  # R3 was set up earlier; often the throttle index
    elif map_call in blob:
        kinds.add("map")
    if has([0xE5, 0x5F, 0x93]):
        kinds.add("map-nearest")
    if (has([0xAA, 0x57]) and line_call in blob) or has([0xE5, 0x58, 0x93]):
        kinds.add("rpm32")
    if has([0xE5, 0x5D, 0x93]):
        kinds.add("load32")
    if has([0xE5, 0x4E, 0x93]) or (has([0xAA, 0x4E]) and lerp_call in blob):
        kinds.add("temp")
    if has([0xE5, 0x54, 0x93]):
        kinds.add("rpm-grid")
    if has([0xE5, 0x52, 0x93]):
        kinds.add("tps-grid")
    if has([0xE4, 0x93, 0xF8, 0xA3]):
        kinds.add("u16")
    elif has([0xE4, 0x93]):
        kinds.add("scalar")
    # 16×16 whose row index was just read from the throttle grid.
    if b"\x90\x72\x08" in rom[max(0, i - 8):i] and ("map" in kinds or "map-rpm" in kinds):
        kinds.add("map-tps")
    return kinds


PRIORITY = ["map-tps", "map", "map-nearest", "map-rpm", "rpm32", "load32", "temp", "rpm-grid", "tps-grid", "u16", "scalar"]

SHAPES = {
    "map": dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16"),
    "map-nearest": dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16"),
    "map-tps": dict(rows=16, cols=16, xAxis="rpm16", yAxis="throttle16"),
    "map-rpm": dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16"),
    "rpm32": dict(rows=1, cols=32, xAxis="rpm32"),
    "load32": dict(rows=1, cols=32, xAxis="load32"),
    "temp": dict(rows=1, cols=39, xAxis="temp"),
    "rpm-grid": dict(rows=1, cols=256, xAxis="rpmRaw"),
    "tps-grid": dict(rows=1, cols=101, xAxis="throttleRaw"),
    "u16": dict(rows=1, cols=1, dataType="u16le"),
    "scalar": dict(rows=1, cols=1),
}


def shape_agrees(kind, rows, cols, bits):
    if kind in ("map", "map-nearest", "map-tps", "map-rpm"):
        return rows == 16 and cols == 16 and bits == 8
    if kind == "rpm32":
        return rows == 1 and cols == 32 and bits == 8
    if kind == "load32":
        return rows == 1 and cols == 32 and bits == 8
    if kind == "temp":
        return rows == 1 and cols == 39 and bits == 8
    if kind == "rpm-grid":
        return cols == 256 and bits == 8
    if kind == "tps-grid":
        return cols in (101, 256) and bits == 8
    if kind == "u16":
        return bits == 16 and rows * cols == 1
    if kind == "scalar":
        return bits == 8 and rows * cols == 1
    return False


def main(src, xdf_path, out):
    rom = open(src, "rb").read()
    if rom[0x6020:0x6028].rstrip(b"\0") != b"I205DO54":
        raise SystemExit(f"expected I205DO54, got {rom[0x6020:0x6028]!r}")
    procs_addr = (
        find_proc(rom, SIG_MAP, movc_at=24),
        find_proc(rom, SIG_LINE32),
        find_proc(rom, SIG_LERP),
    )
    code_at = min(procs_addr)
    xdf, flags = load_xdf(xdf_path)

    refs = {}
    for i in range(len(rom) - 24):
        if rom[i] != 0x90:
            continue
        addr = rom[i + 1] << 8 | rom[i + 2]
        if not (CAL_LO <= addr < code_at) or HEADER_LO <= addr < HEADER_HI:
            continue
        kinds = classify(rom, i, procs_addr)
        if kinds:
            refs.setdefault(addr, set()).update(kinds)

    # Addresses the XDF names and the code actually loads.
    addrs = sorted(set(refs) | set(xdf))
    addrs = [a for a in addrs if CAL_LO <= a < code_at and not (HEADER_LO <= a < HEADER_HI)]

    drafted = []
    for addr in addrs:
        kinds = refs.get(addr, set())
        meta = xdf.get(addr)
        kind = next((k for k in PRIORITY if k in kinds), None)
        if kind is None and meta is None:
            continue
        if kind is None:
            # Named by the XDF, never loaded with a recognizable opcode.
            bits = meta["bits"]
            shape = dict(rows=meta["rows"], cols=meta["cols"])
            if bits == 16 and shape["rows"] * shape["cols"] == 1:
                shape["dataType"] = "u16le"
            origin = "xdf"
        else:
            shape = dict(SHAPES[kind])
            origin = "code"
            if meta is not None and not shape_agrees(kind, meta["rows"], meta["cols"], meta["bits"]):
                # A bare `CLR A / MOVC` is how a multi-byte table is also entered.
                # Keep the code shape when it is a real map or curve; otherwise
                # take the XDF size if it fits before the next referenced address.
                strong = kind in ("map", "map-nearest", "map-tps", "map-rpm", "rpm32", "load32", "temp", "rpm-grid", "tps-grid")
                if not strong:
                    shape = dict(rows=meta["rows"], cols=meta["cols"])
                    if meta["bits"] == 16:
                        shape["dataType"] = "u16le"
                    origin = "xdf-size"
        drafted.append({"addr": addr, "kind": kind, "shape": shape, "origin": origin, "meta": meta, "kinds": kinds})

    # Drop entries that fall inside an earlier, larger table.
    drafted.sort(key=lambda d: (d["addr"], -(d["shape"]["rows"] * d["shape"]["cols"] * (2 if d["shape"].get("dataType") == "u16le" else 1))))
    kept = []
    covered_until = 0
    for d in drafted:
        if d["addr"] < covered_until and d["addr"] != (kept[-1]["addr"] if kept else None):
            continue
        if kept and kept[-1]["addr"] == d["addr"]:
            continue
        size = d["shape"]["rows"] * d["shape"]["cols"] * (2 if d["shape"].get("dataType") == "u16le" else 1)
        # Curves must not run into the next kept-or-drafted address.
        later = [x["addr"] for x in drafted if x["addr"] > d["addr"]]
        gap = (later[0] if later else code_at) - d["addr"]
        if d["shape"]["rows"] == 1 and d["shape"]["cols"] > 1 and size > gap:
            d["shape"]["cols"] = max(1, gap // (2 if d["shape"].get("dataType") == "u16le" else 1))
            size = d["shape"]["cols"] * (2 if d["shape"].get("dataType") == "u16le" else 1)
        if size > gap and d["shape"]["rows"] > 1:
            # A map that would swallow the next real table is not that map.
            continue
        if d["addr"] + size > code_at:
            continue
        kept.append(d)
        covered_until = d["addr"] + size

    FIELD_ORDER = ["id", "name", "group", "address", "rows", "cols", "xAxis", "yAxis",
                   "scale", "offset", "unit", "dataType", "confidence", "notes"]
    tables = []
    for d in kept:
        meta = d["meta"]
        shape = d["shape"]
        titles = meta["titles"] if meta else []
        name = titles[0] if titles else None
        if name is None:
            label = {
                "map": "Карта 16×16 (обороты × нагрузка)",
                "map-nearest": "Карта 16×16 без интерполяции",
                "map-tps": "Карта 16×16 (обороты × дроссель)",
                "map-rpm": "Карта 16×16 (обороты × ?)",
                "rpm32": "Кривая по оборотам",
                "load32": "Кривая по нагрузке",
                "temp": "Кривая по температуре ОЖ",
                "rpm-grid": "Сетка оборотов",
                "tps-grid": "Сетка дросселя",
                "u16": "Константа 16 бит",
                "scalar": "Константа",
                None: "Калибровка",
            }[d["kind"]]
            name = f"{label} @{d['addr']:04X}"
            group = "Не определено"
            confidence = "auto"
        else:
            group = group_of(name) or ("Константы" if shape["rows"] * shape["cols"] == 1 else "Калибровки")
            confidence = "likely"
        if shape["rows"] == 16 and shape["cols"] == 16 and "xAxis" not in shape:
            # Maps whose call site did not name the axes. rpm × load is the common case;
            # throttle rows are set only when the code reads grid 7208 into R3.
            shape["xAxis"] = "rpm16"
            shape["yAxis"] = "load16"
        if shape["rows"] == 1 and shape["cols"] == 39 and "xAxis" not in shape:
            shape["xAxis"] = "temp"
        t = {
            "id": f"t{d['addr']:04X}",
            "name": name,
            "group": group,
            "address": f"0x{d['addr']:04X}",
            "rows": shape["rows"],
            "cols": shape["cols"],
            "confidence": confidence,
        }
        if shape.get("xAxis"):
            t["xAxis"] = shape["xAxis"]
        if shape.get("yAxis"):
            t["yAxis"] = shape["yAxis"]
        if shape.get("dataType"):
            t["dataType"] = shape["dataType"]
        notes = []
        if meta and meta["math"]:
            parsed = parse_equation(meta["math"])
            if parsed:
                scale, offset = (clean_num(v) for v in parsed)
                if scale not in (None, 1, 1.0):
                    t["scale"] = scale
                if offset not in (None, 0, 0.0):
                    t["offset"] = offset
            elif meta["math"] not in ("x",):
                notes.append(f"формула XDF не разобрана: {meta['math']}")
        unit = clean_unit(meta["units"]) if meta and meta["units"] else None
        scale = t.get("scale")
        offset = t.get("offset") or 0
        if unit is None and scale is not None:
            if abs(scale - 14.7 / 256) < 1e-9:
                unit = "AFR"
            elif scale == 0.5 and "уоз" in name.lower():
                unit = "°"
            elif abs(scale - 8 / 3) < 1e-6:
                unit = "мг/цикл"
            elif abs(scale - 1 / 256) < 1e-12 and abs(offset - 0.5) < 1e-9:
                unit = "×"
        if unit is None and "коэфф" in name.lower():
            unit = "×"
        if unit == "°C" or (offset == -60 and unit is None):
            unit = "°C"
        if unit:
            t["unit"] = unit
        if len(titles) > 1:
            notes.append("В XDF этот же адрес назван ещё: " + "; ".join(titles[1:]))
        loaded = rom.find(bytes([0x90, d["addr"] >> 8, d["addr"] & 0xFF])) >= 0
        if d["origin"] == "xdf" and d["kind"] is None and not loaded:
            notes.append("Прямой загрузки этого адреса командой MOV DPTR в прошивке нет — адрес взят из XDF.")
        if d["origin"] == "xdf-size" and shape["rows"] * shape["cols"] > 1:
            notes.append(f"Код обращается к адресу как к байту; размер {shape['rows']}×{shape['cols']} взят из XDF.")
        extra = EXTRA_NOTES.get(d["addr"])
        if extra:
            notes.append(extra)
        bitnotes = flags.get(d["addr"])
        if bitnotes and shape["rows"] * shape["cols"] == 1:
            notes.append("Биты: " + ", ".join(f"{bit} — {title}" for bit, title in bitnotes))
        confirmed = CONFIRMED.get(d["addr"])
        if confirmed:
            # Code evidence wins over the XDF title and the keyword group.
            xdf_name = t["name"]
            t.update({k: v for k, v in confirmed.items() if k != "notes"})
            t["confidence"] = "confirmed"
            if confirmed.get("notes"):
                notes.insert(0, confirmed["notes"])
            if xdf_name and xdf_name != t["name"]:
                notes.append(f"Название в XDF: «{xdf_name}».")
        if notes:
            t["notes"] = " ".join(notes)
        tables.append({k: t[k] for k in FIELD_ORDER if k in t})

    definition = {
        "softwareIDs": ["I205DO54"],
        "family": "J7.2",
        "source": "I205DO54: формы по коду (tools/gen_j72_definitions.py), названия и масштабы — XDF i205do54 (cm_gt, 17.06.2011). "
                  "confidence=confirmed — результат прослежен до ячейки ОЗУ; likely — имя из XDF и форма сошлась; auto — только форма.",
        "axes": {
            "rpm16": {"kind": "inverseLookup", "address": "0x613C", "length": 256, "points": 16, "step": 16, "scale": 30, "unit": "об/мин"},
            "rpm32": {"kind": "inverseLookup", "address": "0x613C", "length": 256, "points": 32, "step": 8, "scale": 30, "unit": "об/мин"},
            "rpmRaw": {"kind": "linear", "start": 0, "step": 30, "points": 256, "unit": "об/мин"},
            "load16": {"kind": "j5Load", "offsetAddress": "0x6064", "gainAddress": "0x6066", "divisor": 6, "points": 16, "step": 16, "unit": "мг/цикл"},
            "load32": {"kind": "j5Load", "offsetAddress": "0x6064", "gainAddress": "0x6066", "divisor": 6, "points": 32, "step": 8, "unit": "мг/цикл"},
            "throttle16": {"kind": "inverseLookup", "address": "0x7208", "length": 101, "points": 16, "step": 16, "scale": 1, "unit": "% ДЗ"},
            "throttleRaw": {"kind": "linear", "start": 0, "step": 1, "points": 101, "unit": "% ДЗ"},
            "temp": {"kind": "linear", "start": -40, "step": 5, "points": 39, "unit": "°C"},
        },
        "tables": tables,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(definition, f, ensure_ascii=False, indent=2)
        f.write("\n")
    named = sum(t["confidence"] != "auto" for t in tables)
    confirmed = sum(t["confidence"] == "confirmed" for t in tables)
    print(f"procs map={procs_addr[0]:04X} line32={procs_addr[1]:04X} lerp={procs_addr[2]:04X}")
    print(f"{len(tables)} tables, {named} named, {confirmed} confirmed, code refs {len(refs)}, xdf {len(xdf)} -> {out}")
    from collections import Counter
    print(Counter(t["group"] for t in tables))
    print(Counter(t["confidence"] for t in tables))


if __name__ == "__main__":
    main(*sys.argv[1:4])
