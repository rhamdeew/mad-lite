#!/usr/bin/env python3
"""Generate a VazCore calibration definition (JSON) for a Январь 5.1 image.

Tables are discovered from `MOV DPTR,#addr` (90 hi lo) references into the
calibration area and typed by the code that follows the reference:

    AA 57 AB 5C 12 A5 9D   2D 16x16, cols = RPM index 57h, rows = load index 5Ch
    E5 5F 93               16x16 without interpolation (5Fh = row*16 + col)
    E5 58 93 / A575(57h)   1D, 32 points by RPM
    E5 5D 93 / A575(5Ch)   1D, 32 points by load
    E5 4E 93               1D by coolant temperature, -40 °C step 5
    E5 54 93               1D, 256 points by raw RPM (30 rpm/unit)
    E4 93                  scalar

Meanings of RAM variables come from the KWP2000 readDataByLocalIdentifier 01
frame, which the firmware assembles from address lists at 0x597A/0x598B/0x5999
(SMS-Soft "kwp2000_euro2.doc" gives the byte order and formulas):

    49h ТОЖ+40   52h ДЗ %   55h обороты/40   61h AFR   6Fh коэф. впрыска
    F844 УОЗ·2   F849 обороты ХХ/10   F841 впрыск·125   F82E ЦН·6   F8F8 КС ПЗУ

The RAM variables were found in J5V05L19 and are shared by the family. The code moves
between versions, so the interpolation procedures are found by their bodies and the grids
(RPM, throttle, load) by the code that reads them; KNOWN names apply to another version only
where it reads the same address the same way. Usage:

    gen_j5_definitions.py FIRMWARE.bin OUT.json
    gen_j5_definitions.py --all [OUT_DIR]     every serial J5 ROM in firmware/catalog.json
"""
import json
import os
import re
import sys

import ctp_map

CAL_START, CAL_END = 0x6000, 0xA000

AFR = dict(scale=14.7 / 256, offset=14.7 * 128 / 256, unit="AFR")
IGN = dict(scale=0.5, unit="°")
MAP = dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16")
TEMP = dict(rows=1, cols=39, xAxis="temp")
COEF = dict(scale=1 / 256, offset=0.5, unit="×")  # (E+128)/256, as 6Fh in the KWP frame
VOLT = dict(rows=1, cols=16, xAxis="voltage16")

