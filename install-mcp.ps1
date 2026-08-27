# Install or upgrade the emisar-mcp bridge on 64-bit Windows.
#
# Interactive install:
#   irm https://emisar.dev/install-mcp.ps1 | iex
#
# Non-interactive binary-only install:
#   & ([scriptblock]::Create((irm https://emisar.dev/install-mcp.ps1))) -Yes
#
# Uninstall the binary, client entries, stored CLI accounts, and rotation state:
#   & ([scriptblock]::Create((irm https://emisar.dev/install-mcp.ps1))) -Uninstall

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$InstallDir = "",
    [string]$PortalOrigin = "",
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$ConnectAll
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$script:Repository = if ($env:EMISAR_REPO) { $env:EMISAR_REPO } else { "andrewdryga/emisar" }
$script:OfficialRepository = "andrewdryga/emisar"
$script:PortalOrigin = if ($PortalOrigin) {
    $PortalOrigin.TrimEnd("/")
} elseif ($env:EMISAR_URL) {
    $env:EMISAR_URL.TrimEnd("/")
} else {
    "https://emisar.dev"
}
$script:ReleaseMirror = "https://emisar.dev/releases/mcp"
$script:AttestationWorkflow = if ($env:EMISAR_ATTESTATION_WORKFLOW) {
    $env:EMISAR_ATTESTATION_WORKFLOW
} elseif ($script:Repository -eq $script:OfficialRepository) {
    "AndrewDryga/emisar/.github/workflows/mcp-release.yml"
} else {
    ""
}
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-Info([string]$Message) {
    Write-Host "[install-mcp] $Message" -ForegroundColor Blue
}

function Write-WarningLine([string]$Message) {
    Write-Warning "[install-mcp] $Message"
}

function Stop-Install([string]$Message) {
    throw "[install-mcp] $Message"
}

function Get-WindowsReleaseArchitecture {
    try {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        } else {
            $env:PROCESSOR_ARCHITECTURE
        }
    }
    switch ($architecture.ToUpperInvariant()) {
        "X64" { return "amd64" }
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { Stop-Install "this release supports 64-bit x86 and ARM Windows only" }
    }
}

function Test-SafePortalOrigin([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
    if ($uri.AbsolutePath -ne "/") { return $false }
    if ($uri.Scheme -eq "https") { return $true }
    return $uri.Scheme -eq "http" -and $env:EMISAR_ALLOW_INSECURE -eq "1" -and $uri.IsLoopback
}

function Normalize-Version([string]$Value) {
    if ($Value -match '^mcp-v') { return $Value }
    if ($Value -match '^v') { return "mcp-$Value" }
    return "mcp-v$Value"
}

function Test-TrustedWebUri([Uri]$Uri) {
    if ($Uri.Scheme -eq "https") { return }
    if ($Uri.Scheme -eq "http" -and $env:EMISAR_ALLOW_INSECURE -eq "1" -and $Uri.IsLoopback) { return }
    Stop-Install "refusing an insecure download URL: $($Uri.GetLeftPart([UriPartial]::Authority))"
}

function New-WebClient([hashtable]$Headers = @{}) {
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    foreach ($name in $Headers.Keys) {
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation($name, [string]$Headers[$name])
    }
    return $client
}

function Get-WebBytes([string]$Url, [hashtable]$Headers = @{}) {
    $uri = [Uri]$Url
    Test-TrustedWebUri $uri
    $client = New-WebClient $Headers
    try {
        $response = $client.GetAsync($uri).GetAwaiter().GetResult()
        Test-TrustedWebUri $response.RequestMessage.RequestUri
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode)"
        }
        return ,$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
    }
}

function Get-WebJson([string]$Url, [hashtable]$Headers = @{}) {
    $bytes = Get-WebBytes $Url $Headers
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return $text | ConvertFrom-Json
}

function Save-WebFile([string]$Url, [string]$Path) {
    $bytes = Get-WebBytes $Url
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-GitHubHeaders {
    $headers = @{ Accept = "application/vnd.github+json" }
    if ($env:EMISAR_GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:EMISAR_GITHUB_TOKEN)"
    }
    return $headers
}

function Assert-ReleaseManifest($Manifest, [string]$ExpectedTag = "") {
    if ([int]$Manifest.schema_version -ne 1 -or [string]$Manifest.component -ne "mcp") {
        Stop-Install "the Emisar release mirror returned an invalid MCP manifest"
    }
    $tag = [string]$Manifest.tag
    $number = [string]$Manifest.version
    $revision = [string]$Manifest.source_revision
    if ($tag -notmatch '^mcp-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        $number -ne $tag.Substring(5) -or $revision -notmatch '^[0-9a-f]{40}$') {
        Stop-Install "the Emisar release mirror returned an invalid MCP manifest"
    }
    if ($ExpectedTag -and $tag -ne $ExpectedTag) {
        Stop-Install "the Emisar release mirror returned $tag for $ExpectedTag"
    }
    return $tag
}

