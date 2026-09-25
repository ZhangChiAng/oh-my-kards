#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run setup.ps1 from native Windows PowerShell 7.2 or newer.' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$projectFile = Join-Path $ProjectRoot 'project.godot'
if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) { throw "Missing Godot project: $projectFile" }

$godotVersion = '4.7.2'
$releaseBase = 'https://github.com/godotengine/godot/releases/download/4.7.2-stable'
$archiveName = 'Godot_v4.7.2-stable_win64.exe.zip'
$downloadDirectory = Join-Path $ProjectRoot 'tools/downloads'
$archivePath = Join-Path $downloadDirectory $archiveName
$checksumPath = Join-Path $downloadDirectory 'SHA512-SUMS.txt'
$godotDirectory = Join-Path $ProjectRoot "tools/godot/$godotVersion"
$godotGui = Join-Path $godotDirectory 'Godot_v4.7.2-stable_win64.exe'
$godotConsole = Join-Path $godotDirectory 'Godot_v4.7.2-stable_win64_console.exe'
$mcpDirectory = Join-Path $ProjectRoot 'tools/mcp'
$manifestPath = Join-Path $mcpDirectory 'package.json'
$lockPath = Join-Path $mcpDirectory 'package-lock.json'
$configureScript = Join-Path $ProjectRoot 'tools/configure-mcp.ps1'

foreach ($requiredFile in @($manifestPath, $lockPath, $configureScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required setup file is missing: $requiredFile" }
}

# Check the committed version pins before npm ci can replace node_modules.
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
$pinnedPackages = $manifest.dependencies
foreach ($packageName in @('@satelliteoflove/godot-mcp', '@ryanmazzolini/minimal-godot-mcp', '@modelcontextprotocol/sdk')) {
    if (-not $pinnedPackages.Contains($packageName)) { throw "Required dependency is missing from package.json: $packageName" }
}
foreach ($packageName in $pinnedPackages.Keys) {
    $expected = $pinnedPackages[$packageName]
    if ($expected -notmatch '^\d+\.\d+\.\d+$' -or
        $lock.packages[''].dependencies[$packageName] -cne $expected -or
        $lock.packages["node_modules/$packageName"].version -cne $expected) {
        throw "Expected exact pin $packageName@$expected in both package.json and package-lock.json. Restore the committed manifests before setup."
    }
}
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$lockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
$projectHash = (Get-FileHash -LiteralPath $projectFile -Algorithm SHA256).Hash

if (-not $NodePath) {
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCommand) { throw 'Native Windows node.exe is missing. Install a supported Node LTS version >=22, then rerun setup.' }
    $NodePath = $nodeCommand.Source
}
$NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$npmPath = Join-Path (Split-Path -Parent $NodePath) 'npm.cmd'
if (-not (Test-Path -LiteralPath $npmPath -PathType Leaf)) {
    throw "npm.cmd was not found beside node.exe at $npmPath. Use a complete native Windows Node installation."
}
$nodeVersionText = (& $NodePath --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersionText -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) {
    throw "Node >=22 is required; this executable returned '$nodeVersionText': $NodePath"
}

