"""Reader for ChipTuningPRO calibration maps (.j5, header "CTM").

Same format as Sources/VazCore/CTPMap.swift (description: docs/ctp-maps.md): entries are
folders (0), curves (1), 3D tables (2), constants (3), flags (4) and identification (5);
the first address of an entry is XORed with 0x28A6FBB8 (format version 1 — not XORed).
"""
import struct

XOR = 0x28A6FBB8


class _Reader:
    def __init__(self, data, pos):
        self.d, self.p = data, pos

    def byte(self):
        self.p += 1
        return self.d[self.p - 1]

    def take(self, n):
        self.p += n
        return self.d[self.p - n:self.p]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def f64(self):
        return struct.unpack("<d", self.take(8))[0]

    def string(self, size=64):
        n = min(self.d[self.p], size)
        text = self.d[self.p + 1:self.p + 1 + n].decode("cp1251", "replace").strip()
        self.p += 1 + size
        return text


def parse(path):
    """List of entries (dicts): name, level, type, address, units, xUnits, zUnits, xTable,
    zTable, xPoints, zPoints, xStart, xEnd, zStart, zEnd, constType, shiftMask, conversion,
    flags (addresses, itemNames, bitNames)."""
    d = open(path, "rb").read()
    if d[:3] != b"CTM":
        raise ValueError(f"{path}: not a CTP map")
    version = d[3]
    olt = version == 1
    key, pad = (0, 4) if olt else (XOR, 8)
    r = _Reader(d, 22 + (35 if version == 7 else 0))
    entries = []
    while r.p < len(d):
        e = dict(name=r.string(), level=r.byte(), type=r.byte())
        length = r.u16()
        body = r.p
        t = e["type"]
        if t in (1, 2, 3):
            r.u32()
            e["address"] = r.u32() ^ key
            r.take(pad)
            if t == 3:
                e.update(units=r.string(16), lower=r.f64(), upper=r.f64(), constType=r.byte())
                r.byte()
                e.update(xPoints=1, zPoints=1)
            else:
                e["xUnits"] = r.string(32)
                e["units"] = r.string(32)
                if t == 2:
                    e["zUnits"] = r.string(32)
                e["xTable"] = r.string(255)
                if t == 2:
                    e["zTable"] = r.string(255)
                e["xPoints"] = r.u16()
                e["shiftMask"] = r.u16()
                e["zPoints"] = r.byte() if t == 2 else 1
                e["xStart"], e["xEnd"] = r.f64(), r.f64()
                r.byte()
                e["lower"], e["upper"] = r.f64(), r.f64()
                r.byte()
                if t == 2:
                    e["zStart"], e["zEnd"] = r.f64(), r.f64()
                    r.byte()
                    e["constType"] = r.byte()
                    r.take(4)
                else:
                    e["constType"] = r.byte()
                    r.take(3)
            e["conversion"] = dict(div=r.f64(), off2=r.f64(), inv=r.f64(), step=r.f64(), off1=r.f64())
        elif t == 4:
            r.u32()
            addrs = [r.u32() for _ in range(8)]
            addrs[0] ^= key
            r.take(pad)
            e["flagAddresses"] = [None if a == 0xFFFFFFFF else a & 0xFFFF for a in addrs]
            e["itemNames"] = [r.string() for _ in range(8)]
            e["bitNames"] = [[r.string() for _ in range(8)] for _ in range(8)]
        r.p = body + length
        entries.append(e)
    return entries


def with_groups(entries):
    """Entries with their folder path ("Пуск / Топливоподача"), folders dropped."""
    folders, out = [], []
    for e in entries:
        folders = folders[:max(e["level"] - 1, 0)]
        if e["type"] == 0:
            folders.append(e["name"])
        else:
            out.append(dict(e, group=" / ".join(folders) or "Общие"))
    return out