# Tables identified by reading the code. Keys override the generated entry.
KNOWN = {
    # Grids and sensors
    0x6104: dict(name="Характеристика ДТОЖ: АЦП/8 → T+60 °C", group="Датчики", confidence="confirmed", rows=1, cols=51,
                 notes="Сверено с характеристикой датчика 19.3801 и подтяжкой 2 кОм: 20 °C → ~79, 100 °C → ~157."),
    0x613C: dict(name="Сетка оборотов: (обороты/30) → индекс столбца", group="Сетки", confidence="confirmed",
                 rows=1, cols=256, xAxis="rpmRaw",
                 notes="Значение 16·k — узел k карт 16×16. Изменение сдвигает сетку всех карт."),
    0x7208: dict(name="Сетка дросселя: ДЗ % → индекс строки", group="Сетки", confidence="confirmed",
                 rows=1, cols=101, xAxis="throttleRaw",
                 notes="Индекс по 52h (положение ДЗ, %, из кадра KWP). Значение 16·k — узел k осей по дросселю."),
    0x6064: dict(name="Сетка нагрузки: смещение (младший байт)", group="Сетки", confidence="confirmed",
                 notes="Строка = ((ЦН·6 − смещение) >> 3) · коэф. >> 8."),
    0x6065: dict(name="Сетка нагрузки: смещение (старший байт)", group="Сетки", confidence="confirmed"),
    0x6066: dict(name="Сетка нагрузки: коэффициент", group="Сетки", confidence="confirmed"),

    # Mixture: result goes to 60h → 61h, reported over KWP as AFR = 14.7·(E+128)/256
    0x6613: dict(name="Состав смеси, основной (вместе с УОЗ A/B)", group="Топливо", confidence="likely", **MAP, **AFR,
                 notes="Результат → 60h → 61h (AFR в кадре KWP). Вызывается в одной ветке с УОЗ 6AC8/6BC8."),
    0x6713: dict(name="Состав смеси, зона регулирования по ДК", group="Топливо", confidence="likely", **MAP, **AFR,
                 notes="Вызывается вместе с УОЗ 6CC8. Везде 14,7 — стехиометрия для работы с датчиком кислорода."),
    0x6953: dict(name="Состав смеси, вариант 3 (вместе с УОЗ D)", group="Топливо", confidence="likely", **MAP, **AFR,
                 notes="Смешивается с текущим составом через A5FF; вызывается вместе с УОЗ 6DC8."),

    # Ignition: result goes to 62h → F844, reported as УОЗ = E/2
    0x6AC8: dict(name="УОЗ A (основной режим)", group="Зажигание", confidence="likely", **MAP, **IGN,
                 notes="Результат → 62h → F844 (УОЗ в кадре KWP, E/2). Выбирается, когда сброшен флаг комплектации 20h.2."),
    0x6BC8: dict(name="УОЗ B (основной режим, флаг 20h.2)", group="Зажигание", confidence="likely", **MAP, **IGN,
                 notes="Вместо 6AC8, когда установлен бит 2 слова комплектации 1 (по протоколу — клапан рециркуляции)."),
    0x6CC8: dict(name="УОЗ C (зона регулирования по ДК)", group="Зажигание", confidence="likely", **MAP, **IGN,
                 notes="Вызывается вместе с составом смеси 6713."),
    0x6DC8: dict(name="УОЗ D (вместе с составом 6953)", group="Зажигание", confidence="likely", **MAP, **IGN),
    0x7877: dict(name="УОЗ в аварийном режиме (неисправен ДМРВ или ДПДЗ)", group="Зажигание", confidence="confirmed", **MAP, **IGN,
                 notes="Код 0x4077: при любом из флагов 23h.5/24h.5 (ДПДЗ) или 23h.6/24h.6 (ДМРВ) УОЗ → 62h отсюда, "
                       "AFR = [60AD]. В XDF I205DO54 (J7.2) по этому адресу тоже «аварийный режим ДМРВ: УОЗ»."),
    0x60AD: dict(name="Состав смеси в аварийном режиме ДМРВ/ДПДЗ", group="Топливо", confidence="likely", **AFR),
    0x6063: dict(name="ДМРВ: порог высокого сигнала", group="Датчики", confidence="likely",
                 notes="Код 0x1641: при превышении ставится флаг 24h.6 (высокий уровень сигнала ДМРВ)."),

    # Start
    0x710B: dict(name="Пуск: цикловая подача по ТОЖ", group="Пуск", confidence="likely", **TEMP,
                 notes="Базовое значение пусковой подачи; дальше умножается на поправки 7132, 7A77, 7A87."),
    0x7A77: dict(name="Пуск: поправка по дросселю (продувка)", group="Пуск", confidence="likely",
                 rows=1, cols=16, xAxis="throttle16",
                 notes="0 при дросселе выше ~70 % — режим продувки цилиндров при пуске."),
    0x7A87: dict(name="Пуск: поправка по числу циклов после старта", group="Пуск", confidence="likely",
                 rows=1, cols=32, xAxis="startCycles", notes="Индекс — счётчик F89E / 8."),
    0x7132: dict(name="Пуск: поправка (индекс по ТОЖ/частоте)", group="Пуск", confidence="likely", rows=1, cols=32),

    # Idle
    0x6F56: dict(name="Желаемые обороты ХХ по ТОЖ", group="Холостой ход", confidence="likely", **TEMP,
                 scale=10, unit="об/мин",
                 notes="Интерполяция A611 по температуре; итог → F849 (желаемые обороты ХХ в кадре KWP, E·10)."),
    0x60E5: dict(name="Добавка к желаемым оборотам ХХ", group="Холостой ход", confidence="likely", scale=10, unit="об/мин"),

    # Fuel: ЦН·256/(AFR+128) → film model → ×6Fh ×77h ×[6057] + 50h, min [5FA8] → F841 (E/125 мс)
    0x6057: dict(name="Масштаб подачи → время впрыска (производительность форсунок)", group="Топливо", confidence="likely",
                 notes="Последний множитель перед F841: больше значение — длиннее впрыск на всех режимах. "
                       "Меняется при замене форсунок."),
    0x5FA8: dict(name="Минимальная длительность впрыска", group="Топливо", confidence="likely",
                 dataType="u16le", scale=0.008, unit="мс",
                 notes="Если рассчитанное время меньше, подставляется это значение. Лежит перед областью калибровок (0x5Fxx)."),
    0x71D8: dict(name="Время задержки открытия форсунки по напряжению", group="Топливо", confidence="likely", **VOLT,
                 scale=0.008, unit="мс",
                 notes="Результат → 50h, прибавляется к времени впрыска. Ось — напряжение F978 (5,2 + E·0,05 В)."),
    0x6813: dict(name="Коэффициент коррекции впрыска без ДК", group="Топливо", confidence="likely", **MAP, **COEF,
                 notes="Результат → 6Fh (коэффициент коррекции в кадре KWP), ограничен 0x0F..0xF0. "
                       "При работе с ДК 6Fh задаёт регулятор."),
    0x8E2A: dict(name="Коррекция топливоподачи на ХХ", group="Холостой ход", confidence="likely", **MAP, **COEF,
                 notes="Результат → 77h, только при признаке ХХ (2Bh.1); вне ХХ коэффициент 1,0."),
    0x6F0F: dict(name="Плёнка топлива: доля осаждения по нагрузке", group="Топливо: плёнка", confidence="likely",
                 rows=1, cols=32, xAxis="load32",
                 notes="Умножается на 6F2F; результат F836 — доля подачи, оседающая на стенках коллектора."),
    0x6F2F: dict(name="Плёнка топлива: поправка осаждения по ТОЖ", group="Топливо: плёнка", confidence="likely", **TEMP),
    0x7CD7: dict(name="Плёнка топлива: коэффициент при сбросе нагрузки", group="Топливо: плёнка", confidence="likely",
                 rows=1, cols=32, xAxis="load32",
                 notes="Применяется, когда плёнка уменьшается (счётчик F8B1)."),
    0x60BC: dict(name="Напряжение бортсети: смещение АЦП", group="Датчики", confidence="likely"),
    0x60BD: dict(name="Напряжение бортсети: коэффициент АЦП", group="Датчики", confidence="likely"),

    # Warm-up enrichment: F97F = 0x80 + (7F67[ТОЖ] − 0x80)·8193[ДЗ×обороты]/256; подача × F97F/128
    0x7F67: dict(name="Обогащение при прогреве по ТОЖ", group="Топливо: прогрев", confidence="likely", **TEMP,
                 scale=1 / 128, unit="×",
                 notes="Индекс F887 = (ТОЖ+40)/5 с дробью F888 (A611). 1,0 = без обогащения. "
                       "Таблица из 39 точек; 7F75 — отдельная ссылка на её хвост."),
    0x7F75: dict(name="Обогащение при прогреве: хвост 7F67 (с +30 °C)", group="Топливо: прогрев", confidence="likely",
                 rows=1, cols=25, scale=1 / 128, unit="×", notes="Те же байты, что 7F67[14…38]."),
    0x8193: dict(name="Обогащение при прогреве: вес по ДЗ × оборотам", group="Топливо: прогрев", confidence="likely",
                 rows=16, cols=16, xAxis="rpm16", yAxis="throttle16", scale=1 / 256, unit="×",
                 notes="Ячейка без интерполяции: строка (7208[ДЗ]+8)>>4, столбец 59h. 0 — прогревное обогащение не действует."),

    # Acceleration enrichment (0x1800–0x1970): прирост наполнения по ДЗ → F97B (добавка к подаче)
    0x75EF: dict(name="Наполнение по ДЗ для обогащения при ускорении", group="Топливо: ускорение", confidence="likely",
                 rows=16, cols=16, xAxis="rpm16", yAxis="throttle16",
                 notes="Результат → F8AB; прирост F8AB за цикл — основа обогащения при ускорении."),
    0x6054: dict(name="Ускорение: порог прироста наполнения", group="Топливо: ускорение", confidence="likely"),
    0x8393: dict(name="Ускорение: коэффициент обогащения по ТОЖ", group="Топливо: ускорение", confidence="likely", **TEMP,
                 notes="Добавка = прирост F8AB × коэффициент → F97D, затем F97B."),
    0x5F6B: dict(name="Ускорение: затухание добавки (1)", group="Топливо: ускорение", confidence="likely",
                 scale=1 / 256, unit="×"),
    0x5F6C: dict(name="Ускорение: затухание добавки (2)", group="Топливо: ускорение", confidence="likely",
                 scale=1 / 256, unit="×"),
    0x5F74: dict(name="Сброс газа: порог уменьшения наполнения", group="Топливо: ускорение", confidence="auto"),
    0x5F73: dict(name="Сброс газа: коэффициент обеднения", group="Топливо: ускорение", confidence="auto"),
    0x5F75: dict(name="Сброс газа: затухание обеднения (1)", group="Топливо: ускорение", confidence="auto",
                 scale=1 / 256, unit="×"),
    0x5F76: dict(name="Сброс газа: затухание обеднения (2)", group="Топливо: ускорение", confidence="auto",
                 scale=1 / 256, unit="×"),
    0x726D: dict(name="ЦН по ДЗ в аварийном режиме ДМРВ", group="Наполнение", confidence="confirmed",
                 rows=16, cols=16, xAxis="rpm16", yAxis="throttle16",
                 notes="Код 0x1655: если стоит флаг ДМРВ (23h.6/24h.6), а ДПДЗ исправен — наполнение берётся отсюда по оборотам и ДЗ. "
                       "Совпадает с XDF I205DO54 («Аварийный режим ДМРВ: ЦН»)."),

    # Forced idle / overrun fuel cut (0x4440–0x4620): режимы 6Bh, бит 2Bh.3 — блокировка подачи
    0x607B: dict(name="ПХХ: порог скорости автомобиля", group="Ограничения", confidence="auto", unit="км/ч",
                 notes="Сравнивается со скоростью F8AE при входе/выходе из принудительного ХХ."),
    0x60E9: dict(name="ПХХ: порог оборотов", group="Ограничения", confidence="auto", scale=30, unit="об/мин"),
    0x60EA: dict(name="ПХХ: порог оборотов (2)", group="Ограничения", confidence="auto", scale=30, unit="об/мин"),
    0x608E: dict(name="ПХХ: задержка входа (циклов)", group="Ограничения", confidence="auto"),
    0x6FC4: dict(name="УОЗ на ПХХ по оборотам", group="Зажигание", confidence="likely",
                 rows=1, cols=32, xAxis="rpm32", **IGN, notes="Результат → 62h в режимах ПХХ (6Bh = 2/4)."),

    # Sensor failure
    0x7DF7: dict(name="Замещающая ТОЖ при неисправности датчика", group="Датчики", confidence="likely",
                 rows=1, cols=16, offset=-40, unit="°C",
                 notes="При флагах 23h.3/24h.3 (по протоколу — низкий/высокий сигнал ДТОЖ) ТОЖ берётся отсюда по таймеру F8AC>>4: модель прогрева от 20 до 95 °C."),

    # Ignition coil
    0x71C8: dict(name="Время накопления катушки по напряжению", group="Зажигание", confidence="likely", **VOLT,
                 notes="Умножается на обороты и переводится в угол накопления (F800)."),

    # Throttle-based map
    0x7E07: dict(name="Карта обороты × ДЗ (вероятно, наполнение по ДЗ)", group="Наполнение", confidence="auto",
                 rows=16, cols=16, xAxis="rpm16", yAxis="throttle16",
                 notes="Строки — индекс 7208[ДЗ]. Похоже на резервный расчёт наполнения по дросселю; не проверено."),

    # Limits
    0x605C: dict(name="Обороты отсечки", group="Ограничения", confidence="likely", scale=30, unit="об/мин",
                 notes="При оборотах ≥ значения обнуляется F987 (вероятно, подача топлива)."),
}
FORCE_MAP = {0x6AC8, 0x6BC8}  # loaded into DPTR before a JNB that picks one of them, then A59D

