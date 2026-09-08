#!/usr/bin/env python3
"""Decode the cleartext Blaze (Fire2 + heat2) stream on TCP 44321 from a capture made by pvp-run.zsh.

    python3 tools/blaze_decode.py runs/<run>/capture.pcapng 44321 [max chars per frame]

Prints one line per frame: UTC time, direction, header words (word 2 = component,
word 3 = command), size, decoded payload. Component 0x0004 = GameManager
(0x14 game setup, 0x16 removePlayer, 0x28 NotifyPlayerRemoved), 0x001c = GameReporting
(0x01 submitGameReport carries GDESYNCEND/GDESYNCRSN)."""
import struct, sys, json, datetime

PCAP = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 44321

def read_pcapng(path):
    d = open(path, 'rb').read()
    i = 0; endian = '<'; tsres = {}; links = {}
    while i + 8 <= len(d):
        btype, blen = struct.unpack_from(endian + 'II', d, i)
        if btype == 0x0A0D0D0A:
            magic = struct.unpack_from('<I', d, i + 8)[0]
            endian = '<' if magic == 0x1A2B3C4D else '>'
            btype, blen = struct.unpack_from(endian + 'II', d, i)
        body = d[i + 8:i + blen - 4]
        if btype == 1:  # IDB
            linktype, _, snaplen = struct.unpack_from(endian + 'HHI', body, 0)
            res = 6; j = 8
            while j + 4 <= len(body):
                code, olen = struct.unpack_from(endian + 'HH', body, j); j += 4
                if code == 0: break
                if code == 9: res = body[j]
                j += (olen + 3) & ~3
            links[len(tsres)] = linktype; tsres[len(tsres)] = res
        elif btype == 6:  # EPB
            ifid, tsh, tsl, caplen, origlen = struct.unpack_from(endian + 'IIIII', body, 0)
            ts = ((tsh << 32) | tsl) / (10 ** tsres.get(ifid, 6))
            yield ts, links.get(ifid, 1), body[20:20 + caplen]
        i += blen

def ip_from_frame(frame, dlt):
    f = frame
    if dlt == 1:
        if f[12:14] != b'\x08\x00': return None
        return f[14:]
    if dlt == 0:
        return f[4:] if f[:4] in (b'\x02\x00\x00\x00', b'\x00\x00\x00\x02') else None
    if dlt == 12: return f
    return None

streams = {'C>S': {}, 'S>C': {}}   # seq -> (ts, payload)
for ts, dlt, frame in read_pcapng(PCAP):
    ip = ip_from_frame(frame, dlt)
    if not ip or (ip[0] >> 4) != 4 or ip[9] != 6: continue
    ihl = (ip[0] & 0xf) * 4
    src = '.'.join(map(str, ip[12:16])); dst = '.'.join(map(str, ip[16:20]))
    tcp = ip[ihl:]
    sport, dport, seq = struct.unpack_from('>HHI', tcp, 0)
    doff = (tcp[12] >> 4) * 4
    payload = tcp[doff:struct.unpack_from('>H', ip, 2)[0] - ihl]
    if dport == PORT: dirn = 'C>S'
    elif sport == PORT: dirn = 'S>C'
    else: continue
    if payload and seq not in streams[dirn]:
        streams[dirn][seq] = (ts, payload)

def assemble(m):
    out = bytearray(); times = []   # times: list of (offset, ts)
    nxt = None
    for seq in sorted(m):
        ts, p = m[seq]
        if nxt is None: nxt = seq
        if seq < nxt:
            p = p[nxt - seq:]
            if not p: continue
            seq = nxt
        if seq > nxt:
            out += b'\0' * (seq - nxt); times.append((len(out), ts))
            nxt = seq
        times.append((len(out), ts)); out += p; nxt += len(p)
    return bytes(out), times

def tsat(times, off):
    t = times[0][1]
    for o, ts in times:
        if o <= off: t = ts
        else: break
    return t

def tag(b):
    t = (b[0] << 16) | (b[1] << 8) | b[2]
    cs = [(t >> 18) & 0x3f, (t >> 12) & 0x3f, (t >> 6) & 0x3f, t & 0x3f]
    return ''.join(chr(c + 32) for c in cs if c).strip()

