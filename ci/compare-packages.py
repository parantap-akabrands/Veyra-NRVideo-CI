"""Compare the independent build with the author's official package.

usage: compare-packages.py <build-extract-dir> <official-extract-dir> <report.md>

Byte-identical output is NOT expected (different machine, paths, FFmpeg
configuration, timestamps). The useful signals are: which files exist only in
the official package (binaries we did not and cannot build), and which shared
files are identical (vendor DLLs, QML, shaders).
"""
import hashlib
import sys
from pathlib import Path


def inventory(root: Path):
    out = {}
    if not root.is_dir():
        return out
    for pkg in sorted(p for p in root.iterdir() if p.is_dir()):
        # unwrap a single top-level folder inside the zip
        base = pkg
        kids = [k for k in base.iterdir()]
        while len(kids) == 1 and kids[0].is_dir():
            base = kids[0]
            kids = list(base.iterdir())
        for f in base.rglob('*'):
            if f.is_file():
                rel = f.relative_to(base).as_posix().lower()
                out.setdefault(rel, []).append((pkg.name, f.stat().st_size, hashlib.sha256(f.read_bytes()).hexdigest()))
    return out


build_dir, official_dir, report = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
ours = {k: v for k, v in inventory(build_dir).items()}
official = inventory(official_dir)
binary = ('.exe', '.dll', '.sys', '.node', '.pyd')

lines = ['## Independent build vs official package', '']
if not ours:
    lines.append('_No independent build artifact was available to compare._')
only_official_bin = sorted(k for k in official if k not in ours and k.endswith(binary))
lines += ['### Executables/DLLs present only in the official package (not built from source here)', '']
lines += [f'- `{k}`  ' + ', '.join(f'{p}: {s} B sha256 {h[:16]}…' for p, s, h in official[k]) for k in only_official_bin] or ['- none']
shared = sorted(k for k in official if k in ours)
same = [k for k in shared if {h for _, _, h in ours[k]} & {h for _, _, h in official[k]}]
diff = [k for k in shared if k not in same]
lines += ['', f'### Shared paths: {len(shared)}  identical: {len(same)}  different: {len(diff)}', '']
lines += ['Different (expected for anything compiled; check vendor DLLs and QML/shader text):', '']
lines += [f'- `{k}`' for k in diff[:300]] or ['- none']
lines += ['', f'Files only in this build: {sum(1 for k in ours if k not in official)}', '']
report.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('\n'.join(lines[:80]))