# ---------------------------------------------------------------------------
# Finding code and grids in any serial J5 version (the code moves between versions)

# Procedure bodies without absolute addresses (J5V05L19: A575, A59D, A611). The 2D body also
# starts the XRAM variant (A62F), told apart by `mov a,r4; movc` (EC 93) vs `mov dpl,a; movx`.
SIG_INTERP1 = bytes.fromhex("eac423541ffbeac42354e0fa7003")
SIG_INTERP2 = bytes.fromhex("eb54f0f5f0ea54f0c425f0fcea540ffaeb540ffb")
SIG_INTERPT = bytes.fromhex("ea93f8ea0493c398400a")

# Kinds that pin a table's shape; anything else ("unknown", "map?", "line?") is ambiguous.
DEFINITE = {"map", "mapThr", "mapNearest", "rpm32", "load32", "temp", "rpmRaw", "scalar"}
PRIORITY = ["map", "mapThr", "mapNearest", "rpm32", "load32", "temp", "rpmRaw", "map?", "scalar", "line?", "unknown"]
FIELD_ORDER = ["id", "name", "group", "address", "rows", "cols", "xAxis", "yAxis",
               "scale", "offset", "reciprocal", "mask", "unit", "dataType", "confidence", "notes", "access"]
SHAPES = {
    "map": dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16", kind="Карта 16×16 (обороты × нагрузка)"),
    "mapThr": dict(rows=16, cols=16, xAxis="rpm16", yAxis="throttle16", kind="Карта 16×16 (обороты × ДЗ)"),
    "mapNearest": dict(rows=16, cols=16, xAxis="rpm16", yAxis="load16", kind="Карта 16×16 без интерполяции"),
    "map?": dict(rows=16, cols=16, xAxis="rpm16", kind="Карта 16×16 (ось строк не определена)"),
    "rpm32": dict(rows=1, cols=32, xAxis="rpm32", kind="Кривая по оборотам"),
    "load32": dict(rows=1, cols=32, xAxis="load32", kind="Кривая по нагрузке"),
    "temp": dict(rows=1, cols=39, xAxis="temp", kind="Кривая по температуре ОЖ"),
    "rpmRaw": dict(rows=1, cols=256, xAxis="rpmRaw", kind="Кривая по оборотам (256 точек)"),
    "scalar": dict(rows=1, cols=1, kind="Константа"),
}
# Where the firmware stores a lookup result says what the table is (RAM meanings: KWP frame).
DESTINATIONS = {
    0x62: dict(what="УОЗ", group="Зажигание", scale=0.5, unit="°"),
    0x60: dict(what="Состав смеси", group="Топливо", **AFR),
    0x6F: dict(what="Коэффициент коррекции впрыска", group="Топливо", **COEF),
}
# KNOWN entries describing grids: applied wherever the grid is in this version.
GRID_ROLES = {"rpm": 0x613C, "throttle": 0x7208, "loadOffset": 0x6064, "loadOffsetHigh": 0x6065, "loadGain": 0x6066}