function Get-GitHubRelease([string]$Tag) {
    $release = Get-WebJson "https://api.github.com/repos/$($script:Repository)/releases/tags/$Tag" (Get-GitHubHeaders)
    if ($release.immutable -ne $true) {
        Stop-Install "release $Tag is mutable and is no longer trusted"
    }
    return [pscustomobject]@{
        Tag = $Tag
        Base = "https://github.com/$($script:Repository)/releases/download/$Tag"
        Source = "GitHub release mirror"
        Test = $false
    }
}

function Resolve-Release([string]$RequestedVersion) {
    if ($env:EMISAR_MCP_TEST_BASE_URL) {
        $testUri = [Uri]$env:EMISAR_MCP_TEST_BASE_URL
        if (-not $testUri.IsLoopback -or $env:EMISAR_ALLOW_INSECURE -ne "1") {
            Stop-Install "EMISAR_MCP_TEST_BASE_URL is accepted only for an explicitly enabled loopback test server"
        }
        if (-not $RequestedVersion) {
            $RequestedVersion = Assert-ReleaseManifest (Get-WebJson "$($env:EMISAR_MCP_TEST_BASE_URL.TrimEnd('/'))/latest.json")
        }
        [void](Assert-ReleaseManifest (Get-WebJson "$($env:EMISAR_MCP_TEST_BASE_URL.TrimEnd('/'))/$RequestedVersion/manifest.json") $RequestedVersion)
        return [pscustomobject]@{
            Tag = $RequestedVersion
            Base = "$($env:EMISAR_MCP_TEST_BASE_URL.TrimEnd('/'))/$RequestedVersion"
            Source = "installer test server"
            Test = $true
        }
    }

    if (-not $RequestedVersion) {
        if ($script:Repository -eq $script:OfficialRepository) {
            $manifest = $null
            try {
                $manifest = Get-WebJson "$($script:ReleaseMirror)/latest.json"
            } catch {
                Write-WarningLine "Emisar release mirror unavailable; falling back to GitHub"
            }
            if ($null -ne $manifest) { $RequestedVersion = Assert-ReleaseManifest $manifest }
        }
        if (-not $RequestedVersion) {
            $releases = Get-WebJson "https://api.github.com/repos/$($script:Repository)/releases?per_page=100" (Get-GitHubHeaders)
            $candidate = $releases |
                Where-Object { -not $_.draft -and -not $_.prerelease -and [string]$_.tag_name -match '^mcp-v[0-9]+\.[0-9]+\.[0-9]+$' } |
                Sort-Object { [Version](([string]$_.tag_name).Substring(5)) } -Descending |
                Select-Object -First 1
            if (-not $candidate) { Stop-Install "no mcp-v* release found yet" }
            $RequestedVersion = [string]$candidate.tag_name
        }
    }

    if ($RequestedVersion -notmatch '^mcp-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        Stop-Install "release version must match mcp-vMAJOR.MINOR.PATCH"
    }
    if ($script:Repository -eq $script:OfficialRepository) {
        $manifest = $null
        try {
            $manifest = Get-WebJson "$($script:ReleaseMirror)/$RequestedVersion/manifest.json"
        } catch {
            Write-WarningLine "Emisar release mirror unavailable; falling back to GitHub"
        }
        if ($null -ne $manifest) {
            [void](Assert-ReleaseManifest $manifest $RequestedVersion)
            return [pscustomobject]@{
                Tag = $RequestedVersion
                Base = "$($script:ReleaseMirror)/$RequestedVersion"
                Source = "Emisar release mirror"
                Test = $false
            }
        }
    }
    return Get-GitHubRelease $RequestedVersion
}

function Assert-NoReparsePoint([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Install "$Label is a reparse point: $Path"
    }
}

function Set-PrivateDirectoryACL([string]$Path) {
    Assert-NoReparsePoint $Path "directory"
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $identities = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )
    foreach ($identity in $identities) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-PrivateFileACL([string]$Path) {
    Assert-NoReparsePoint $Path "file"
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $identities = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )
    foreach ($identity in $identities) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::FullControl, $allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Add-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if ($current) { $entries = @($current.Split(';') | Where-Object { $_ }) }
    if (-not ($entries | Where-Object { $_.TrimEnd('\\') -ieq $Directory.TrimEnd('\\') })) {
        $entries += $Directory
        [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "User")
        $marker = Join-Path $Directory ".emisar-mcp-path-added"
        [IO.File]::WriteAllText($marker, "added by install-mcp.ps1`r`n", $script:Utf8NoBom)
        Set-PrivateFileACL $marker
    }
    if (-not ($env:Path.Split(';') | Where-Object { $_.TrimEnd('\\') -ieq $Directory.TrimEnd('\\') })) {
        $env:Path = "$Directory;$($env:Path)"
    }
}

