#!/usr/bin/env python3
"""List or extend an ath12k board-2.bin.
  ath12k_bd.py list IN
  ath12k_bd.py add IN OUT NAME DATAFILE
"""
import struct, sys, hashlib
MAGIC = b"QCA-ATH12K-BOARD\0"
IE_BOARD, IE_REGDB = 0, 1
SUB_NAME, SUB_DATA = 0, 1

def pad4(b): return b + b"m" * (-len(b) % 4)

def parse(buf):
    assert buf.startswith(MAGIC), "bad magic"
    off = len(pad4(MAGIC)); ies = []
    while off < len(buf):
        ie_id, ie_len = struct.unpack_from("<II", buf, off); off += 8
        data = buf[off:off + ie_len]; off += ie_len + (-ie_len % 4)
        subs = []; so = 0
        while so < len(data):
            sid, slen = struct.unpack_from("<II", data, so); so += 8
            subs.append((sid, data[so:so + slen])); so += slen + (-slen % 4)
        ies.append((ie_id, subs))
    return ies

def build(ies):
    out = MAGIC + b"m" * (-len(MAGIC) % 4)
    for ie_id, subs in ies:
        body = b"".join(struct.pack("<II", sid, len(d)) + pad4(d) for sid, d in subs)
        out += struct.pack("<II", ie_id, len(body)) + body
    return out

cmd, src = sys.argv[1], sys.argv[2]
ies = parse(open(src, "rb").read())
if cmd == "list":
    for ie_id, subs in ies:
        names = [d.decode() for s, d in subs if s == SUB_NAME]
        datas = [d for s, d in subs if s == SUB_DATA]
        print(ie_id, names, [f"{len(d)}:{hashlib.sha1(d).hexdigest()[:10]}" for d in datas])
elif cmd == "add":
    dst, name, datafile = sys.argv[3:6]
    data = open(datafile, "rb").read()
    for _, subs in ies:
        assert name.encode() not in [d for s, d in subs if s == SUB_NAME], "name exists"
    ies.append((IE_BOARD, [(SUB_NAME, name.encode()), (SUB_DATA, data)]))
    out = build(ies)
    assert parse(out)[:-1] == ies[:-1]
    open(dst, "wb").write(out)