def find_procs(a):
    procs = {"interp1": set(), "interp2": set(), "interpT": set()}
    for name, sig in (("interp1", SIG_INTERP1), ("interpT", SIG_INTERPT)):
        procs[name] = {m.start() for m in re.finditer(re.escape(sig), a)}
    for m in re.finditer(re.escape(SIG_INTERP2), a):
        if b"\xec\x93" in a[m.start() + 20:m.start() + 30]:  # `mov a,r4; movc`: table in ROM (XRAM one: movx)
            procs["interp2"].add(m.start())
    return procs


def call_at(a, p):
    """(target, length) of an LCALL or ACALL at p."""
    if p + 2 < len(a) and a[p] == 0x12:
        return a[p + 1] << 8 | a[p + 2], 3
    if p + 1 < len(a) and a[p] & 0x1F == 0x11:
        return ((p + 2) & 0xF800) | (a[p] >> 5) << 8 | a[p + 1], 2
    return None


def classify(a, i, procs):
    """Kind of access to the table loaded by `mov dptr,#t` at i, and where the result goes."""
    regs = {}
    # Registers set before the DPTR load: `mov r2/r3,direct`, or r3 = throttle grid index
    # (`mov a,52h|B; movc; mov r3,a` right before).
    k = i
    for _ in range(3):
        if k >= 4 and a[k - 1] == 0xFB and a[k - 4:k - 1] in (b"\xe5\x52\x93", b"\xe5\xf0\x93"):
            regs.setdefault(3, "thr")
            k -= 4
        elif k >= 2 and a[k - 2] in (0xAA, 0xAB):
            regs.setdefault(a[k - 2] - 0xA8, a[k - 1])
            k -= 2
        else:
            break
    j = i + 3
    while a[j] in (0xAA, 0xAB):
        regs[a[j] - 0xA8] = a[j + 1]
        j += 2
    call = call_at(a, j)
    dest = None
    if call:
        target, length = call
        e = j + length
        if a[e] == 0xF5:
            dest = a[e + 1]
        elif a[e + 2] == 0xF5:
            dest = a[e + 3]
        if target in procs["interp2"]:
            r2, r3 = regs.get(2), regs.get(3)
            if r2 == 0x57 and r3 == 0x5C:
                return "map", dest
            if r2 == 0x57 and r3 == "thr":
                return "mapThr", dest
            return "map?", dest
        if target in procs["interp1"]:
            return {0x57: "rpm32", 0x5C: "load32"}.get(regs.get(2), "line?"), dest
        if target in procs["interpT"]:
            return "temp", dest
    n = a[i + 3:i + 6]
    if n[0] == 0xE5 and n[2] == 0x93:
        return {0x5F: "mapNearest", 0x58: "rpm32", 0x5D: "load32", 0x4E: "temp", 0x54: "rpmRaw"}.get(n[1], "line?"), None
    if n[0] == 0xE4 and n[1] == 0x93:
        return "scalar", None
    return "unknown", None


def monotone_grid(a, addr, length):
    t = a[addr:addr + length]
    return len(t) == length and all(x <= y for x, y in zip(t, t[1:])) and 0xE0 <= t[-1] <= 0xF0


def find_grids(a):
    """Grid tables as the code reads them: RPM table by 54h (rpm/30), throttle table by 52h (%),
    load = ((ЦН·6 − word) >> 3) · gain (J5V05L19: 613C, 7208, 6064/6066; J5V07I27: 613C, 720A, 60BD/60BA)."""
    grids = {}
    for m in re.finditer(rb"\x90(..)\xe5\x54\x93", a, re.S):
        t = m.group(1)[0] << 8 | m.group(1)[1]
        if monotone_grid(a, t, 256):
            grids["rpm"] = t
            break
    for m in re.finditer(rb"\x90(..)\xe5\x52\x93", a, re.S):
        t = m.group(1)[0] << 8 | m.group(1)[1]
        if monotone_grid(a, t, 101):
            grids["throttle"] = t
            break
    m = re.search(rb"\x90(..)\xe4\x93\xfa\x90(..)\xe4\x93\xfb.{3,4}\xe4\x40.\x90(..)\xe4\x93\xf5\xf0", a, re.S)
    if m:
        grids["loadOffset"] = m.group(1)[0] << 8 | m.group(1)[1]
        grids["loadOffsetHigh"] = m.group(2)[0] << 8 | m.group(2)[1]
        grids["loadGain"] = m.group(3)[0] << 8 | m.group(3)[1]
    return grids


def software_id(a):
    """ID from the diagnostic identification record (as Firmware.softwareID for J5):
    "1411010-xx", engine, date, ID; J5V26K23 stores them as `5A` frames with a checksum byte."""
    start = a.find(b"1411010-")
    if start < 0:
        return a[0x6020:0x6028].decode("latin1").rstrip("\0")
    fields = []
    for m in re.finditer(rb"[\x20-\x7e]{3,}", a[start:start + 64]):
        text, h = m.group(), start + m.start() - 5
        if h >= 0 and a[h] & 0xC0 == 0x80 and a[h + 1:h + 4] == b"\xf1\x10\x5a":
            text = text[:(a[h] & 0x3F) - 2]
        fields.append(text.decode("latin1"))
    return fields[3] if len(fields) > 3 else a[0x6020:0x6028].decode("latin1").rstrip("\0")


def known_kinds(known):
    """Access kinds a KNOWN description is compatible with."""
    if "rows" not in known:
        return {"scalar"}
    if known["rows"] == 16:
        return {"mapThr"} if known.get("yAxis") == "throttle16" else {"map", "mapNearest"}
    return {"temp": {"temp"}, "rpm32": {"rpm32"}, "load32": {"load32"}, "rpmRaw": {"rpmRaw"}}.get(
        known.get("xAxis"), {"rpm32", "load32", "temp", "rpmRaw", "line?"})


# ADC routine: `mov dptr,#T; movc a,@a+dptr; clr c; clr EA; add a,30h` — the MAF code from ADDAT
# indexes a 256-word table, low bytes at T, high bytes at T+100h; the mean of the sum in 30h/31h
# goes to F808 (air flow, E/10 kg/h in the 21 01 frame). docs/j5-reverse-notes.md, «Таблица ДМРВ».
SIG_MAF = bytes.fromhex("93c3c2af2530")