function Remove-UserPath([string]$Directory) {
    $marker = Join-Path $Directory ".emisar-mcp-path-added"
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return }
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current) {
        $entries = @($current.Split(';') | Where-Object { $_ -and $_.TrimEnd('\\') -ine $Directory.TrimEnd('\\') })
        [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "User")
    }
    Remove-Item -LiteralPath $marker -Force
}

function Assert-SafeArchive([string]$ArchivePath, [string]$ExpectedRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\\', '/')
            if ($name.StartsWith('/') -or $name.Contains(':') -or
                @($name.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0 -or
                -not $name.StartsWith("$ExpectedRoot/")) {
                Stop-Install "release archive contains an unsafe path"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Test-Attestation([string]$ArchivePath, [bool]$TestRelease) {
    if ($TestRelease) {
        Write-WarningLine "test release; skipping provenance verification"
        return
    }
    if (-not $script:AttestationWorkflow) {
        Write-WarningLine "no attestation workflow configured; skipping provenance check"
        return
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-WarningLine "gh not installed; skipping release attestation check"
        return
    }
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-WarningLine "gh is not authenticated; skipping release attestation check"
        return
    }
    & gh attestation verify $ArchivePath --repo $script:Repository --signer-workflow $script:AttestationWorkflow *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Install "release attestation did not verify against $($script:AttestationWorkflow)"
    }
    Write-Info "release attestation verified"
}

function Confirm-Install([string]$Prompt) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return $answer -match '^(?i:y|yes)$'
}

function Install-Bridge([string]$Destination, [string]$Source, [string]$ExpectedHash) {
    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    Set-PrivateDirectoryACL $directory
    Assert-NoReparsePoint $Destination "existing emisar-mcp executable"
    $suffix = [Guid]::NewGuid().ToString("N")
    $staged = Join-Path $directory ".emisar-mcp.new.$suffix.exe"
    $backup = Join-Path $directory ".emisar-mcp.old.$suffix.exe"
    try {
        Copy-Item -LiteralPath $Source -Destination $staged
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $staged).Hash -ine $ExpectedHash) {
            Stop-Install "staged executable checksum changed"
        }
        try {
            if (Test-Path -LiteralPath $Destination) {
                [IO.File]::Replace($staged, $Destination, $backup, $true)
            } else {
                [IO.File]::Move($staged, $Destination)
            }
        } catch {
            Stop-Install "could not replace $Destination; close every MCP client using emisar-mcp and retry"
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash -ine $ExpectedHash) {
            if (Test-Path -LiteralPath $backup) {
                [IO.File]::Replace($backup, $Destination, $null, $true)
            }
            Stop-Install "installed executable checksum changed; the previous version was restored"
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
    }
}

# The reverse of the install path. The bridge removes its own entry, and the
# backup it wrote, from every detected LLM client config and drops the stored
# direct-CLI accounts and rotation state; then the executable goes. That order
# is load-bearing: once the executable is gone nothing can clean a client
# config, so a missing or older bridge is reported, never skipped.
function Uninstall-Bridge([string]$Executable, [string]$AppDataDirectory) {
    $credentials = Join-Path $AppDataDirectory "emisar\credentials"
    if (Test-Path -LiteralPath $credentials) {
        Assert-NoReparsePoint $credentials "credential directory"
    }
    if (Test-Path -LiteralPath $Executable) {
        Assert-NoReparsePoint $Executable "emisar-mcp executable"
        $supportsDisconnect = & {
            $ErrorActionPreference = "Continue"
            & $Executable disconnect --help *> $null
            return $LASTEXITCODE -eq 0
        }
        if (-not $supportsDisconnect) {
            Write-WarningLine "the installed bridge is older than this script and cannot remove its own client entries"
            Write-WarningLine "  reinstall it first, then re-run with -Uninstall"
        } else {
            & {
                $ErrorActionPreference = "Continue"
                & $Executable disconnect --all --forget --yes
                if ($LASTEXITCODE -ne 0) {
                    Write-WarningLine "some LLM client entries could not be removed; remove them by hand"
                }
            }
        }
    }
    if (Test-Path -LiteralPath $credentials) { Remove-Item -LiteralPath $credentials -Recurse -Force }
    if (Test-Path -LiteralPath $Executable) {
        try { Remove-Item -LiteralPath $Executable -Force } catch {
            Stop-Install "could not remove $Executable; close every MCP client using emisar-mcp and retry"
        }
    }
    Remove-UserPath (Split-Path -Parent $Executable)
    Write-Info "uninstalled; connected keys remain valid until revoked at $($script:PortalOrigin)/app/agents; unused installer keys stay hidden and expire after 30 days"
}

