#!/usr/bin/env python3
"""slice.py — backward provenance over a CX_TRACE_AT log.

Usage:
  slice.py TRACE.log --findv VALUE      first step where a GPR equals VALUE
  slice.py TRACE.log --track REG VALUE  walk back the writer chain
  slice.py TRACE.log --steps N          show the last N TR lines (parsed)
Options: --start-step K (only consider steps >= K)

TR line format (per instruction, registers BEFORE it runs):
  TR ip=<rip> ax= cx= dx= bx= sp= bp= si= di= 8= .. 15= f= c=<hex bytes>
"""
import sys, re, array
from capstone import *
from capstone.x86 import *

REGS = ['ax','cx','dx','bx','sp','bp','si','di','8','9','10','11','12','13','14','15']
R64  = ['rax','rcx','rdx','rbx','rsp','rbp','rsi','rdi','r8','r9','r10','r11','r12','r13','r14','r15']
RIDX = {n: i for i, n in enumerate(REGS)}
TRIP = re.compile(r'^TR ip=([0-9a-f]+) ')

def load(path):
    offs = array.array('q')
    rips = array.array('Q')
    regs = [array.array('Q') for _ in range(16)]
    flags = array.array('Q')
    with open(path, 'r', errors='replace') as f:
        pos = 0
        for line in f:
            if not line.startswith('TR ip='):
                pos += len(line); continue
            offs.append(pos); pos += len(line)
            fields = line.split()
            rips.append(int(fields[1][3:], 16))
            vals = [0]*16
            for fld in fields[2:]:
                if fld.startswith('c='): break
                if '=' in fld:
                    k, v = fld.split('=', 1)
                    if k in RIDX: vals[RIDX[k]] = int(v, 16)
            for i in range(16): regs[i].append(vals[i])
    return offs, rips, regs

def read_code(path, off):
    with open(path, 'r', errors='replace') as f:
        f.seek(off)
        line = f.readline()
    fields = line.split()
    for fld in fields:
        if fld.startswith('c='):
            h = fld[2:]
            return bytes.fromhex(h[:32])
    return b''

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True

PARENT = {}
for _p in ['rax','rcx','rdx','rbx','rsp','rbp','rsi','rdi'] + [f'r{i}' for i in range(8,16)]:
    PARENT[_p] = _p
for _p, _subs in {'rax':'eax ax al ah', 'rcx':'ecx cx cl ch', 'rdx':'edx dx dl dh', 'rbx':'ebx bx bl bh',
                  'rsp':'esp sp spl', 'rbp':'ebp bp bpl', 'rsi':'esi si sil', 'rdi':'edi di dil',
                  **{f'r{i}': f'r{i}d r{i}w r{i}b' for i in range(8,16)}}.items():
    for _s in _subs.split(): PARENT[_s] = _p

def parent(name):
    return PARENT.get(name)

def ins_writes(ins):
    try:
        return {parent(md.reg_name(r)) for r in ins.regs_access()[1]} - {None}
    except Exception:
        return set()

def ins_reads(ins):
    try:
        return {parent(md.reg_name(r)) for r in ins.regs_access()[0]} - {None}
    except Exception:
        return set()

def dis(rip, code):
    out = list(md.disasm(code, rip))
    return out[0] if out else None

def show(trace, offs, rips, regs, k, note=""):
    ins = dis(rips[k], read_code(trace, offs[k]))
    regs_s = ' '.join(f"{R64[i]}={regs[i][k]:#x}" for i in range(16) if regs[i][k])
    print(f"  step {k}: {rips[k]:#x}  {ins.mnemonic} {ins.op_str}" if ins else f"  step {k}: {rips[k]:#x} <undecoded>")
    print(f"      {regs_s} {note}")

def writer_of(regs, ridx, value, i):
    """last k < i where instruction k wrote register ridx to `value`"""
    k = i - 1
    while k >= 0:
        if regs[ridx][k+1] == value and regs[ridx][k] != value:
            return k
        k -= 1
    return -1

def opreads_reg(op, ridx):
    if op.type == X86_OP_REG and md.reg_name(op.reg) == R64[ridx]: return True
    if op.type == X86_OP_MEM:
        if md.reg_name(op.mem.base) == R64[ridx]: return True
        if md.reg_name(op.mem.index) == R64[ridx]: return True
    return False