def find_maf(a):
    """Address of the MAF table, or None (MAP-sensor builds have none)."""
    i = a.find(SIG_MAF)
    return a[i - 2] << 8 | a[i - 1] if i >= 3 and a[i - 3] == 0x90 else None


def maf_table(addr):
    return {"id": f"t{addr:04X}", "name": "Характеристика ДМРВ: напряжение → расход воздуха", "group": "Датчики",
            "address": f"0x{addr:04X}", "rows": 1, "cols": 256, "xAxis": "adc256", "scale": 0.1, "unit": "кг/ч",
            "dataType": "u16split", "confidence": "likely",
            "notes": "Код АЦП ДМРВ (старшие 8 бит) → расход ×10 кг/ч: младшие байты по адресу таблицы, старшие — "
                     "на 100h дальше. Процедура опроса АЦП суммирует значения, среднее пишется в F808 (расход "
                     "воздуха в кадре диагностики). Ось — напряжение при опорном 5 В. Найдена по тюнинговым "
                     "G26 «тарировки Сименс», где заменён только этот блок."}


# Disputed points between the CTP maps and our L19 description, settled by J5V05L19 code
# (docs/ctp-maps.md, «Сверка с кодом»). Added to the notes of builds with the L19 layout.
IGNITION_NOTE = ("Проверено по коду J5V05L19: итоговый УОЗ (62h) знаковый — ограничение A325 и сравнение "
                 "через +80h. Но интерполятор A59D беззнаковый: соседние ячейки не должны переходить через "
                 "0° (−0,5 и +0,5° дадут между ними около −64°).")
CODE_NOTES = {
    **{addr: IGNITION_NOTE for addr in (0x6AC8, 0x6BC8, 0x6CC8, 0x6DC8, 0x7877)},
    0x76EF: "Проверено по коду J5V05L19 (0x291F): 256 байт прибавляются со знаком к таблице обучения FD00, "
            "сумма — в FE00. Таблица 16×16 со знаком, как в карте CTP (прежнее «константа» было неверно).",
    0x7E07: "Проверено по коду J5V05L19 (0x3FC4): (E+128)/256 умножается на 4Fh, результат (не больше FEh−42h) — "
            "порог детонации F937. Оси обороты × ДЗ.",
    0x63D3: "Проверено по коду J5V05L19 (0x3F67): ячейка без интерполяции — ДЗ (7208[52h], округлено до 16) + 59h.",
    **{addr: "Проверено по коду J5V05L19: читается напрямую по индексу ТОЖ 4Eh (0…36), то есть используются "
             "37 точек (−40…140 °C); две последние точки карты CTP (145, 150 °C) код не читает."
       for addr in (0x6FE4, 0x9992, 0x928A)},
}

# J5V07I27/J28 moved their calibrations; no CTP map for them is at hand (the ChipTuningPRO 7
# installer has J5V07I27.j5, encrypted). Names come from J5V07G26 instead, by the code around
# each table reference: the same 10 (or 6) bytes before and after `mov dptr,#X` in both builds
# point to the same table. Taken only when the match is unique and the data look alike.
CONTEXT_DONOR = "j5/j5v07g26/J5V07G26.BIN"


def code_refs(a):
    """Table address -> reference sites (`mov dptr,#X` in code)."""
    out = {}
    for i in range(len(a) - 3):
        if a[i] == 0x90 and not CAL_START - 0x100 <= i < 0xA700:
            t = a[i + 1] << 8 | a[i + 2]
            if CAL_START - 0x100 <= t < 0xA700:
                out.setdefault(t, []).append(i)
    return out


def match_by_context(donor, a):
    """{our address: donor address} for references whose surrounding code is the same."""
    index = {}
    for t, sites in code_refs(donor).items():
        for s in sites:
            for n in (10, 6):
                index.setdefault((n, donor[s - n:s], donor[s + 3:s + 3 + n]), set()).add(t)
    mapping = {}
    for t, sites in code_refs(a).items():
        votes = {}
        for s in sites:
            for n in (10, 6):
                hit = index.get((n, a[s - n:s], a[s + 3:s + 3 + n]))
                if hit and len(hit) == 1:
                    d = next(iter(hit))
                    votes[d] = votes.get(d, 0) + 1
                    break
        if votes:
            mapping[t] = max(votes, key=votes.get)
    taken = {}
    for t, d in mapping.items():
        taken.setdefault(d, []).append(t)
    result = {}
    for d, ts in taken.items():
        if len(ts) > 1:
            # Several of our tables claim one donor table: the one starting with the same byte wins.
            ts = [t for t in ts if a[t] == donor[d]]
        if len(ts) == 1:
            result[ts[0]] = d
    return result


def apply_context_names(a, tables, axes, donor, donor_def):
    """Names from the donor build where code context and data agree; returns the count."""
    donor_tables = {int(t["address"], 16): t for t in donor_def["tables"] if t["confidence"] != "auto"}
    ours = {int(t["address"], 16): t for t in tables}
    named = 0
    for addr, d_addr in match_by_context(donor, a).items():
        src = donor_tables.get(d_addr)
        if not src:
            continue
        size = src["rows"] * src["cols"] * (2 if src.get("dataType", "u8").startswith("u16") else 1)
        x, y = donor[d_addr:d_addr + size], a[addr:addr + size]
        similar = len(y) == size and (sum(p == q for p, q in zip(x, y)) >= size / 2
                                      or sum(abs(p - q) for p, q in zip(x, y)) <= 8 * size)
        t = ours.get(addr)
        if not similar:
            if t is not None and t["confidence"] == "auto":
                t["notes"] = (t.get("notes", "") + f" Возможно, «{src['name']}» (код вокруг ссылки как у "
                              f"J5V07G26 @{d_addr:04X}, но данные заметно отличаются).").strip()
            continue
        if t is None:
            t = {"id": f"t{addr:04X}", "address": f"0x{addr:04X}"}
            tables.append(t)
            ours[addr] = t
        elif t["confidence"] != "auto":
            continue  # a grid or a name from the code's destination stays
        for k in ("xAxis", "yAxis", "scale", "offset", "reciprocal", "mask", "unit", "dataType"):
            t.pop(k, None)
        t.update({k: v for k, v in src.items() if k not in ("id", "address", "confidence", "notes", "access")})
        for key in ("xAxis", "yAxis"):
            if t.get(key) and t[key] not in axes:
                if t[key] in donor_def["axes"] and donor_def["axes"][t[key]]["kind"] == "linear":
                    axes[t[key]] = donor_def["axes"][t[key]]
                else:
                    del t[key]
        t["confidence"] = "likely" if src["confidence"] != "auto" else "auto"
        t["notes"] = (f"По совпадению кода с J5V07G26 @{d_addr:04X} (данные похожи). "
                      + (src.get("notes") or "")).strip()
        named += 1
    tables.sort(key=lambda t: (int(t["address"], 16), t["id"]))
    return named