if ($env:OS -ne "Windows_NT") { Stop-Install "this installer requires Windows" }
$releaseArchitecture = Get-WindowsReleaseArchitecture
if (-not (Test-SafePortalOrigin $script:PortalOrigin)) { Stop-Install "EMISAR_URL must be an HTTPS origin without credentials, path, query, or fragment" }

$appDataDirectory = $env:APPDATA
$localAppDataDirectory = $env:LOCALAPPDATA
if (-not $InstallDir) { $InstallDir = Join-Path $localAppDataDirectory "Programs\Emisar\bin" }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$executable = Join-Path $InstallDir "emisar-mcp.exe"

if ($Uninstall) {
    if (-not (Confirm-Install "uninstall emisar-mcp, remove its local client entries, and delete all stored CLI accounts and rotation state?")) { Stop-Install "aborted by user" }
    Uninstall-Bridge $executable $appDataDirectory
    return
}

if ($Version) { $Version = Normalize-Version $Version }
$release = Resolve-Release $Version
$versionNumber = $release.Tag.Substring(5)
$archiveRoot = "emisar-mcp-$versionNumber-windows-$releaseArchitecture"
$archiveName = "$archiveRoot.zip"
Write-Info "install target: windows/$releaseArchitecture"
Write-Info "  -> $executable"
Write-Info "$($release.Source): $($release.Tag)"
if (-not (Confirm-Install "install emisar-mcp $($release.Tag)?")) { Stop-Install "aborted by user" }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("emisar-mcp-install." + [Guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $temporaryRoot)
Set-PrivateDirectoryACL $temporaryRoot
try {
    $archivePath = Join-Path $temporaryRoot $archiveName
    $checksumsPath = Join-Path $temporaryRoot "SHA256SUMS-MCP"
    Write-Info "downloading $archiveName"
    Save-WebFile "$($release.Base)/$archiveName" $archivePath
    Save-WebFile "$($release.Base)/SHA256SUMS-MCP" $checksumsPath
    $checksums = [IO.File]::ReadAllText($checksumsPath)
    $match = [regex]::Match($checksums, "(?im)^([0-9a-f]{64})\s+\*?" + [regex]::Escape($archiveName) + "\s*$")
    if (-not $match.Success) { Stop-Install "SHA256SUMS-MCP does not list $archiveName" }
    $actualArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
    if ($actualArchiveHash -ine $match.Groups[1].Value) { Stop-Install "checksum verification failed for $archiveName" }
    Write-Info "checksum verified"
    Test-Attestation $archivePath ([bool]$release.Test)
    Assert-SafeArchive $archivePath $archiveRoot
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryRoot
    $sourceExecutable = Join-Path $temporaryRoot "$archiveRoot\emisar-mcp.exe"
    if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) { Stop-Install "release archive is missing emisar-mcp.exe" }
    Assert-NoReparsePoint $sourceExecutable "release executable"
    $reportedVersion = (& $sourceExecutable --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -ne "emisar-mcp $versionNumber") {
        Stop-Install "downloaded executable reported an unexpected version"
    }
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceExecutable).Hash
    Install-Bridge $executable $sourceExecutable $sourceHash
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Add-UserPath $InstallDir
Write-Host ""
Write-Host "emisar-mcp $versionNumber installed" -ForegroundColor Green
Write-Host "  $executable"
# The bridge owns the connection phase: it detects the LLM clients installed for
# this user, runs ONE browser approval covering the direct CLI and every client
# the operator picks, and writes each client's own configuration shape.
if ($Yes -and -not $ConnectAll) {
    Write-Host ""
    Write-Host "Connect this machine and your LLM clients: emisar-mcp connect"
    Write-Host "Manual client snippets: $($script:PortalOrigin)/app/agents/connect"
} else {
    $connectArguments = @("connect", "--url", $script:PortalOrigin)
    if ($ConnectAll) { $connectArguments += @("--all") }
    & {
        $ErrorActionPreference = "Continue"
        & $executable @connectArguments
        if ($LASTEXITCODE -ne 0) {
            Write-WarningLine "connection setup did not finish; run 'emisar-mcp connect', or use the manual snippets at $($script:PortalOrigin)/app/agents/connect"
        }
    }
}
Write-Host "Open a new terminal before using emisar-mcp from PATH."
