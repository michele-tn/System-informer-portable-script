#requires -Version 5.1
<#
.SYNOPSIS
Find, verify, extract and run Stable or Canary System Informer as administrator.
.DESCRIPTION
Queries SourceForge for Stable or the official Canary page for previews. Keeps the original ZIP,
uses versioned portable directories and never installs the setup package.
Requires Windows and Internet access. Launch mode also requires UAC approval.
.PARAMETER Channel
Stable (default), Canary, or Nightly (alias for Canary).
.PARAMETER Destination
Portable workspace. Defaults to the directory containing this script.
.PARAMETER NoLaunch
Prepare the portable application without starting it.
.PARAMETER CheckOnly
Report the selected release and expected SHA-256 without downloading.
.EXAMPLE
.\Start-SystemInformer.ps1
.EXAMPLE
.\Start-SystemInformer.ps1 -Destination 'D:\Portable Tools\SystemInformer' -NoLaunch
.EXAMPLE
.\Start-SystemInformer.ps1 -CheckOnly
.EXAMPLE
.\Start-SystemInformer.ps1 -Channel Canary -NoLaunch
#>
[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [ValidateSet('Stable', 'Canary', 'Nightly')]
    [string]$Channel = 'Stable',
    [ValidateNotNullOrEmpty()]
    [string]$Destination = $PSScriptRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Prepare')]
    [switch]$NoLaunch,
    [Parameter(Mandatory = $true, ParameterSetName = 'Check')]
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SourceForgeUrl([string]$Url) {
    $uri = [uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
        ($uri.Host -ne 'sourceforge.net' -and -not $uri.Host.EndsWith('.sourceforge.net')) -or
        $uri.UserInfo) {
        throw "Rejected an unexpected download URL: $Url"
    }
}

function Get-LatestStableRelease {
    Write-Host '[1/5] Checking the latest stable portable ZIP on SourceForge...'
    $listing = Invoke-WebRequest -Uri 'https://sourceforge.net/projects/systeminformer/files/' `
        -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 10
    # Match portable binary ZIPs only; setup EXEs cannot become candidates.
    $pattern = 'systeminformer-(?<version>\d+\.\d+\.\d+(?:\.\d+)?)-(?:release-)?bin\.zip'
    $candidates = @([regex]::Matches($listing.Content, $pattern) | ForEach-Object {
        [pscustomobject]@{ FileName = $_.Value; Version = [version]$_.Groups['version'].Value }
    } | Sort-Object Version -Descending | Select-Object -Unique -Property FileName, Version)
    if ($candidates.Count -eq 0) {
        throw 'No stable portable ZIP was found. Check the SourceForge file list; its format may have changed.'
    }
    $latest = $candidates[0]
    $pageUrl = "https://sourceforge.net/projects/systeminformer/files/$($latest.FileName)/download"
    $page = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 10
    $hashMatch = [regex]::Match($page.Content, 'SHA-?256[\s\S]{0,600}?\b(?<hash>[a-fA-F0-9]{64})\b', 'IgnoreCase')
    if (-not $hashMatch.Success) {
        throw 'SourceForge did not publish a recognizable SHA-256. Nothing will be downloaded or launched.'
    }
    [pscustomobject]@{
        Version = $latest.Version.ToString(); FileName = $latest.FileName
        Sha256 = $hashMatch.Groups['hash'].Value.ToLowerInvariant(); PageUrl = $pageUrl
    }
}

function Get-LatestCanaryRelease {
    Write-Host '[1/5] Checking the latest Canary portable ZIP...'
    $page = Invoke-WebRequest -Uri 'https://systeminformer.com/canary' -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 10
    $link = [regex]::Match($page.Content, 'href="(?<url>https://github\.com/winsiderss/si-builds/releases/download/(?<version>\d+\.\d+\.\d+\.\d+)/systeminformer-build-bin\.zip)"', 'IgnoreCase')
    $hash = [regex]::Match($page.Content, 'Binaries\s*<small[^>]*>\(SHA-256\)[\s\S]*?href="https://www\.virustotal\.com/gui/file/(?<hash>[a-fA-F0-9]{64})"', 'IgnoreCase')
    if (-not $link.Success -or -not $hash.Success) {
        throw 'The official Canary page did not publish a recognizable portable ZIP and SHA-256.'
    }
    [pscustomobject]@{
        Version = $link.Groups['version'].Value
        FileName = "systeminformer-$($link.Groups['version'].Value)-canary-bin.zip"
        Sha256 = $hash.Groups['hash'].Value.ToLowerInvariant()
        PageUrl = $link.Groups['url'].Value
    }
}

function Get-ArchiveSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Receive-VerifiedArchive($Release, [string]$ArchivePath) {
    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        if ((Get-ArchiveSha256 $ArchivePath) -eq $Release.Sha256) {
            Write-Host '[2/5] Reusing the existing ZIP: SHA-256 verified.'
            return
        }
        Write-Host '[2/5] Existing ZIP failed verification. Downloading a replacement...'
    } else { Write-Host '[2/5] Downloading the portable ZIP...' }
    $partial = "$ArchivePath.$([guid]::NewGuid().ToString('N')).partial"
    $url = $Release.PageUrl
    try {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            if ($Channel -eq 'Stable') { Assert-SourceForgeUrl $url }
            elseif ($url -notmatch '^https://github\.com/winsiderss/si-builds/releases/download/\d+\.\d+\.\d+\.\d+/systeminformer-build-bin\.zip$') {
                throw "Rejected an unexpected Canary download URL: $url"
            }
            Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 180 -MaximumRedirection 10
            if ((Get-ArchiveSha256 $partial) -eq $Release.Sha256) {
                Move-Item -LiteralPath $partial -Destination $ArchivePath -Force
                Write-Host 'Download complete: SHA-256 verified.'
                return
            }
            if ((Get-Item -LiteralPath $partial).Length -gt 2MB) {
                throw 'The downloaded archive failed SHA-256 verification. The previous ZIP was preserved.'
            }
            if ($Channel -ne 'Stable') { throw 'The Canary archive failed SHA-256 verification.' }
            # SourceForge sometimes sends an HTML refresh rather than an HTTP redirect.
            $html = Get-Content -LiteralPath $partial -Raw
            $refresh = [regex]::Match($html, 'content\s*=\s*"\d+;\s*url=([^"]+)"', 'IgnoreCase')
            if (-not $refresh.Success) {
                throw 'The server returned HTML instead of a ZIP, with no usable download redirect. Retry later.'
            }
            $url = [System.Net.WebUtility]::HtmlDecode($refresh.Groups[1].Value)
        }
        throw 'SourceForge exceeded the HTML redirect limit. Retry later.'
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Expand-VerifiedArchive([string]$ArchivePath, [string]$Target) {
    # Validate ZIP paths before extracting anything.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Target).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = [IO.Path]::GetFullPath((Join-Path $Target $entry.FullName))
            if (-not $entryPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The ZIP contains an unsafe entry: $($entry.FullName)"
            }
        }
    } finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Target -Force
}

try {
    if ($Channel -eq 'Nightly') { $Channel = 'Canary' }
    if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
    if (-not $PSCommandPath) { throw 'Save this script as a .ps1 file before running it.' }
    if (-not $CheckOnly) {
        $Destination = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination))
    }
    if (-not $CheckOnly -and -not $NoLaunch -and -not (Test-Administrator)) {
        Write-Host 'Administrator privileges are required. Accept the Windows UAC prompt to continue.'
        # Encode an expression to preserve paths with spaces and apostrophes.
        $scriptLiteral = $PSCommandPath.Replace("'", "''")
        $destinationLiteral = $Destination.Replace("'", "''")
        $command = "& '$scriptLiteral' -Destination '$destinationLiteral' -Channel '$Channel'"
        if ($NoLaunch) { $command += ' -NoLaunch' }
        if ($CheckOnly) { $command += ' -CheckOnly' }
        $command += '; exit $LASTEXITCODE'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $hostExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
        $child = Start-Process -FilePath $hostExe -Verb RunAs -Wait -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        exit $child.ExitCode
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $release = if ($Channel -eq 'Stable') { Get-LatestStableRelease } else { Get-LatestCanaryRelease }
    Write-Host "Latest $Channel version: $($release.Version)"
    Write-Host "Expected SHA-256: $($release.Sha256)"
    if ($CheckOnly) { $release | Format-List; exit 0 }

    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    $binaryFolder = switch ($architecture) {
        'AMD64' { 'amd64' }; 'ARM64' { 'arm64' }; 'x86' { 'i386' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $lockPath = Join-Path $Destination '.systeminformer.lock'
    $lock = $null
    try {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'Another run is using this directory, or it is not writable. Close the other run and retry.' }
        $archivePath = Join-Path $Destination $release.FileName
        Receive-VerifiedArchive $release $archivePath
        $folderName = if ($Channel -eq 'Stable') { "SystemInformer-$($release.Version)" } else { "SystemInformer-Canary-$($release.Version)" }
        $versionFolder = Join-Path $Destination $folderName
        $exe = Join-Path $versionFolder "$binaryFolder\SystemInformer.exe"
        $marker = Join-Path $versionFolder '.archive-sha256'
        $prepared = (Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $marker -PathType Leaf)
        if ($prepared) { $prepared = (Get-Content -LiteralPath $marker -Raw).Trim() -eq $release.Sha256 }
        if (-not $prepared) {
            if (Test-Path -LiteralPath $versionFolder) {
                throw "An incomplete directory already exists: $versionFolder. Rename it, then retry; its files were preserved."
            }
            Write-Host '[3/5] Extracting into a new versioned directory...'
            Expand-VerifiedArchive $archivePath $versionFolder
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "The expected executable is missing: $exe" }
            Set-Content -LiteralPath $marker -Value $release.Sha256 -Encoding ASCII
        } else { Write-Host '[3/5] Reusing the prepared portable directory.' }
        Write-Host '[4/5] Preparing local settings...'
        $settings = "$exe.settings.json"
        if (-not (Test-Path -LiteralPath $settings)) { [IO.File]::WriteAllText($settings, '{}') }
        $manifest = [ordered]@{
            Channel = $Channel; Version = $release.Version; Architecture = $architecture; Sha256 = $release.Sha256
            Archive = $release.FileName; Executable = "$folderName/$binaryFolder/SystemInformer.exe"
            Source = $release.PageUrl; CheckedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $manifestName = if ($Channel -eq 'Stable') { 'latest-release.json' } else { 'latest-canary-release.json' }
        $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination $manifestName) -Encoding UTF8
        Write-Host "ZIP retained: $archivePath"
        Write-Host "Portable executable: $exe"
        if ($NoLaunch) { Write-Host '[5/5] Ready. Application launch was skipped (-NoLaunch).' }
        else {
            Write-Host '[5/5] Starting System Informer with administrator privileges...'
            # A new instance prevents forwarding the launch to an existing unelevated process.
            $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) `
                -ArgumentList '-v -newinstance' -WindowStyle Normal -PassThru
            Start-Sleep -Seconds 3
            $process.Refresh()
            if ($process.HasExited) { throw "System Informer exited during startup (exit code $($process.ExitCode))." }
            Write-Host "System Informer is running. Process ID: $($process.Id)"
        }
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
    exit 0
} catch {
    Write-Error -Message "System Informer could not complete the operation: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