def drop_overlaps(tables):
    """Generic tables that run into a named one are the named table's bytes misread."""
    def span(t):
        start = int(t["address"], 16)
        return start, start + t["rows"] * t["cols"] * (2 if t.get("dataType", "u8").startswith("u16") else 1)
    named = [span(t) for t in tables if t["confidence"] != "auto"]
    keep = []
    for t in tables:
        s, e = span(t)
        if t["confidence"] == "auto" and any(s < ne and ns < e and (s, e) != (ns, ne) for ns, ne in named):
            continue
        keep.append(t)
    return keep


def generate(a, reference=False, donor=None):
    """Definition dict for one image. `reference`: the image KNOWN was written from (J5V05L19).
    `donor`: (image, definition) of J5V07G26 for builds whose layout differs from L19."""
    sid = software_id(a)
    procs = find_procs(a)
    grids = find_grids(a)
    grid_at = {addr: role for role, addr in grids.items()}
    refs, dests = {}, {}
    for i in range(len(a) - 12):
        if a[i] != 0x90:
            continue
        t = a[i + 1] << 8 | a[i + 2]
        if CAL_START <= t < CAL_END:
            kind, dest = classify(a, i, procs)
            refs.setdefault(t, set()).add(kind)
            if dest is not None:
                dests.setdefault(t, set()).add(dest)
    for addr in grids.values():
        refs.setdefault(addr, {"scalar"})
    # Names by address carry over only to builds with the L19 calibration layout (grids at the
    # same places). J5V07I27/J28 moved their grids, so their constants may mean anything there.
    l19_layout = all(grids.get(role) == addr for role, addr in GRID_ROLES.items())
    if reference:
        for addr in KNOWN:
            refs.setdefault(addr, {"scalar"})

    addrs = sorted(refs)
    tables = []
    for idx, addr in enumerate(addrs):
        gap = (addrs[idx + 1] if idx + 1 < len(addrs) else CAL_END) - addr
        kinds = sorted(refs[addr], key=lambda k: PRIORITY.index(k) if k in PRIORITY else 99)
        kind = "map" if reference and addr in FORCE_MAP else kinds[0]
        # KNOWN: grids by role; everything else by address, if this version reads it the same way.
        known = None
        if addr in grid_at:
            known = KNOWN[GRID_ROLES[grid_at[addr]]]
        elif addr in KNOWN and addr not in GRID_ROLES.values() and (reference or l19_layout):
            definite = refs[addr] & DEFINITE
            if reference or (definite & known_kinds(KNOWN[addr])) or not definite:
                known = KNOWN[addr]
        if kind not in SHAPES and not known:
            continue
        shape = dict(SHAPES.get(kind, SHAPES["scalar"]))
        label = shape.pop("kind")
        if shape["rows"] == 1:
            shape["cols"] = min(shape["cols"], gap)  # curves never run into the next referenced table
        t = {"id": f"t{addr:04X}", "address": f"0x{addr:04X}", "confidence": "auto", **shape}
        if kind == "scalar":
            t.update(name=f"Константа @{addr:04X}", group="Константы")
        else:
            t.update(name=f"{label} @{addr:04X}", group="Не определено: " + label)
            dest = next(iter(dests[addr])) if len(dests.get(addr, ())) == 1 else None
            if dest in DESTINATIONS:
                d = DESTINATIONS[dest]
                t.update(name=f"{d['what']}: {label.lower()} @{addr:04X}", group=d["group"],
                         **{k: v for k, v in d.items() if k not in ("what", "group")},
                         notes=f"Назначение — по месту записи результата ({dest:02X}h), не проверено.")
        if known:
            if "rows" in known:
                t.pop("xAxis", None)
                t.pop("yAxis", None)
            t.pop("notes", None)  # the automatic destination note gives way to the known description
            t.update(known)
            if not reference:
                if t["confidence"] == "confirmed":
                    t["confidence"] = "likely"
                t["notes"] = (t.get("notes", "") + " По аналогии с J5V05L19: тот же адрес"
                              + (" и вид доступа в коде." if refs[addr] & DEFINITE else ".")).strip()
        if len(refs[addr]) > 1:
            t["access"] = sorted(refs[addr])
        tables.append({k: t[k] for k in FIELD_ORDER if k in t})

    axes = {
        "rpmRaw": {"kind": "linear", "start": 0, "step": 30, "points": 256, "unit": "об/мин"},
        "throttleRaw": {"kind": "linear", "start": 0, "step": 1, "points": 101, "unit": "% ДЗ"},
        "temp": {"kind": "linear", "start": -40, "step": 5, "points": 39, "unit": "°C"},
        "voltage16": {"kind": "linear", "start": 5.2, "step": 0.8, "points": 16, "unit": "В"},
        "startCycles": {"kind": "linear", "start": 0, "step": 8, "points": 32, "unit": "циклов"},
    }
    if "rpm" in grids:
        for n, step in ((16, 16), (32, 8)):
            axes[f"rpm{n}"] = {"kind": "inverseLookup", "address": f"0x{grids['rpm']:04X}", "length": 256,
                               "points": n, "step": step, "scale": 30, "unit": "об/мин"}
    if "loadOffset" in grids:
        for n, step in ((16, 16), (32, 8)):
            axes[f"load{n}"] = {"kind": "j5Load", "offsetAddress": f"0x{grids['loadOffset']:04X}",
                                "gainAddress": f"0x{grids['loadGain']:04X}", "divisor": 6,
                                "points": n, "step": step, "unit": "мг/такт"}
    if "throttle" in grids:
        axes["throttle16"] = {"kind": "inverseLookup", "address": f"0x{grids['throttle']:04X}", "length": 101,
                              "points": 16, "step": 16, "scale": 1, "unit": "% ДЗ"}
    ctp_added = apply_ctp(sid, tables, axes, refs) if l19_layout else 0
    context_named = 0
    if not l19_layout and donor is not None:
        context_named = apply_context_names(a, tables, axes, *donor)
        tables = drop_overlaps(tables)
    if l19_layout:
        for t in tables:
            note = CODE_NOTES.get(int(t["address"], 16))
            if note and note not in (t.get("notes") or ""):
                t["notes"] = ((t.get("notes") or "") + " " + note).strip()
    maf = find_maf(a)
    if maf is not None:
        # Generic shapes that run into the table's two pages are its own bytes misread.
        def overlaps(t):
            start = int(t["address"], 16)
            size = t["rows"] * t["cols"] * (2 if t.get("dataType", "u8").startswith("u16") else 1)
            return start < maf + 512 and maf < start + size
        dropped = [t["id"] for t in tables if overlaps(t)]
        if dropped:
            print(f"{sid}: таблица ДМРВ {maf:04X} перекрывает {', '.join(dropped)} — убраны")
        tables = [t for t in tables if not overlaps(t)] + [maf_table(maf)]
        tables.sort(key=lambda t: (int(t["address"], 16), t["id"]))
        axes["adc256"] = {"kind": "linear", "start": 0, "step": 0.01955, "points": 256, "unit": "В"}
    tables = [{k: t[k] for k in FIELD_ORDER if k in t} for t in tables]
    for t in tables:  # an axis this version doesn't have is dropped rather than pointing nowhere
        for key in ("xAxis", "yAxis"):
            if t.get(key) and t[key] not in axes:
                del t[key]
    found = ", ".join(f"{k} {'/'.join(f'{x:04X}' for x in sorted(v))}" for k, v in procs.items() if v)
    note = "" if reference else (
        (" Имена — по аналогии с J5V05L19 (тот же адрес и вид доступа) или по месту записи результата"
         if l19_layout else " Раскладка калибровок отличается от J5V05L19 (сетки в других местах): имена — только "
                            "сеткам и по месту записи результата") + "; всё с confidence=auto не проверено.")
    if context_named:
        note += (f" Имена {context_named} таблиц перенесены с J5V07G26 по совпадению кода вокруг ссылки "
                 "и похожим данным (confidence=likely); карты CTP для этой сборки нет.")
    if l19_layout:
        note += (" Названия, единицы и пересчёт остальных таблиц — из карт ChipTuningPRO серийных J5V05N35/J5V03K22 "
                 f"(confidence=likely; {ctp_added} таблиц, которые код читает непонятным генератору способом, добавлено по карте).")
    # Several builds share one ID with different code (J5V05J16 and its HIP9011 build, K17 and
    # K17a): the app takes a definition only where these procedure bytes are in place.
    check = [{"address": f"0x{min(procs[role]):04X}", "bytes": sig[:8].hex().upper()}
             for role, sig in (("interp1", SIG_INTERP1), ("interp2", SIG_INTERP2), ("interpT", SIG_INTERPT))
             if procs[role]]
    return {
        "softwareIDs": [sid],
        "family": "J5.1",
        "check": check,
        "source": f"Сгенерировано tools/gen_j5_definitions.py из {sid} (процедуры: {found}; сетки: "
                  + ", ".join(f"{k} {v:04X}" for k, v in sorted(grids.items())) + ")." + note,
        "axes": axes,
        "tables": tables,
    }


