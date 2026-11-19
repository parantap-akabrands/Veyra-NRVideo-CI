# Stages the third-party SDK headers/import libraries Veyra expects under
# third_party_local/, fetched from each vendor's own GitHub repository at an
# exact commit. Every checkout is verified by commit SHA; the two NVIDIA
# Optical Flow headers (not published on GitHub by NVIDIA) are additionally
# pinned by file SHA-256.
param(
    [Parameter(Mandatory = $true)][string]$VeyraRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$ManifestOut
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$pins = @(
    @{ Name = 'NVIDIA DLSS SDK';          Repo = 'NVIDIA/DLSS';                              Tag = 'v310.7.0';   Commit = 'a291cc7d2cc642a51566f3dfd5376f635cd1b284' },
    @{ Name = 'Intel XeSS SDK';           Repo = 'intel/xess';                               Tag = 'v3.0.2';     Commit = '8fe81bdbbaf00b3c1b733fd0d830c333dc84e6f0' },
    @{ Name = 'AMD FidelityFX SDK';       Repo = 'GPUOpen-LibrariesAndSDKs/FidelityFX-SDK'; Tag = 'v2.3.0';     Commit = '60f4ea81909200d8542eca14dccb2628b763a9a3' },
    @{ Name = 'AMD AMF SDK';              Repo = 'GPUOpen-LibrariesAndSDKs/AMF';             Tag = '(commit)';   Commit = '57ee0cfb0e1a08d9041f77435653794c1b012be0' },
    @{ Name = 'nv-codec-headers';         Repo = 'FFmpeg/nv-codec-headers';                  Tag = 'n13.0.19.0'; Commit = 'e844e5b26f46bb77479f063029595293aa8f812d' },
    @{ Name = 'NVOF headers (NeuralScreen copy)'; Repo = 'perseval-BLR/NeuralScreen';        Tag = '(commit)';   Commit = '9d6948c2b8f27987aac584f8d2b09e73c17c94e5' }
)

function Get-Pinned([string]$Repo, [string]$Commit, [string]$Dir) {
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    git init -q $Dir
    git -C $Dir remote add origin "https://github.com/$Repo.git"
    git -C $Dir fetch -q --depth 1 origin $Commit
    git -C $Dir -c advice.detachedHead=false checkout -q FETCH_HEAD
    $head = (git -C $Dir rev-parse HEAD).Trim()
    if ($head -ne $Commit) { throw "$Repo resolved to $head, expected $Commit" }
}

function Copy-Tree([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$tpl = Join-Path $VeyraRoot 'third_party_local'
New-Item -ItemType Directory -Force -Path $tpl | Out-Null

foreach ($p in $pins) {
    $dir = Join-Path $WorkRoot (($p.Repo -split '/')[1])
    Write-Host "Fetching $($p.Repo) @ $($p.Commit)"
    Get-Pinned $p.Repo $p.Commit $dir
    $p.Dir = $dir
}
$byRepo = @{}; foreach ($p in $pins) { $byRepo[$p.Repo] = $p.Dir }

# NVIDIA DLSS SDK 310.7.0 -> include/ and lib/ (static NGX shim nvsdk_ngx_s.lib)
$dlss = Join-Path $tpl 'nvidia/DLSS_SDK_310.7.0'
Copy-Tree (Join-Path $byRepo['NVIDIA/DLSS'] 'include') (Join-Path $dlss 'include')
Copy-Tree (Join-Path $byRepo['NVIDIA/DLSS'] 'lib') (Join-Path $dlss 'lib')
Copy-Item (Join-Path $byRepo['NVIDIA/DLSS'] 'LICENSE.txt') $dlss

# Intel XeSS 3.0.2 (headers only are needed at build time)
$xess = Join-Path $tpl 'intel/xess-3.0.2'
Copy-Tree (Join-Path $byRepo['intel/xess'] 'inc') (Join-Path $xess 'inc')
Copy-Item (Join-Path $byRepo['intel/xess'] 'LICENSE.txt') $xess

# AMD FidelityFX SDK 2.3.0 Kits/FidelityFX headers
$ffx = Join-Path $tpl 'amd/FidelityFX-SDK-2.3.0/Kits/FidelityFX'
$ffxSrc = Join-Path $byRepo['GPUOpen-LibrariesAndSDKs/FidelityFX-SDK'] 'Kits/FidelityFX'
foreach ($sub in 'api', 'framegeneration', 'upscalers') {
    Copy-Tree (Join-Path $ffxSrc "$sub/include") (Join-Path $ffx "$sub/include")
}

# AMD AMF public headers (MIT)
$amf = Join-Path $tpl 'amd/AMF-SDK-1.5.3'
Copy-Tree (Join-Path $byRepo['GPUOpen-LibrariesAndSDKs/AMF'] 'amf/public/include') (Join-Path $amf 'include')

# nv-codec-headers n13.0.19.0
$nvenc = Join-Path $tpl 'nvidia/nv-codec-headers-13.0'
Copy-Tree (Join-Path $byRepo['FFmpeg/nv-codec-headers'] 'include') (Join-Path $nvenc 'include')

# NVIDIA Optical Flow SDK 5.0 headers (MIT-licensed NVIDIA headers). NVIDIA only
# publishes the 5.x SDK behind a developer login, so the copy redistributed in
# NeuralScreen is used, pinned by SHA-256 (reviewed: unmodified NVIDIA MIT
# header text, API version 5.0).
$nvofPins = @{
    'nvOpticalFlowCommon.h' = 'cdbdbf0797fc02d2de1051520d4164bb1e36b7722009f46cb16216675319436a'
    'nvOpticalFlowD3D12.h'  = 'f12bbc6c54278cb5d3ae81723ca0363644f672fc3e72b635a709470ffdd6886f'
}
$nvof = Join-Path $tpl 'nvidia/Optical_Flow_SDK_5.0.7'
New-Item -ItemType Directory -Force -Path (Join-Path $nvof 'NvOFInterface'), (Join-Path $nvof 'Common/NvOFBase') | Out-Null
foreach ($h in $nvofPins.Keys) {
    $src = Join-Path $byRepo['perseval-BLR/NeuralScreen'] "native/include/nvofa/$h"
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant()
    if ($got -ne $nvofPins[$h]) { throw "$h SHA-256 $got does not match pinned $($nvofPins[$h])" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $nvof "NvOFInterface/$h")
}

$manifest = [ordered]@{ sdks = @($pins | ForEach-Object { [ordered]@{ name = $_.Name; repo = $_.Repo; tag = $_.Tag; commit = $_.Commit } }); nvofHeaderSha256 = $nvofPins }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestOut -Encoding utf8
Write-Host "SDKs staged under $tpl"