def track(trace, offs, rips, regs, ridx, value, i, depth=0, maxdepth=12):
    ind = "  " * (depth + 1)
    if depth > maxdepth: return
    k = writer_of(regs, ridx, value, i)
    if k < 0:
        print(f"{ind}{R64[ridx]}={value:#x} already had this value at/before trace start (or changed in a gap)")
        return
    ins = dis(rips[k], read_code(trace, offs[k]))
    desc = f"{ins.mnemonic} {ins.op_str}" if ins else "<undecoded>"
    print(f"{ind}{R64[ridx]}={value:#x} <- step {k} {rips[k]:#x} {desc}")
    if depth >= maxdepth or ins is None:
        return
    old = regs[ridx][k]           # value before the instruction
    written = R64[ridx] in ins_writes(ins)
    srcs = []
    for op in ins.operands:
        if op.type == X86_OP_REG:
            nm = parent(md.reg_name(op.reg))
            if nm in R64:
                j = R64.index(nm)
                srcs.append((j, regs[j][k], False))
        elif op.type == X86_OP_MEM:
            m = op.mem
            ea = m.disp
            parts = []
            if m.base:
                bn = parent(md.reg_name(m.base))
                if bn is None:
                    if md.reg_name(m.base) == 'rip':
                        ea += ins.address + ins.size
                        parts.append("rip-rel")
                else:
                    bj = R64.index(bn)
                    ea += regs[bj][k]; parts.append(f"{bn}={regs[bj][k]:#x}")
                    srcs.append((bj, regs[bj][k], True))
            if m.index:
                inn = parent(md.reg_name(m.index))
                if inn is not None:
                    ij = R64.index(inn)
                    ea += regs[ij][k] * m.scale; parts.append(f"{inn}*{m.scale}={regs[ij][k]*m.scale:#x}")
                    srcs.append((ij, regs[ij][k], True))
            if m.disp: parts.append(f"disp={m.disp:#x}")
            print(f"{ind}   mem operand: ea={ea:#x} ({', '.join(parts) or 'abs'})")
    if not written:
        print(f"{ind}   (?) instruction does not list {R64[ridx]} as written")
    for op in ins.operands:
        if op.type == X86_OP_REG and parent(md.reg_name(op.reg)) == R64[ridx] and (op.access & CS_AC_READ):
            srcs.append((ridx, old, False))
    seen = set()
    for j, v, ismem in srcs:
        key = (j, v)
        if key in seen: continue
        seen.add(key)
        tag = " (base/index of load)" if ismem else ""
        print(f"{ind}   source {R64[j]}={v:#x}{tag}")
        track(trace, offs, rips, regs, j, v, k, depth + 1, maxdepth)