# Installation never kills an editor. A running copy may lock its executable or
# load the addon while the package files are being replaced.
foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -Like 'Godot*')) {
    try { $processPath = $process.Path } catch { $processPath = $null }
    if (-not $processPath) { throw "Cannot inspect Godot PID $($process.Id). Close this project's Godot instance before setup; no process was terminated." }
    if ($processPath.StartsWith($godotDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The project-local Godot is running (PID $($process.Id)). Close it before setup; no process was terminated."
    }
}

function Receive-SetupFile {
    param([string]$Uri, [string]$Destination)
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { return }
    $partialPath = $Destination + '.partial'
    try {
        Write-Host "Downloading $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $partialPath -TimeoutSec 300
        Move-Item -LiteralPath $partialPath -Destination $Destination -Force
    } catch {
        throw "Download failed for $Uri. Check network access and file permissions, then retry. No permission or TLS checks were bypassed. Details: $($_.Exception.Message)"
    }
}

if (-not ((Test-Path -LiteralPath $godotGui -PathType Leaf) -and (Test-Path -LiteralPath $godotConsole -PathType Leaf))) {
    [void](New-Item -ItemType Directory -Path $downloadDirectory -Force)
    Receive-SetupFile -Uri "$releaseBase/SHA512-SUMS.txt" -Destination $checksumPath
    Receive-SetupFile -Uri "$releaseBase/$archiveName" -Destination $archivePath
    $hashPattern = '^([A-Fa-f0-9]{128})\s+\*?' + [regex]::Escape($archiveName) + '\s*$'
    $matchingHashes = @(foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ($line -match $hashPattern) { $Matches[1].ToUpperInvariant() }
    })
    if ($matchingHashes.Count -ne 1) {
        throw "Expected exactly one SHA512 entry for $archiveName in $checksumPath. Obtain the checksum file from $releaseBase/SHA512-SUMS.txt before retrying."
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA512).Hash
    if ($actualHash -cne $matchingHashes[0]) {
        throw "Godot archive SHA512 mismatch: $archivePath. The cached archive was not extracted; remove or replace this file with a fresh official download before retrying."
    }
    Write-Host "Verified SHA512 for $archiveName"
    [void](New-Item -ItemType Directory -Path $godotDirectory -Force)
    try {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $godotDirectory -Force
    } catch {
        throw "Godot extraction failed in $godotDirectory. Check file permissions and close any process using this installation. Details: $($_.Exception.Message)"
    }
}
foreach ($executable in @($godotGui, $godotConsole)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "The Godot archive did not provide the complete Windows installation: $executable" }
}
$portableMarker = Join-Path $godotDirectory '_sc_'
if (-not (Test-Path -LiteralPath $portableMarker -PathType Leaf)) {
    [IO.File]::WriteAllText($portableMarker, '')
}
$actualGodotVersion = (& $godotConsole --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualGodotVersion -notmatch '^4\.7\.2\.stable(?:\.|$)') {
    throw "Expected Godot 4.7.2 stable; received '$actualGodotVersion' from $godotConsole. The existing installation was not silently replaced."
}
Write-Host "Godot ready: $actualGodotVersion"
Write-Host "Node ready: $nodeVersionText ($NodePath)"

Write-Host 'Installing the committed MCP dependency lock with npm ci...'
& $npmPath ci --prefix $mcpDirectory --cache (Join-Path $mcpDirectory '.npm-cache') --no-audit --no-fund
if ($LASTEXITCODE -ne 0) {
    throw 'npm ci failed. Check the npm output for network, permission, or lockfile errors. No global installation or fallback to latest was attempted.'
}
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $manifestHash -or
    (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -cne $lockHash) {
    throw 'The MCP manifest or lockfile changed during installation. Review that change before continuing; setup will not silently accept different dependencies.'
}
foreach ($packageName in $pinnedPackages.Keys) {
    $installedManifest = Join-Path $mcpDirectory "node_modules/$packageName/package.json"
    $installed = Get-Content -LiteralPath $installedManifest -Raw | ConvertFrom-Json
    if ($installed.version -cne $pinnedPackages[$packageName]) { throw "Installed $packageName does not match its required version." }
}

$runtimeEntry = Join-Path $mcpDirectory 'node_modules/@satelliteoflove/godot-mcp/dist/cli.js'
& $NodePath $runtimeEntry --install-addon $ProjectRoot
if ($LASTEXITCODE -ne 0) { throw 'Godot MCP addon installation failed. Review the installer output; no editor was launched.' }
$pluginConfig = Join-Path $ProjectRoot 'addons/godot_mcp/plugin.cfg'
$runtimeVersion = $pinnedPackages['@satelliteoflove/godot-mcp']
if (-not (Test-Path -LiteralPath $pluginConfig -PathType Leaf) -or
    (Get-Content -LiteralPath $pluginConfig -Raw) -notmatch ('(?m)^version="' + [regex]::Escape($runtimeVersion) + '"\r?$')) {
    throw "The installed Godot MCP addon does not match $runtimeVersion. Review the existing addon before replacing it; setup does not force a downgrade."
}
if ((Get-FileHash -LiteralPath $projectFile -Algorithm SHA256).Hash -cne $projectHash) {
    throw 'project.godot changed during setup. Review it before continuing; the setup script does not edit the project configuration.'
}

try {
    & $configureScript -ProjectRoot $ProjectRoot -NodePath $NodePath
} catch {
    throw "Project-local MCP configuration failed. Existing permission restrictions remain in effect; no global config fallback was used. Details: $($_.Exception.Message)"
}
Write-Host 'Setup complete. Godot and MCP are installed locally; no editor or game was started.'
Write-Host 'Reconnect the Codex client to load this trusted project configuration, then run tools/verify.ps1 and tools/launch-editor.ps1 as documented.'
