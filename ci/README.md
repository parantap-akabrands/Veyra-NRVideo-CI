# Independent Veyra build

`.github/workflows/independent-build.yml` builds Veyra from the upstream
author's source (`Likely7/Veyra-NRVideo`) on a clean GitHub-hosted
`windows-2022` runner. It does not use any binary the author built.

| Input | Source | Pin |
|---|---|---|
| Veyra source | github.com/Likely7/Veyra-NRVideo | commit `b430d986…` (the 2.1.9 product commit; override with `veyra_ref`) |
| FFmpeg 9.0.1, dav1d, zlib, libass | vcpkg port built from source | vcpkg `30ef65ca…` (Veyra's own baseline) + Veyra's 2 FFmpeg patches pinned by SHA-256 |
| Qt 6.8.3 | download.qt.io via install-qt-action | Qt's own archive checksums |
| DLSS SDK 310.7.0 | github.com/NVIDIA/DLSS | `a291cc7d…` |
| XeSS 3.0.2 | github.com/intel/xess | `8fe81bdb…` |
| FidelityFX SDK 2.3.0 | github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK | `60f4ea81…` |
| AMF headers | github.com/GPUOpen-LibrariesAndSDKs/AMF | `57ee0cfb…` |
| nv-codec-headers 13.0.19.0 | github.com/FFmpeg/nv-codec-headers | `e844e5b2…` |
| NVIDIA Optical Flow 5.0 headers (2 MIT headers) | copy in github.com/perseval-BLR/NeuralScreen | commit `9d6948c2…` + file SHA-256 (NVIDIA only publishes these behind a developer login) |

Outputs (artifact `veyra-independent-build`):
- `Veyra-independent-<sha>.zip`: `veyra_qml_ui.exe` + Qt + FFmpeg + shaders
- `vendor-runtime-official-signed.zip`: optional NVIDIA/Intel/AMD runtime DLLs copied unchanged from the vendors' repos; the workflow requires each to have a valid Authenticode signature
- `SHA256SUMS*.txt`, `BUILD-INFO.json`, Defender report
- A Sigstore build-provenance attestation. Verify it with
  `gh attestation verify Veyra-independent-*.zip -R parantap-akabrands/veyra-nrvideo-ci`

The workflow also scans the official release with Microsoft Defender and
checks Authenticode on every DLL/EXE in it. It then runs ClamAV over the
source, both packages and the two helper repos, and compares this build's
files with the official package.

Not included, because there is no public source for them: `nvngx_dlssnr.dll`
(the NVIDIA neural-denoise runtime that the "NR" feature needs), the RTX Video
SDK runtimes, FidelityFX 1.1.4 optical-flow libraries, the PS5, Moonlight and
Xbox streaming backends (off by default), the startup music and the VB-CABLE
package.

## Assembling a runnable copy on your PC

`ci/assemble-local.ps1` combines the independent build with the GPU runtimes
from the official release zip, without trusting the author's binaries:

1. It checks the official zip against GitHub's recorded SHA-256 (`4225ecb1…` for
   `Veyra-2.1.9-NVIDIA-win64-portable.zip`).
2. It copies files from `runtime/` and `runtime_local/` only if they carry a
   valid Authenticode signature from NVIDIA, Intel or AMD, or are non-executable
   data. This includes NVIDIA's own signed `nr-original/nvngx_dlssnr.dll` 310.8.0,
   which supports RTX 50 (Blackwell) natively.
3. It refuses every unsigned or modified DLL/EXE: the community
   `nr-ampere/nvngx_dlssnr.dll`, the unsigned Magewell DLL, and all of the
   author's own binaries.
4. It writes `ASSEMBLY-REPORT.txt` listing what was copied and what was refused.

```powershell
gh attestation verify .\Veyra-independent-b430d986c2.zip -R parantap-akabrands/Veyra-NRVideo-CI
powershell -ExecutionPolicy Bypass -File .\assemble-local.ps1 -IndependentZip .\Veyra-independent-b430d986c2.zip -OfficialZip .\Veyra-2.1.9-NVIDIA-win64-portable.zip -Destination C:\Veyra
```