def varint(b, i):
    x = b[i]; i += 1
    neg = x & 0x40; v = x & 0x3f; sh = 6
    while x & 0x80:
        x = b[i]; i += 1
        v |= (x & 0x7f) << sh; sh += 7
    return (-v if neg else v), i

def value(b, i, ty, depth=0):
    if depth > 12: raise ValueError('deep')
    if ty == 0: return varint(b, i)
    if ty == 1:
        n, i = varint(b, i); s = b[i:i + n]; return s.rstrip(b'\0').decode('utf-8', 'replace'), i + n
    if ty == 2:
        n, i = varint(b, i); return 'blob[%d]:%s' % (n, b[i:i + min(n, 24)].hex()), i + n
    if ty == 3: return struct_(b, i, depth + 1)
    if ty == 4:
        st = b[i]; n, i = varint(b, i + 1); out = []
        for _ in range(n): v, i = value(b, i, st, depth + 1); out.append(v)
        return out, i
    if ty == 5:
        kt, vt = b[i], b[i + 1]; n, i = varint(b, i + 2); out = {}
        for _ in range(n):
            k, i = value(b, i, kt, depth + 1); v, i = value(b, i, vt, depth + 1); out[str(k)] = v
        return out, i
    if ty == 6:
        m = b[i]; i += 1
        if m == 0x7f: return {'union': None}, i
        tg = tag(b[i:i + 3]); t2 = b[i + 3]; v, i = value(b, i + 4, t2, depth + 1)
        return {'union%d' % m: {tg: v}}, i
    if ty == 7:  # variable TDF: present u8, tdf id varint, one tagged field, 0x00 terminator
        present = b[i]; i += 1
        if not present: return None, i
        tid, i = varint(b, i)
        tg = tag(b[i:i + 3]); t2 = b[i + 3]; v, i = value(b, i + 4, t2, depth + 1)
        if i < len(b) and b[i] == 0: i += 1
        return {'var(%d)' % tid: {tg: v}}, i
    if ty == 8:
        a, i = varint(b, i); c, i = varint(b, i); return 'objtype(%d,%d)' % (a, c), i
    if ty == 9:
        a, i = varint(b, i); c, i = varint(b, i); e, i = varint(b, i); return 'objid(%d,%d,%d)' % (a, c, e), i
    if ty == 10: return struct.unpack_from('>f', b, i)[0], i + 4
    if ty == 11: return varint(b, i)
    raise ValueError('type %d' % ty)

def struct_(b, i, depth=0):
    out = {}
    while i < len(b):
        if b[i] == 0: return out, i + 1
        if b[i] == 2: i += 1; continue
        tg = tag(b[i:i + 3]); ty = b[i + 3]
        v, i = value(b, i + 4, ty, depth)
        out[tg] = v
    return out, i

def decode(payload):
    try:
        v, i = struct_(payload, 0)
        return v
    except Exception as e:
        return {'_undecoded': payload[:40].hex(), '_err': str(e)}

def fmt(ts):
    return datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M:%S.%f')[:-3]

frames = []
for dirn, m in streams.items():
    data, times = assemble(m)
    i = 0
    while i + 16 <= len(data):
        size = struct.unpack_from('>I', data, i)[0]
        w = struct.unpack_from('>HHHHHH', data, i + 4)
        if size > 200000:
            frames.append((tsat(times, i), dirn, ('BAD',), size, {'_resync_at': i})); break
        payload = data[i + 16:i + 16 + size]
        frames.append((tsat(times, i), dirn, w, size, decode(payload) if size else {}))
        i += 16 + size

frames.sort(key=lambda f: f[0])
for ts, dirn, w, size, v in frames:
    s = json.dumps(v, ensure_ascii=False, default=str)
    if len(s) > int(sys.argv[3]) if len(sys.argv) > 3 else 600: s = s[:int(sys.argv[3]) if len(sys.argv) > 3 else 600] + '…'
    print('%s %s w=%s size=%d %s' % (fmt(ts), dirn, ' '.join('%04x' % x for x in w), size, s))
