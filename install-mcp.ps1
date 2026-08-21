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
$script:ConfiguredClients = New-Object Collections.Generic.List[string]
$script:ConnectionPhaseRan = $false
$script:CLIAuthenticated = $false

function Write-Info([string]$Message) {
    Write-Host "[install-mcp] $Message" -ForegroundColor Blue
}

function Write-WarningLine([string]$Message) {
    Write-Warning "[install-mcp] $Message"
}

function Stop-Install([string]$Message) {
    throw "[install-mcp] $Message"
}

function Test-SafePortalOrigin([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
    if ($uri.AbsolutePath -ne "/") { return $false }
    if ($uri.Scheme -eq "https") { return $true }
    return $uri.Scheme -eq "http" -and $env:EMISAR_ALLOW_INSECURE -eq "1" -and $uri.IsLoopback
}

function Test-SafeConfigValue([string]$Value) {
    return $Value.Length -gt 0 -and $Value.IndexOfAny([char[]]@([char]0, "`r", "`n")) -lt 0
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

function New-Client([string]$Label, [string]$Id, [string]$Kind, [string]$Path, [string]$Marker = "") {
    if (-not $Marker) { $Marker = Split-Path -Parent $Path }
    return [pscustomobject]@{ Label = $Label; Id = $Id; Kind = $Kind; Path = $Path; Marker = $Marker }
}

function Find-Clients([string]$HomeDirectory, [string]$AppDataDirectory) {
    $clients = New-Object Collections.Generic.List[object]
    $candidates = @(
        (New-Client "Claude Code" "claude-code" "json" (Join-Path $HomeDirectory ".claude.json") (Join-Path $HomeDirectory ".claude")),
        (New-Client "Claude Desktop" "claude-desktop" "json" (Join-Path $AppDataDirectory "Claude\claude_desktop_config.json")),
        (New-Client "Cursor" "cursor" "json" (Join-Path $HomeDirectory ".cursor\mcp.json")),
        (New-Client "Gemini CLI" "gemini" "json" (Join-Path $HomeDirectory ".gemini\settings.json")),
        (New-Client "Codex CLI" "codex" "toml" (Join-Path $HomeDirectory ".codex\config.toml")),
        (New-Client "OpenClaw" "openclaw" "openclaw" (Join-Path $HomeDirectory ".openclaw\openclaw.json")),
        (New-Client "OpenCode" "opencode" "opencode" (Join-Path $HomeDirectory ".config\opencode\opencode.json")),
        (New-Client "Windsurf" "windsurf" "json" (Join-Path $HomeDirectory ".codeium\windsurf\mcp_config.json")),
        (New-Client "Pi" "pi" "json" (Join-Path $HomeDirectory ".pi\agent\mcp.json")),
        (New-Client "Copilot CLI" "copilot-cli" "copilot" (Join-Path $HomeDirectory ".copilot\mcp-config.json")),
        (New-Client "Zed" "zed" "zed" (Join-Path $AppDataDirectory "Zed\settings.json")),
        (New-Client "Hermes" "hermes" "hermes" (Join-Path $HomeDirectory ".hermes\config.yaml")),
        (New-Client "Goose" "goose" "goose" (Join-Path $HomeDirectory ".config\goose\config.yaml")),
        (New-Client "Grok CLI" "grok" "toml" (Join-Path $HomeDirectory ".grok\config.toml"))
    )
    foreach ($client in $candidates) {
        if ((Test-Path -LiteralPath $client.Path -PathType Leaf) -or (Test-Path -LiteralPath $client.Marker)) {
            $clients.Add($client)
        }
    }
    return $clients.ToArray()
}

function Test-ClientConnected($Client) {
    if (-not (Test-Path -LiteralPath $Client.Path -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($Client.Path)
    switch ($Client.Kind) {
        "toml" { return $text -match '(?m)^\[mcp_servers\.emisar\]\s*$' }
        "hermes" { return $text -match '(?m)^\s{2}emisar:\s*$' }
        "goose" { return $text -match '(?m)^\s{2}emisar:\s*$' }
        default { return $text -match '"emisar"\s*:' }
    }
}

function Set-PropertyValue($Object, [string]$Name, $Value) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Get-OrAddObject($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $value = [pscustomobject]@{}
        Set-PropertyValue $Object $Name $value
        return $value
    }
    if ($null -eq $property.Value -or $property.Value -is [string] -or $property.Value -is [ValueType] -or $property.Value -is [array]) {
        throw "existing config key is not an object: $Name"
    }
    return $property.Value
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    Assert-NoReparsePoint $Path "client config"
    $temporary = Join-Path $directory (".emisar-mcp." + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
        if (Test-Path -LiteralPath $Path) {
            Assert-NoReparsePoint "$Path.emisar-bak" "client config backup"
            Copy-Item -LiteralPath $Path -Destination "$Path.emisar-bak" -Force
            Set-PrivateFileACL "$Path.emisar-bak"
            [IO.File]::Replace($temporary, $Path, $null, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
        Set-PrivateFileACL $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function New-ClientEnvironment([string]$Key, [string]$ClientId) {
    return [ordered]@{
        EMISAR_URL = $script:PortalOrigin
        EMISAR_API_KEY = $Key
        EMISAR_CLIENT = $ClientId
    }
}

function Set-JsonClientConfig($Client, [string]$Executable, [string]$Key) {
    if (Test-Path -LiteralPath $Client.Path) {
        $raw = [IO.File]::ReadAllText($Client.Path)
        if ($raw -match '(?m)(^|[^:])//|/\*') {
            throw "commented JSON must be updated from the portal snippet"
        }
        $config = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    } else {
        $config = [pscustomobject]@{}
    }
    if ($null -eq $config -or $config -is [array]) { throw "top-level JSON is not an object" }
    $environment = New-ClientEnvironment $Key $Client.Id
    switch ($Client.Kind) {
        "openclaw" {
            $mcp = Get-OrAddObject $config "mcp"
            $container = Get-OrAddObject $mcp "servers"
            $entry = [ordered]@{ command = $Executable; env = $environment }
        }
        "opencode" {
            $container = Get-OrAddObject $config "mcp"
            $entry = [ordered]@{ type = "local"; command = @($Executable); enabled = $true; environment = $environment }
        }
        "copilot" {
            $container = Get-OrAddObject $config "mcpServers"
            $entry = [ordered]@{ type = "local"; command = $Executable; args = @(); env = $environment; tools = @("*") }
        }
        "zed" {
            $container = Get-OrAddObject $config "context_servers"
            $entry = [ordered]@{ source = "custom"; command = $Executable; args = @(); env = $environment }
        }
        default {
            $container = Get-OrAddObject $config "mcpServers"
            $entry = [ordered]@{ command = $Executable; env = $environment }
        }
    }
    Set-PropertyValue $container "emisar" $entry
    Write-AtomicText $Client.Path (($config | ConvertTo-Json -Depth 20) + "`r`n")
}

function Quote-ConfigString([string]$Value) {
    return ($Value | ConvertTo-Json -Compress)
}

function Set-TextClientConfig($Client, [string]$Executable, [string]$Key) {
    $existing = if (Test-Path -LiteralPath $Client.Path) { [IO.File]::ReadAllText($Client.Path) } else { "" }
    if ($Client.Kind -eq "toml") {
        if ($existing -match '(?m)^\[mcp_servers\.emisar\]\s*$') { return }
        $block = "[mcp_servers.emisar]`r`ncommand = $(Quote-ConfigString $Executable)`r`nenv = { EMISAR_URL = $(Quote-ConfigString $script:PortalOrigin), EMISAR_API_KEY = $(Quote-ConfigString $Key), EMISAR_CLIENT = $(Quote-ConfigString $Client.Id) }`r`n"
    } elseif ($Client.Kind -eq "hermes") {
        if ($existing -match '(?m)^mcp_servers:\s*$') { throw "existing mcp_servers YAML must be updated from the portal snippet" }
        $block = "mcp_servers:`r`n  emisar:`r`n    command: $(Quote-ConfigString $Executable)`r`n    env:`r`n      EMISAR_URL: $(Quote-ConfigString $script:PortalOrigin)`r`n      EMISAR_API_KEY: $(Quote-ConfigString $Key)`r`n      EMISAR_CLIENT: hermes`r`n"
    } else {
        if ($existing -match '(?m)^extensions:\s*$') { throw "existing extensions YAML must be updated from the portal snippet" }
        $block = "extensions:`r`n  emisar:`r`n    name: emisar`r`n    cmd: $(Quote-ConfigString $Executable)`r`n    args: []`r`n    enabled: true`r`n    envs:`r`n      EMISAR_URL: $(Quote-ConfigString $script:PortalOrigin)`r`n      EMISAR_API_KEY: $(Quote-ConfigString $Key)`r`n      EMISAR_CLIENT: goose`r`n    type: stdio`r`n    timeout: 300`r`n"
    }
    if ($existing.Trim()) { $existing = $existing.TrimEnd() + "`r`n`r`n" }
    Write-AtomicText $Client.Path ($existing + $block)
}

function Install-ClientConfig($Client, [string]$Executable, [string]$Key) {
    if (-not (Test-SafeConfigValue $script:PortalOrigin) -or -not (Test-SafeConfigValue $Executable) -or -not (Test-SafeConfigValue $Key)) {
        throw "a config value contains unsupported characters"
    }
    if ($Client.Kind -in @("toml", "hermes", "goose")) {
        Set-TextClientConfig $Client $Executable $Key
    } else {
        Set-JsonClientConfig $Client $Executable $Key
    }
}

function Invoke-JsonPost([string]$Url, $Body) {
    $uri = [Uri]$Url
    Test-TrustedWebUri $uri
    $client = New-WebClient @{ Accept = "application/json" }
    try {
        $json = $Body | ConvertTo-Json -Compress -Depth 8
        $content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, "application/json")
        $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
        Test-TrustedWebUri $response.RequestMessage.RequestUri
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = $null
        try { if ($text) { $parsed = $text | ConvertFrom-Json } } catch { }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed }
    } finally {
        $client.Dispose()
    }
}

function Test-APIKey([string]$Key) {
    return $Key.Length -eq 47 -and $Key -match '^emk-[A-Za-z0-9_-]{43}$'
}

function Request-DeviceGrant([string[]]$ClientIds) {
    $response = Invoke-JsonPost "$($script:PortalOrigin)/api/mcp/device_authorization" @{ requested_clients = $ClientIds }
    if ($response.Status -ne 200 -or $null -eq $response.Body) { throw "could not start connection approval" }
    $grant = $response.Body
    if ([string]$grant.device_code -notmatch '^emdg-[A-Za-z0-9_-]{16,128}$' -or
        [string]$grant.user_code -notmatch '^[A-Z0-9-]{4,32}$') {
        throw "the portal returned an invalid device grant"
    }
    $verification = [Uri]([string]$grant.verification_uri_complete)
    $origin = [Uri]$script:PortalOrigin
    if ($verification.Scheme -ne $origin.Scheme -or $verification.Host -ne $origin.Host -or $verification.Port -ne $origin.Port) {
        throw "the portal returned an invalid verification URL"
    }
    $parsedInterval = 0
    $interval = 5
    if ([int]::TryParse([string]$grant.interval, [ref]$parsedInterval)) { $interval = [Math]::Min(120, [Math]::Max(1, $parsedInterval)) }
    $parsedExpires = 0
    $expires = 900
    if ([int]::TryParse([string]$grant.expires_in, [ref]$parsedExpires)) { $expires = [Math]::Min(3600, [Math]::Max(60, $parsedExpires)) }
    return [pscustomobject]@{
        DeviceCode = [string]$grant.device_code
        UserCode = [string]$grant.user_code
        Verification = $verification.AbsoluteUri
        Interval = $interval
        Expires = $expires
    }
}

function Wait-DeviceGrant($Grant) {
    Write-Host ""
    Write-Host "Approve this machine in your browser" -ForegroundColor White
    Write-Host "  $($Grant.Verification)"
    if ($env:EMISAR_MCP_TEST_NO_BROWSER -ne "1") {
        try { Start-Process $Grant.Verification | Out-Null } catch { }
    }
    Write-Host "Waiting for approval (Ctrl-C skips CLI/client setup)..."
    $deadline = [DateTime]::UtcNow.AddSeconds($Grant.Expires)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $Grant.Interval
        $response = Invoke-JsonPost "$($script:PortalOrigin)/api/mcp/device_token" @{ device_code = $Grant.DeviceCode }
        if ($response.Status -eq 200 -and $null -ne $response.Body -and $null -ne $response.Body.client_keys) {
            Write-Host "Approved." -ForegroundColor Green
            return $response.Body
        }
        if ($response.Status -eq 400 -and $null -ne $response.Body) {
            $code = [string]$response.Body.error
            if ($code -eq "authorization_pending" -or -not $code) { continue }
            if ($code -eq "access_denied") { throw "the request was denied in the portal" }
            if ($code -in @("expired_token", "invalid_grant")) { throw "the approval code expired" }
            if ($code -match '^[A-Za-z0-9._-]{1,40}$') { throw "the portal reported $code" }
        }
    }
    throw "the approval code expired"
}

function Get-ClientKey($TokenResponse, [string]$ClientId) {
    $property = $TokenResponse.client_keys.PSObject.Properties[$ClientId]
    if ($null -eq $property) { return "" }
    return [string]$property.Value
}

function Import-CLIAuth([string]$Executable, [string]$Origin, [string]$Payload) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = "auth import `"$Origin`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    $payloadBytes = $script:Utf8NoBom.GetBytes($Payload)
    try {
        $consoleInputEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = $script:Utf8NoBom
            $started = $process.Start()
        } finally {
            [Console]::InputEncoding = $consoleInputEncoding
        }
        if (-not $started) { throw "could not start emisar-mcp auth import" }
        $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        [Array]::Clear($payloadBytes, 0, $payloadBytes.Length)
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Configure-Clients([string]$Executable, [string]$HomeDirectory, [string]$AppDataDirectory) {
    if ($Yes -and -not $ConnectAll) { return }
    $script:ConnectionPhaseRan = $true
    $clients = @(Find-Clients $HomeDirectory $AppDataDirectory)
    $selected = New-Object Collections.Generic.List[object]
    foreach ($client in $clients) {
        if (Test-ClientConnected $client) {
            Write-Host ("  {0,-16} already connected" -f $client.Label)
            continue
        }
        $connect = $ConnectAll
        if (-not $ConnectAll) {
            $answer = Read-Host "Add emisar to $($client.Label)? [y/N]"
            $connect = $answer -match '^(?i:y|yes)$'
        }
        if ($connect) { $selected.Add($client) }
    }

    $urlWasSet = Test-Path Env:EMISAR_URL
    $keyWasSet = Test-Path Env:EMISAR_API_KEY
    $savedUrl = $env:EMISAR_URL
    $savedKey = $env:EMISAR_API_KEY
    $storedAccountWorks = $false
    try {
        Remove-Item Env:EMISAR_URL -ErrorAction SilentlyContinue
        Remove-Item Env:EMISAR_API_KEY -ErrorAction SilentlyContinue
        $storedAccountWorks = & {
            $ErrorActionPreference = "Continue"
            & $Executable auth status $script:PortalOrigin *> $null
            if ($LASTEXITCODE -ne 0) { return $false }
            & $Executable list_tools --json *> $null
            return $LASTEXITCODE -eq 0
        }
    } finally {
        if ($urlWasSet) { $env:EMISAR_URL = $savedUrl } else { Remove-Item Env:EMISAR_URL -ErrorAction SilentlyContinue }
        if ($keyWasSet) { $env:EMISAR_API_KEY = $savedKey } else { Remove-Item Env:EMISAR_API_KEY -ErrorAction SilentlyContinue }
    }
    $cliNeedsAuth = -not $storedAccountWorks
    $ids = New-Object Collections.Generic.List[string]
    if ($cliNeedsAuth) { $ids.Add("emisar-mcp-cli") }
    foreach ($client in $selected) { $ids.Add($client.Id) }
    if ($ids.Count -eq 0) {
        $script:CLIAuthenticated = $true
        return
    }

    $grant = Request-DeviceGrant ($ids.ToArray())
    $token = Wait-DeviceGrant $grant
    $keys = @{}
    foreach ($id in $ids) {
        $key = Get-ClientKey $token $id
        if (-not (Test-APIKey $key)) { throw "the portal did not deliver every requested key" }
        $keys[$id] = $key
    }

    if ($cliNeedsAuth) {
        $approval = $token | ConvertTo-Json -Depth 6 -Compress
        try {
            $importExitCode = Import-CLIAuth $Executable $script:PortalOrigin $approval
        } finally {
            $approval = $null
        }
        if ($importExitCode -ne 0) { throw "could not store the direct CLI credential" }
        $script:CLIAuthenticated = $true
    } else {
        $script:CLIAuthenticated = $true
    }
    foreach ($client in $selected) {
        try {
            Install-ClientConfig $client $Executable ([string]$keys[$client.Id])
            $script:ConfiguredClients.Add("$($client.Label): $($client.Path)")
            Write-Host ("  {0,-16} connected -> {1}" -f $client.Label, $client.Path) -ForegroundColor Green
        } catch {
            $innerType = if ($null -ne $_.Exception.InnerException) {
                $_.Exception.InnerException.GetType().FullName
            } else {
                "none"
            }
            $targetMethod = if ($null -ne $_.Exception.InnerException -and $null -ne $_.Exception.InnerException.TargetSite) {
                $_.Exception.InnerException.TargetSite.Name
            } else {
                "none"
            }
            Write-Verbose "$($client.Label) config update failed at line $($_.InvocationInfo.ScriptLineNumber) with $($_.Exception.GetType().FullName) (inner: $innerType; target: $targetMethod)"
            Write-WarningLine "$($client.Label): could not update $($client.Path); use Custom at $($script:PortalOrigin)/app/agents/connect"
        }
    }
    $keys.Clear()
    $token = $null
}

function Remove-JsonClientConfig($Client) {
    if (-not (Test-Path -LiteralPath $Client.Path)) { return }
    try {
        $raw = [IO.File]::ReadAllText($Client.Path)
        if ($raw -match '(?m)(^|[^:])//|/\*') { throw "commented JSON" }
        $config = $raw | ConvertFrom-Json
        $containers = switch ($Client.Kind) {
            "openclaw" { @("mcp", "servers") }
            "opencode" { @("mcp") }
            "zed" { @("context_servers") }
            default { @("mcpServers") }
        }
        $node = $config
        foreach ($name in $containers) {
            $property = $node.PSObject.Properties[$name]
            if ($null -eq $property) { return }
            $node = $property.Value
        }
        [void]$node.PSObject.Properties.Remove("emisar")
        Write-AtomicText $Client.Path (($config | ConvertTo-Json -Depth 20) + "`r`n")
    } catch {
        Write-WarningLine "$($Client.Label): could not remove emisar from $($Client.Path); remove it manually"
    }
}

function Remove-TextClientConfig($Client) {
    if (-not (Test-Path -LiteralPath $Client.Path)) { return }
    $text = [IO.File]::ReadAllText($Client.Path)
    if ($Client.Kind -eq "toml") {
        $text = [regex]::Replace($text, '(?ms)^\[mcp_servers\.emisar\]\s*\r?\n.*?(?=^\[|\z)', '')
    } elseif ($Client.Kind -eq "hermes") {
        $text = [regex]::Replace($text, '(?ms)^mcp_servers:\s*\r?\n  emisar:\s*\r?\n(?:    .*\r?\n?)*', '')
    } else {
        $text = [regex]::Replace($text, '(?ms)^extensions:\s*\r?\n  emisar:\s*\r?\n(?:    .*\r?\n?)*', '')
    }
    Write-AtomicText $Client.Path $text
}

function Uninstall-Bridge([string]$Executable, [string]$HomeDirectory, [string]$AppDataDirectory) {
    $credentials = Join-Path $AppDataDirectory "emisar\credentials"
    if (Test-Path -LiteralPath $credentials) {
        Assert-NoReparsePoint $credentials "credential directory"
    }
    if (Test-Path -LiteralPath $Executable) {
        Assert-NoReparsePoint $Executable "emisar-mcp executable"
    }
    foreach ($client in @(Find-Clients $HomeDirectory $AppDataDirectory)) {
        if ($client.Kind -in @("toml", "hermes", "goose")) { Remove-TextClientConfig $client } else { Remove-JsonClientConfig $client }
        if (Test-Path -LiteralPath "$($client.Path).emisar-bak") {
            Assert-NoReparsePoint "$($client.Path).emisar-bak" "client config backup"
            Remove-Item -LiteralPath "$($client.Path).emisar-bak" -Force
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
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    Stop-Install "this release supports 64-bit x86 Windows only"
}
if (-not (Test-SafePortalOrigin $script:PortalOrigin)) { Stop-Install "EMISAR_URL must be an HTTPS origin without credentials, path, query, or fragment" }

$homeDirectory = if ($env:EMISAR_MCP_TEST_HOME) { $env:EMISAR_MCP_TEST_HOME } else { $HOME }
$appDataDirectory = if ($env:EMISAR_MCP_TEST_APPDATA) { $env:EMISAR_MCP_TEST_APPDATA } else { $env:APPDATA }
$localAppDataDirectory = if ($env:EMISAR_MCP_TEST_LOCALAPPDATA) { $env:EMISAR_MCP_TEST_LOCALAPPDATA } else { $env:LOCALAPPDATA }
if (-not $InstallDir) { $InstallDir = Join-Path $localAppDataDirectory "Programs\Emisar\bin" }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$executable = Join-Path $InstallDir "emisar-mcp.exe"

if ($Uninstall) {
    if (-not (Confirm-Install "uninstall emisar-mcp, remove its local client entries, and delete all stored CLI accounts and rotation state?")) { Stop-Install "aborted by user" }
    Uninstall-Bridge $executable $homeDirectory $appDataDirectory
    return
}

if ($Version) { $Version = Normalize-Version $Version }
$release = Resolve-Release $Version
$versionNumber = $release.Tag.Substring(5)
$archiveRoot = "emisar-mcp-$versionNumber-windows-amd64"
$archiveName = "$archiveRoot.zip"
Write-Info "install target: windows/amd64"
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
try {
    Configure-Clients $executable $homeDirectory $appDataDirectory
} catch {
    Write-WarningLine "$($_.Exception.Message); run emisar-mcp auth for the CLI, or connect an LLM client at $($script:PortalOrigin)/app/agents/connect"
}
if ($script:ConfiguredClients.Count -gt 0) {
    Write-Host ""
    Write-Host "Restart each connected client to pick up emisar."
} elseif (-not $script:ConnectionPhaseRan) {
    Write-Host ""
    Write-Host "Authenticate the CLI in a terminal: emisar-mcp auth"
    Write-Host "Connect an LLM client: $($script:PortalOrigin)/app/agents/connect"
}
if ($script:CLIAuthenticated) {
    Write-Host "Try it: emisar-mcp list_tools"
}
Write-Host "Open a new terminal before using emisar-mcp from PATH."
