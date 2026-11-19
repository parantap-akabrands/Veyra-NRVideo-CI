# Collects the official Veyra release binaries and every public candidate
# source, hash-matches them, records Authenticode status and runs Defender.
# Binaries are never executed; only text reports are written for upload.
param([Parameter(Mandatory = $true)][string]$Work)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$official = Join-Path $Work 'official'; $public = Join-Path $Work 'public'
New-Item -ItemType Directory -Force $official, $public | Out-Null
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$maxAsset = 2GB; $budget = 30GB; $spent = 0

function Expand-All([string]$Dir) {
    # two passes so archives inside archives are expanded too
    foreach ($pass in 1..2) {
        Get-ChildItem $Dir -Recurse -File | Where-Object { $_.Extension -in '.zip', '.7z', '.rar', '.xz', '.gz', '.tar' -and -not (Test-Path "$($_.FullName).x") } | ForEach-Object {
            try { & $sevenZip x -y -bso0 -bsp0 "-o$($_.FullName).x" $_.FullName | Out-Null }
            catch { Write-Host "expand failed: $($_.Exception.Message)" }
        }
    }
}

# ---- 1. Official packages (NVIDIA + AMD portable builds)
Write-Host "== Official $env:OFFICIAL_TAG"
gh release download $env:OFFICIAL_TAG -R Likely7/Veyra-NRVideo -D $official -p 'Veyra-*-NVIDIA-win64-portable.zip' -p 'Veyra-*-AMD-win64-portable.zip'
Expand-All $official

# ---- 2. Vendor SDK repositories (NVIDIA-signed DLSS runtimes etc.), pinned tags
$vendor = @(
    @{ repo = 'NVIDIA/DLSS'; ref = 'v310.7.0' }, @{ repo = 'NVIDIA/DLSS'; ref = 'v310.9.1' }, @{ repo = 'NVIDIA/DLSS'; ref = 'v310.9.16' },
    @{ repo = 'intel/xess'; ref = 'v3.0.2' },
    @{ repo = 'GPUOpen-LibrariesAndSDKs/FidelityFX-SDK'; ref = 'v2.3.0' }
)
foreach ($v in $vendor) {
    $d = Join-Path $public ("git_" + ($v.repo -replace '/', '_') + "_" + $v.ref)
    try {
        git init -q $d; git -C $d remote add origin "https://github.com/$($v.repo).git"
        git -C $d fetch -q --depth 1 origin "refs/tags/$($v.ref)"
        git -C $d -c advice.detachedHead=false checkout -q FETCH_HEAD
        Remove-Item -Recurse -Force (Join-Path $d '.git')
    } catch { Write-Host "vendor fetch failed $($v.repo)@$($v.ref): $($_.Exception.Message)" }
}

# ---- 3. Community GitHub releases named by the author or linked from his notices
$community = @(
    @{ repo = 'RankFTW/rhi-repo'; tag = 'dlssnr|renodx-dlss5|dlss5|nr' },
    @{ repo = 'lmxxf/dlss5-on-amd-9070xt-porting'; tag = '.' },
    @{ repo = 'lmxxf/DLSS5-RTX-3080-laptop'; tag = '.' },
    @{ repo = 'RedDukeDev/dlss5-image-enhancer-zluda'; tag = '.' },
    @{ repo = 'RedDukeDev/ZLUDA'; tag = '.' },
    @{ repo = 'RedDukeDev/dlss5-nr-amd-custom'; tag = '.' },
    @{ repo = 'danielblnc/DLSS-NR-on-AMD'; tag = '.' },
    @{ repo = 'vosen/ZLUDA'; tag = '.' }
)
$assetLog = [System.Collections.Generic.List[object]]::new()
foreach ($c in $community) {
    Write-Host "== $($c.repo)"
    try { $rels = gh api "repos/$($c.repo)/releases?per_page=40" | ConvertFrom-Json }
    catch { Write-Host "  cannot list releases: $($_.Exception.Message)"; continue }
    foreach ($r in $rels) {
        if ($r.tag_name -notmatch $c.tag) { continue }
        foreach ($a in $r.assets) {
            $row = [pscustomobject]@{ repo = $c.repo; tag = $r.tag_name; published = $r.published_at; asset = $a.name; bytes = $a.size; githubDigest = $a.digest; downloaded = $false }
            $assetLog.Add($row)
            if ($a.name -notmatch '\.(zip|7z|rar|dll|exe|xz|gz|tar)$') { continue }
            if ($a.size -gt $maxAsset -or ($spent + $a.size) -gt $budget) { Write-Host "  skip (size) $($a.name)"; continue }
            $dest = Join-Path $public ("rel_" + ($c.repo -replace '/', '_') + "_" + ($r.tag_name -replace '[^\w\.-]', '_'))
            try {
                gh release download $r.tag_name -R $c.repo -D $dest -p $a.name --skip-existing
                $spent += $a.size; $row.downloaded = $true
            } catch { Write-Host "  download failed $($a.name): $($_.Exception.Message)" }
        }
    }
}
$assetLog | Export-Csv -NoTypeInformation (Join-Path $Work 'public-release-assets.csv')
Expand-All $public

