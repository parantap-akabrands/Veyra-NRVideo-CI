"""Compare community-modified nvngx_dlssnr.dll builds against NVIDIA-signed
originals, to show WHAT was changed. A GPU-kernel-only patch should leave the
CPU code (.text), imports and exports essentially untouched; new imports
(network, process, registry APIs) or large .text changes would be red flags.

usage: pe-compare.py <inventory.json> <report.md>
inventory.json: [{"path":..., "sha256":..., "signature":"Valid|HashMismatch|NotSigned|...", "label":...}, ...]
Reads files only; never loads or executes them.
"""
import hashlib
import json
import math
import sys
from collections import Counter

import capstone
import pefile

SUSPICIOUS = {
    'ws2_32.dll', 'wininet.dll', 'winhttp.dll', 'urlmon.dll', 'dnsapi.dll', 'iphlpapi.dll',
    'crypt32.dll', 'advapi32.dll', 'shell32.dll', 'user32.dll', 'ntdll.dll', 'psapi.dll', 'wtsapi32.dll',
}
SUSPICIOUS_FUNCS = {
    'WriteProcessMemory', 'CreateRemoteThread', 'VirtualAllocEx', 'OpenProcess', 'SetWindowsHookExA',
    'SetWindowsHookExW', 'GetAsyncKeyState', 'URLDownloadToFileA', 'URLDownloadToFileW', 'InternetOpenA',
    'InternetOpenW', 'WinHttpOpen', 'connect', 'send', 'recv', 'RegSetValueExA', 'RegSetValueExW',
    'CreateProcessA', 'CreateProcessW', 'ShellExecuteA', 'ShellExecuteW', 'WinExec', 'CryptUnprotectData',
}


def entropy(b: bytes) -> float:
    if not b:
        return 0.0
    c = Counter(b)
    n = len(b)
    return -sum(v / n * math.log2(v / n) for v in c.values())


def load(path):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT'],
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT']])
    secs = {}
    for s in pe.sections:
        name = s.Name.rstrip(b'\0').decode(errors='replace')
        data = s.get_data()
        secs[name] = dict(data=data, va=s.VirtualAddress, raw=s.PointerToRawData, size=len(data),
                          sha=hashlib.sha256(data).hexdigest(), ent=entropy(data[:4_000_000]))
    imps = set()
    for attr in ('DIRECTORY_ENTRY_IMPORT', 'DIRECTORY_ENTRY_DELAY_IMPORT'):
        for d in getattr(pe, attr, []):
            dll = d.dll.decode(errors='replace').lower()
            for i in d.imports:
                imps.add((dll, (i.name or b'#%d' % i.ordinal).decode(errors='replace')))
    exps = set()
    if hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
        exps = {(e.name or b'').decode(errors='replace') for e in pe.DIRECTORY_ENTRY_EXPORT.symbols}
    return pe, secs, imps, exps


def diff_ranges(a: bytes, b: bytes, limit=40):
    n = min(len(a), len(b))
    out, total = [], 0
    chunk = 1 << 16
    for base in range(0, n, chunk):
        end = min(n, base + chunk)
        if a[base:end] == b[base:end]:
            continue
        i = base
        while i < end:
            if a[i] != b[i]:
                j = i
                while j < end and a[j] != b[j]:
                    j += 1
                total += j - i
                if out and out[-1][1] == i:
                    out[-1] = (out[-1][0], j)
                elif len(out) < limit:
                    out.append((i, j))
                i = j
            else:
                i += 1
    total += abs(len(a) - len(b))
    return total, out


def similarity(sa, sb):
    return sum(1 for k in sa if k in sb and sa[k]['sha'] == sb[k]['sha'])


inv = json.load(open(sys.argv[1], encoding='utf-8-sig'))
inv = [x for x in inv if x['path'].lower().endswith('.dll')]
loaded = {}
for x in inv:
    try:
        loaded[x['sha256']] = (x, *load(x['path']))
    except Exception as e:  # noqa: BLE001
        print('cannot parse', x['path'], e)

refs = [v for v in loaded.values() if v[0]['signature'] == 'Valid']
mods = [v for v in loaded.values() if v[0]['signature'] != 'Valid']
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
L = ['# nvngx_dlssnr.dll provenance and diff report', '',
     '| label | version | bytes | sha256 | Authenticode |', '|---|---|---|---|---|']
for x, pe, secs, imps, exps in loaded.values():
    L.append(f"| {x['label']} | {x.get('version','')} | {x.get('bytes','')} | `{x['sha256']}` | {x['signature']} |")

for m in mods:
    x, pe, secs, imps, exps = m
    L += ['', f"## {x['label']}  (`{x['sha256'][:16]}…`, {x['signature']})", '']
    if not refs:
        L.append('_No NVIDIA-signed reference available._')
        continue
    ref = max(refs, key=lambda r: (similarity(secs, r[2]), -abs(len(r[0]['path']) - len(x['path']))))
    rx, rpe, rsecs, rimps, rexps = ref
    L.append(f"Closest NVIDIA-signed reference: **{rx['label']}** (`{rx['sha256'][:16]}…`, version {rx.get('version','')})")
    L += ['', '| section | size (mod / ref) | identical | differing bytes | entropy mod/ref |', '|---|---|---|---|---|']
    text_ranges = None
    for name in sorted(set(secs) | set(rsecs)):
        a, b = secs.get(name), rsecs.get(name)
        if not a or not b:
            L.append(f"| {name} | {a and a['size']} / {b and b['size']} | ADDED/REMOVED | – | – |")
            continue
        same = a['sha'] == b['sha']
        total, ranges = (0, []) if same else diff_ranges(a['data'], b['data'])
        if name == '.text' and not same:
            text_ranges = (ranges, a, b)
        L.append(f"| {name} | {a['size']} / {b['size']} | {'yes' if same else 'no'} | {total} | {a['ent']:.2f} / {b['ent']:.2f} |")
    new_imps = sorted(imps - rimps)
    gone_imps = sorted(rimps - imps)
    L += ['', f"Imports added: {len(new_imps)}  removed: {len(gone_imps)}"]
    for d, f in new_imps:
        flag = ' **SUSPICIOUS**' if f in SUSPICIOUS_FUNCS or d in SUSPICIOUS else ''
        L.append(f"- + `{d}!{f}`{flag}")
    for d, f in gone_imps:
        L.append(f"- − `{d}!{f}`")
    L.append(f"Exports added: {sorted(exps - rexps)}  removed: {sorted(rexps - exps)}")
    if text_ranges:
        ranges, a, b = text_ranges
        L += ['', '`.text` (CPU code) changes, first ranges, disassembled:', '```']
        for s, e in ranges[:25]:
            lo = max(0, s - 8)
            hi = min(len(a['data']), e + 8)
            va = a['va'] + lo
            L.append(f"-- RVA {a['va'] + s:#x} ({e - s} bytes)")
            for tag, buf in (('ref', b['data'][lo:hi]), ('mod', a['data'][lo:hi])):
                ins = '; '.join(f"{i.mnemonic} {i.op_str}".strip() for i in md.disasm(buf, va))
                L.append(f"   {tag}: {ins[:300]}")
        L.append('```')

open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(L) + '\n')
print('\n'.join(L))
