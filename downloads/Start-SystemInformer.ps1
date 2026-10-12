#requires -Version 5.1
<#
.SYNOPSIS
Find, verify, extract and run the latest stable System Informer as administrator.
.DESCRIPTION
Queries the official SourceForge file list on every run. Keeps the original ZIP,
uses versioned portable directories and never installs the setup package.
Requires Windows and Internet access. Launch mode also requires UAC approval.
.PARAMETER Destination
Portable workspace. Defaults to the directory containing this script.
.PARAMETER NoLaunch
Prepare the portable application without starting it.
.PARAMETER CheckOnly
Report the latest stable release and expected SHA-256 without downloading.
.EXAMPLE
.\Start-SystemInformer.ps1
.EXAMPLE
.\Start-SystemInformer.ps1 -Destination 'D:\Portable Tools\SystemInformer' -NoLaunch
.EXAMPLE
.\Start-SystemInformer.ps1 -CheckOnly
#>
[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
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

function Receive-VerifiedArchive($Release, [string]$ArchivePath) {
    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -eq $Release.Sha256) {
            Write-Host '[2/5] Reusing the existing ZIP: SHA-256 verified.'
            return
        }
        Write-Host '[2/5] Existing ZIP failed verification. Downloading a replacement...'
    } else { Write-Host '[2/5] Downloading the portable ZIP...' }
    $partial = "$ArchivePath.$([guid]::NewGuid().ToString('N')).partial"
    $url = $Release.PageUrl
    try {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Assert-SourceForgeUrl $url
            Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 180 -MaximumRedirection 10
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $Release.Sha256) {
                Move-Item -LiteralPath $partial -Destination $ArchivePath -Force
                Write-Host 'Download complete: SHA-256 verified.'
                return
            }
            if ((Get-Item -LiteralPath $partial).Length -gt 2MB) {
                throw 'The downloaded archive failed SHA-256 verification. The previous ZIP was preserved.'
            }
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
        $command = "& '$scriptLiteral' -Destination '$destinationLiteral'"
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
    $release = Get-LatestStableRelease
    Write-Host "Latest stable version: $($release.Version)"
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
        $versionFolder = Join-Path $Destination "SystemInformer-$($release.Version)"
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
            Version = $release.Version; Architecture = $architecture; Sha256 = $release.Sha256
            Archive = $release.FileName; Executable = "SystemInformer-$($release.Version)/$binaryFolder/SystemInformer.exe"
            Source = $release.PageUrl; CheckedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'latest-release.json') -Encoding UTF8
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
