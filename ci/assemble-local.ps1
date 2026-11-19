<#
Assemble a runnable Veyra folder on YOUR PC from:
  1. the independent CI build   (Veyra-independent-<sha>.zip, artifact of this repo's workflow)
  2. the official release zip   (Veyra-2.1.9-NVIDIA-win64-portable.zip from Likely7/Veyra-NRVideo)

From the official zip, only GPU-runtime files are taken, and only if they are
validly Authenticode-signed by NVIDIA, Intel or AMD. Every unsigned or modified
DLL/EXE in the official package (community nvngx_dlssnr.dll builds, the
author's own binaries) is refused. Non-executable runtime data (json config,
model data) is copied and listed so you can see it.

Nothing is executed. Run in Windows PowerShell 5.1 or PowerShell 7:
  powershell -ExecutionPolicy Bypass -File assemble-local.ps1 `
     -IndependentZip .\Veyra-independent-b430d986c2.zip `
     -OfficialZip   .\Veyra-2.1.9-NVIDIA-win64-portable.zip `
     -Destination   C:\Veyra
#>
param(
    [Parameter(Mandatory = $true)][string]$IndependentZip,
    [Parameter(Mandatory = $true)][string]$OfficialZip,
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'

# SHA-256 of the official 2.1.9 NVIDIA package, as recorded by GitHub for the release asset.
$OfficialSha256 = '4225ecb11a8e96c2826b4b0b798feb811d7ae237f3edf0b627f3b6895c79f362'
$TrustedSigners = 'CN=NVIDIA Corporation,', 'CN=Intel Corporation,', 'CN=Advanced Micro Devices,'
$PeExt = '.dll', '.exe', '.sys', '.ocx', '.cpl', '.scr', '.node'

$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $OfficialZip).Hash.ToLowerInvariant()
if ($got -ne $OfficialSha256) { throw "Official zip SHA-256 $got does not match the published $OfficialSha256" }
Write-Host "Official zip hash OK"

if (Test-Path -LiteralPath $Destination) { throw "$Destination already exists; choose an empty folder" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("veyra-assemble-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$tmp\ind", "$tmp\off" | Out-Null
try {
    Expand-Archive -LiteralPath $IndependentZip -DestinationPath "$tmp\ind"
    Expand-Archive -LiteralPath $OfficialZip -DestinationPath "$tmp\off"
    $indRoot = (Get-ChildItem "$tmp\ind" -Directory | Select-Object -First 1).FullName
    $offRoot = (Get-ChildItem "$tmp\off" -Directory | Select-Object -First 1).FullName
    if (-not (Test-Path "$indRoot\veyra_qml_ui.exe")) { throw 'independent zip does not contain veyra_qml_ui.exe' }

    Copy-Item -LiteralPath $indRoot -Destination $Destination -Recurse
    Write-Host "Independent build copied to $Destination"

    $report = foreach ($f in Get-ChildItem "$offRoot\runtime", "$offRoot\runtime_local" -Recurse -File -ErrorAction SilentlyContinue) {
        $rel = $f.FullName.Substring($offRoot.Length + 1)
        $isPe = $PeExt -contains $f.Extension.ToLowerInvariant()
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant()
        $action = 'copied'; $why = 'data file'
        if ($isPe) {
            $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
            $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
            $trusted = $sig.Status -eq 'Valid' -and ($TrustedSigners | Where-Object { $subject.StartsWith($_) })
            if ($trusted) { $why = "signed: $($subject.Split(',')[0])" }
            else { $action = 'REFUSED'; $why = "signature $($sig.Status) $($subject.Split(',')[0])" }
        }
        $dst = Join-Path $Destination $rel
        if ($action -eq 'copied' -and -not (Test-Path -LiteralPath $dst)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dst
        } elseif ($action -eq 'copied') { $action = 'kept independent copy' }
        [pscustomobject]@{ action = $action; file = $rel; sha256 = $hash.Substring(0, 16); detail = $why }
    }
    $report | Sort-Object action, file | Format-Table -AutoSize | Out-String -Width 300 | Tee-Object (Join-Path $Destination 'ASSEMBLY-REPORT.txt')
    Write-Host "Done. Start $Destination\veyra_qml_ui.exe"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