# ---------------------------------------------------------------------------
# Names from ChipTuningPRO maps of two serial builds (docs/ctp-maps.md): the calibration
# layout is shared by the family, so they name most tables of every build with the L19 layout.

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CTP_MAPS = [("J5V05N35", "firmware/maps/J5V05N35.j5"), ("J5V03K22", "firmware/maps/J5v03k22.j5")]
_ctp_cache = {}


def ctp_entries(sid):
    """address -> (entry, map ID) from both maps; the map of the closer line wins."""
    order = CTP_MAPS[::-1] if sid.startswith(("J5V03", "A5_03")) else CTP_MAPS
    merged = {}
    for map_id, path in order:
        if path not in _ctp_cache:
            _ctp_cache[path] = ctp_map.with_groups(ctp_map.parse(os.path.join(ROOT, path)))
        for e in _ctp_cache[path]:
            if e["type"] in (1, 2, 3) and CAL_START - 0x100 <= e["address"] < CAL_END:
                merged.setdefault(e["address"], []).append((e, map_id))
            elif e["type"] == 4:
                merged.setdefault(("flags", e["name"]), []).append((e, map_id))
    return merged


def ctp_axis(table, points, start, end, unit, axes):
    """Our axis key for a CTP axis source, adding linear axes as needed."""
    n = max(points, 1)
    if table.startswith("!") and "-613C" in table:
        return f"rpm{n}" if n in (16, 32) else None
    if table.startswith("!") and "-6064" in table:
        return f"load{n}" if n in (16, 32) else None
    if table.startswith("!") and "-7208" in table:
        return "throttle16" if n == 16 else None
    if table:
        return None  # e.g. the MAF grid !005-5F84: formula unknown
    if n == 39 and start == -40 and end == 150:
        return "temp"
    if n == 256 and start == 0 and end == 7650:
        return "rpmRaw"
    step = (end - start) / (n - 1) if n > 1 else 0
    key = f"lin{n}_{start:g}_{end:g}"
    axes.setdefault(key, {"kind": "linear", "start": start, "step": step, "points": n, "unit": unit or None})
    if axes[key]["unit"] is None:
        del axes[key]["unit"]
    return key


def ctp_scale(e):
    """(fields) for our TableDefinition from a CTP conversion and type, or None if unsupported."""
    dtype = {0: None, 1: "s8", 2: "u16le"}.get(e.get("constType"), "skip")
    if dtype == "skip":
        return None
    c = e["conversion"]
    div = c["div"] or 1
    out = {}
    if c["inv"]:
        out["reciprocal"] = c["inv"] / div
    else:
        scale = c["step"] / div
        offset = -c["off1"] * scale - c["off2"]
        if scale != 1:
            out["scale"] = scale
        if offset:
            out["offset"] = offset
    if dtype:
        out["dataType"] = dtype
    mask = e.get("shiftMask", 0xFFFF)
    if mask not in (0, 0xFFFF):
        out["mask"] = mask
    return out