def main():
    args = sys.argv[1:]
    path = args[0]
    mode = None; val = None; reg = None; steps = 0; start = 0; end = None; sub = None; maskbits = 0; depth = 12; atstep = None
    i = 1
    while i < len(args):
        if args[i] == '--findv': mode = 'find'; val = int(args[i+1], 16); i += 2
        elif args[i] == '--findsub':
            mode = 'findsub'; sub = args[i+1].lower().lstrip('0x'); maskbits = 4*len(sub)
            val = int(sub, 16); i += 2
        elif args[i] == '--findstore': mode = 'findstore'; val = int(args[i+1], 16); i += 2
        elif args[i] == '--track':
            mode = 'track'; reg = args[i+1]; val = int(args[i+2], 16); i += 3
        elif args[i] == '--steps': steps = int(args[i+1]); i += 2
        elif args[i] == '--start-step': start = int(args[i+1]); i += 2
        elif args[i] == '--end-step': end = int(args[i+1]); i += 2
        elif args[i] == '--findstoreval': mode = 'findstoreval'; val = int(args[i+1], 16); i += 2
        elif args[i] == '--depth': depth = int(args[i+1]); i += 2
        elif args[i] == '--trackstep':
            mode='trackstep'; reg=args[i+1]; atstep=int(args[i+2]); i += 3
        else: i += 1
    print(f"loading {path} ...", file=sys.stderr)
    offs, rips, regs = load(path)
    n = len(rips)
    if end is None: end = n
    print(f"{n} TR lines, rip range {rips[0]:#x} .. {rips[-1]:#x}")
    if steps:
        for k in range(max(0, n-steps), n):
            show(path, offs, rips, regs, k)
        return
    if mode == 'find':
        hits = []
        for k in range(start, n):
            for j in range(16):
                if regs[j][k] == val:
                    hits.append((k, j))
                    break
            if len(hits) >= 40: break
        if not hits:
            print(f"value {val:#x} never appears in a GPR within the trace")
            return
        print(f"first {len(hits)} hits (step, rip, reg):")
        for k, j in hits[:10]:
            print(f"  step {k} rip={rips[k]:#x} {R64[j]}={val:#x}")
        k0, j0 = hits[0]
        print("\n== walk back from the FIRST occurrence ==")
        track(path, offs, rips, regs, j0, val, k0, 0, depth)
        return
    if mode == 'findsub':
        mask = (1 << maskbits) - 1
        hits = []
        for k in range(start, n):
            for j in range(16):
                if (regs[j][k] & mask) == val:
                    hits.append((k, j)); break
            if len(hits) >= 60: break
        if not hits:
            print(f"no GPR with low {maskbits} bits == {val:#x} within the trace")
            return
        print(f"low-{maskbits}-bit matches: {len(hits)} steps; first 12:")
        for k, j in hits[:12]:
            print(f"  step {k} rip={rips[k]:#x} {R64[j]}={regs[j][k]:#x}")
        k0, j0 = hits[0]
        print("\n== walk back from the FIRST occurrence ==")
        track(path, offs, rips, regs, j0, regs[j0][k0], k0, 0, depth)
        return
    if mode in ('findstore', 'findstoreval'):
        from capstone.x86 import X86_OP_MEM as _MEM, X86_OP_REG as _REG, X86_OP_IMM as _IMM
        hits = []
        for k in range(start, end):
            ins = dis(rips[k], read_code(path, offs[k]))
            if ins is None: continue
            mn = ins.mnemonic
            # push: writes [rsp-8]
            if mn.startswith('push'):
                ea = regs[4][k] - 8
                sval = None
                if ins.operands:
                    op = ins.operands[0]
                    if op.type == _REG:
                        pn = parent(md.reg_name(op.reg))
                        if pn: sval = regs[R64.index(pn)][k]
                    elif op.type == _IMM: sval = op.imm & 0xffffffffffffffff
                if mode == 'findstore' and ea == val:
                    hits.append((k, ins, sval, ea))
                elif mode == 'findstoreval' and sval == val:
                    hits.append((k, ins, sval, ea))
                continue
            # pop: reads [rsp]
            if mn.startswith('pop') and len(ins.operands) == 1 and ins.operands[0].type == _MEM:
                ea = regs[4][k]
                if mode == 'findstore' and ea == val:
                    hits.append((k, ins, None, ea))
                continue
            for op in ins.operands:
                if op.type == _MEM and (op.access & CS_AC_WRITE):
                    m = op.mem
                    ea = m.disp
                    if m.base:
                        bn = parent(md.reg_name(m.base))
                        if bn is None:
                            if md.reg_name(m.base) == 'rip': ea += ins.address + ins.size
                        else: ea += regs[R64.index(bn)][k]
                    if m.index:
                        inn = parent(md.reg_name(m.index))
                        if inn is not None: ea += regs[R64.index(inn)][k] * m.scale
                    sval = None
                    so = ins.operands[1] if len(ins.operands) > 1 else None
                    if so is not None:
                        if so.type == _REG:
                            pn = parent(md.reg_name(so.reg))
                            if pn: sval = regs[R64.index(pn)][k]
                        elif so.type == _IMM: sval = so.imm & 0xffffffffffffffff
                    if mode == 'findstore' and ea == val:
                        hits.append((k, ins, sval, ea)); break
                    if mode == 'findstoreval' and sval == val:
                        hits.append((k, ins, sval, ea)); break
        label = f"to {val:#x}" if mode == 'findstore' else f"of value {val:#x}"
        print(f"{len(hits)} store(s) {label}")
        for k, ins, sval, ea in hits[:60]:
            sv = f" value={sval:#x}" if sval is not None else ""
            print(f"  step {k} rip={rips[k]:#x}  {ins.mnemonic} {ins.op_str}  ea={ea:#x}{sv}")
        return
    if mode == 'trackstep':
        j = RIDX[reg]
        k = atstep
        print(f"using step {k} rip={rips[k]:#x}  {reg}={regs[j][k]:#x}")
        track(path, offs, rips, regs, j, regs[j][k], k, 0, depth)
        return
    if mode == 'track':
        j = RIDX[reg]
        k = n - 1
        while k >= 0 and regs[j][k] != val: k -= 1
        if k < 0:
            print(f"{reg}={val:#x} not present"); return
        print(f"using step {k} rip={rips[k]:#x}")
        track(path, offs, rips, regs, j, val, k, 0, depth)

main()