# ---- 4. Inventory every PE file
function Get-Inventory([string]$Root, [string]$Kind) {
    Get-ChildItem $Root -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe', '.sys' } | ForEach-Object {
        $sig = Get-AuthenticodeSignature -LiteralPath $_.FullName
        [pscustomobject]@{
            kind = $Kind; path = $_.FullName; rel = $_.FullName.Substring($Root.Length + 1)
            name = $_.Name.ToLowerInvariant(); bytes = $_.Length; version = $_.VersionInfo.FileVersion
            sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            signature = [string]$sig.Status; signer = $sig.SignerCertificate.Subject
        }
    }
}
$offInv = @(Get-Inventory $official 'official')
$pubInv = @(Get-Inventory $public 'public')
$pubBySha = $pubInv | Group-Object sha256 -AsHashTable -AsString
$offInv + $pubInv | Export-Csv -NoTypeInformation (Join-Path $Work 'pe-inventory.csv')

# ---- 5. Match official binaries to public sources
$L = [System.Collections.Generic.List[string]]::new()
$L.Add("# Provenance of binaries in official Veyra $env:OFFICIAL_TAG packages"); $L.Add('')
$L.Add('Built from Veyra/FFmpeg source (veyra_qml_ui.exe, av*.dll, sw*.dll, dav1d.dll) are compared by the independent build instead.'); $L.Add('')
$L.Add('| file in official package | sha256 | Authenticode | public match |'); $L.Add('|---|---|---|---|')
foreach ($o in ($offInv | Sort-Object sha256 -Unique | Sort-Object rel)) {
    $m = $pubBySha[$o.sha256]
    $match = if ($m) { ($m | Select-Object -First 3 | ForEach-Object { $_.rel -replace '\\', '/' }) -join '<br>' } else { '**NO PUBLIC MATCH FOUND**' }
    $L.Add("| $($o.rel -replace '\\','/') | ``$($o.sha256.Substring(0,16))…`` | $($o.signature) | $match |")
}
$L.Add(''); $L.Add('## Public nvngx_dlssnr.dll builds found'); $L.Add('')
$L.Add('| source | version | bytes | sha256 | Authenticode |'); $L.Add('|---|---|---|---|---|')
foreach ($p in ($pubInv | Where-Object name -eq 'nvngx_dlssnr.dll' | Sort-Object sha256 -Unique)) {
    $L.Add("| $($p.rel -replace '\\','/') | $($p.version) | $($p.bytes) | ``$($p.sha256)`` | $($p.signature) |")
}
$L | Set-Content -Encoding utf8 (Join-Path $Work 'provenance.md')
$L | Out-Host
$L >> $env:GITHUB_STEP_SUMMARY

# ---- 6. Inventory for the PE diff (official + public NR runtimes, deduplicated)
$nr = ($offInv + $pubInv) | Where-Object name -eq 'nvngx_dlssnr.dll' | Sort-Object sha256 -Unique | ForEach-Object {
    [ordered]@{ path = $_.path; sha256 = $_.sha256; signature = $_.signature; version = $_.version; bytes = $_.bytes; label = "$($_.kind): $($_.rel -replace '\\','/')" }
}
ConvertTo-Json -InputObject @($nr) -Depth 3 | Set-Content -Encoding utf8 (Join-Path $Work 'dlssnr-inventory.json')

# ---- 7. Microsoft Defender over everything
$mp = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
$PSNativeCommandUseErrorActionPreference = $false
& $mp -SignatureUpdate | Out-Host
& $mp -Scan -ScanType 3 -File $Work -DisableRemediation | Tee-Object (Join-Path $Work 'defender.txt')
$code = $LASTEXITCODE
"Defender exit code: $code (0 = no threats, 2 = threats found)" | Tee-Object -Append (Join-Path $Work 'defender.txt')
"### Defender over official + public binaries: exit $code" >> $env:GITHUB_STEP_SUMMARY