def apply_ctp(sid, tables, axes, refs):
    """Names, units, scales and shapes from the CTP maps (see the module comment above).
    Entries the generated description lacks are added only where this build's code reads the
    address (`refs`): an older build may not have a function the 2002–2004 maps describe."""
    by_addr = {}
    for t in tables:
        by_addr.setdefault(int(t["address"], 16), []).append(t)
    used = {t["id"] for t in tables}
    added = 0
    for key, found in ctp_entries(sid).items():
        if isinstance(key, tuple):  # configuration flag bytes -> one 0/1 entry per named bit
            e, map_id = found[0]
            for i, address in enumerate(e["flagAddresses"]):
                if address is None or not CAL_START - 0x100 <= address < CAL_END or address not in refs:
                    continue
                for bit, name in enumerate(e["bitNames"][i]):
                    tid = f"f{address:04X}.{bit}"
                    if name and tid not in used:
                        used.add(tid)
                        group = " / ".join(x for x in (e["group"], e["name"], e["itemNames"][i]) if x and x != "Общие")
                        tables.append({"id": tid, "name": name, "group": group, "address": f"0x{address:04X}",
                                       "rows": 1, "cols": 1, "unit": "0/1", "mask": 1 << bit, "confidence": "likely",
                                       "notes": f"По карте CTP {map_id}: байт {address:04X}, бит {bit}."})
            continue
        # The preferred map's entries for this address (two when bit fields share a byte, like 63D3).
        for n, (e, map_id) in enumerate(f for f in found if f[1] == found[0][1]):
            fields = ctp_scale(e)
            if fields is None:
                continue
            rows, cols = e["zPoints"], e["xPoints"]
            existing = [t for t in by_addr.get(key, []) if "mask" not in t or t.get("mask") == fields.get("mask")]
            t = existing[0] if existing and n == 0 else None
            note = f"По карте CTP {map_id}: «{e['name']}»."
            if t and t["confidence"] != "auto":
                # Traced in L19 code: our name, shape and scale stay; signedness from CTP if the scale agrees.
                if fields.get("dataType") == "s8" and "dataType" not in t and t.get("scale", 1) == fields.get("scale", 1):
                    t["dataType"] = "s8"
                t["notes"] = (t.get("notes", "") + " В карте CTP " + map_id + ": «" + e["name"] + "».").strip()
                continue
            if t:
                same = (t["rows"], t["cols"]) == (rows, cols)
                curve = t["rows"] == 1 and rows == 1 and t["cols"] > 1
                scalar = t["rows"] == 1 and t["cols"] == 1
                if not (same or curve or scalar):
                    t["notes"] = (t.get("notes", "") + f" В карте CTP {map_id} по этому адресу «{e['name']}» "
                                  f"{rows}×{cols} — форма не совпадает, не перенесено.").strip()
                    continue
                for k in ("scale", "offset", "reciprocal", "dataType", "mask", "xAxis", "yAxis", "unit"):
                    t.pop(k, None)
            elif key not in refs:
                continue
            else:
                tid = f"t{key:04X}" if f"t{key:04X}" not in used else f"t{key:04X}_{n + 2}"
                used.add(tid)
                t = {"id": tid, "address": f"0x{key:04X}"}
                tables.append(t)
                added += 1
                note = (f"По карте CTP {map_id}: «{e['name']}». Код этой сборки читает адрес, но вид доступа "
                        "генератор не распознал — форма из карты, не проверено.")
            t.update(name=e["name"], group=e["group"], rows=rows, cols=cols, confidence="likely", notes=note)
            if e.get("units"):
                t["unit"] = e["units"]
            if e["type"] in (1, 2):
                x = ctp_axis(e["xTable"], cols, e["xStart"], e["xEnd"], e["xUnits"], axes)
                if x:
                    t["xAxis"] = x
            if e["type"] == 2:
                y = ctp_axis(e["zTable"], rows, e["zStart"], e["zEnd"], e["zUnits"], axes)
                if y:
                    t["yAxis"] = y
            t.update(fields)
    tables.sort(key=lambda t: (int(t["address"], 16), t["id"]))
    return added


def write(definition, out):
    with open(out, "w", encoding="utf-8") as f:
        json.dump(definition, f, ensure_ascii=False, indent=2)
    tables = definition["tables"]
    named = sum(t["confidence"] != "auto" for t in tables)
    print(f"{definition['softwareIDs'][0]}: {len(tables)} tables ({named} named) -> {out}")


def main(argv):
    if argv[:1] == ["--all"]:
        # Every raw J5 ROM in firmware/catalog.json; the first file of each software ID wins
        # (catalog order lists the original before "КС откл." variants).
        root = os.path.join(os.path.dirname(__file__), "..")
        out_dir = argv[1] if len(argv) > 1 else os.path.join(root, "Sources/VazCore/Definitions")
        catalog = json.load(open(os.path.join(root, "firmware/catalog.json"), encoding="utf-8"))
        done = {}
        donor = load_donor(root)
        for entry in catalog:
            for f in entry["files"]:
                if not (f["path"].startswith("j5/") and f["kind"].startswith("ПЗУ")):
                    continue
                a = open(os.path.join(root, "firmware", f["path"]), "rb").read()
                sid = software_id(a)
                definition = generate(a, reference=sid == "J5V05L19", donor=donor)
                layout = (definition["check"], [(t["address"], t["rows"], t["cols"]) for t in definition["tables"]])
                same = next((p for p, l in done.get(sid, []) if l == layout), None)
                if same:
                    print(f"{sid}: {f['path']} — та же раскладка, что у {same}")
                    continue
                # Same ID, different build: its own file, chosen by the check bytes.
                stem = os.path.splitext(os.path.basename(f["path"]))[0].replace(" ", "_")
                name = sid if sid not in done else f"{sid}~{stem}"
                done.setdefault(sid, []).append((f["path"], layout))
                write(definition, os.path.join(out_dir, f"{name}.json"))
        return
    src, out = argv[0], argv[1]
    a = open(src, "rb").read()
    write(generate(a, reference=software_id(a) == "J5V05L19", donor=load_donor(ROOT)), out)


def load_donor(root):
    """J5V07G26 image and its generated definition, for builds with their own layout."""
    image = open(os.path.join(root, "firmware", CONTEXT_DONOR), "rb").read()
    return image, generate(image)


if __name__ == "__main__":
    main(sys.argv[1:])
