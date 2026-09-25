#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$NodePath,
    [switch]$Disabled
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot') -PathType Leaf)) { throw 'Missing project.godot.' }
if (-not $NodePath) { $NodePath = (Get-Command node.exe -ErrorAction Stop).Source }
$NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$runtimeEntry = Join-Path $ProjectRoot 'tools/mcp/node_modules/@satelliteoflove/godot-mcp/dist/cli.js'
$diagnosticsEntry = Join-Path $ProjectRoot 'tools/mcp/diagnostics-server.mjs'
foreach ($entry in @($runtimeEntry, $diagnosticsEntry)) {
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw "MCP package entry is missing: $entry" }
}

# JSON strings are valid TOML basic strings and safely encode Windows backslashes.
$nodeToml = ConvertTo-Json -InputObject $NodePath -Compress
$rootToml = ConvertTo-Json -InputObject $ProjectRoot -Compress
$runtimeToml = ConvertTo-Json -InputObject $runtimeEntry -Compress
$diagnosticsToml = ConvertTo-Json -InputObject $diagnosticsEntry -Compress
$enabledToml = if ($Disabled) { 'false' } else { 'true' }
$beginMarker = '# BEGIN OH-MY-KARDS MANAGED GODOT MCP'
$endMarker = '# END OH-MY-KARDS MANAGED GODOT MCP'
$managedText = @"
$beginMarker
[mcp_servers.godot_runtime]
enabled = $enabledToml
command = $nodeToml
args = [$runtimeToml]
cwd = $rootToml
startup_timeout_sec = 60
tool_timeout_sec = 60

[mcp_servers.godot_runtime.env]
GODOT_HOST = '127.0.0.1'
GODOT_PORT = '6550'

[mcp_servers.godot_diagnostics]
enabled = $enabledToml
command = $nodeToml
args = [$diagnosticsToml]
cwd = $rootToml
startup_timeout_sec = 60
tool_timeout_sec = 60

[mcp_servers.godot_diagnostics.env]
GODOT_WORKSPACE_PATH = $rootToml
GODOT_LSP_PORT = '6005'
GODOT_DAP_PORT = '6006'
$endMarker
"@
$configDirectory = Join-Path $ProjectRoot '.codex'
$configPath = Join-Path $configDirectory 'config.toml'
$existingText = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
$blockPattern = '(?ms)^' + [regex]::Escape($beginMarker) + '\r?\n.*?^' + [regex]::Escape($endMarker) + '(?=\r?$)'
$managedMatches = [regex]::Matches($existingText, $blockPattern)
$markerCount = [regex]::Matches($existingText, '(?m)^# (?:BEGIN|END) OH-MY-KARDS MANAGED GODOT MCP\r?$').Count
if ($managedMatches.Count -gt 1 -or $markerCount -ne 2 * $managedMatches.Count) { throw 'Existing MCP managed markers are inconsistent. No config was changed.' }
$unmanagedText = [regex]::Replace($existingText, $blockPattern, '')
if ($unmanagedText -match '(?m)^\s*\[\s*mcp_servers\s*\.\s*["'']?godot_(?:runtime|diagnostics)["'']?(?:\s*[.\]])' -or
    $unmanagedText -match '(?m)^\s*["'']?godot_(?:runtime|diagnostics)["'']?\s*=') {
    throw 'An existing Godot MCP configuration is outside the managed block. Refusing to overwrite unrelated settings; merge it explicitly.'
}
if ($managedMatches.Count -eq 1) {
    $match = $managedMatches[0]
    $newText = $existingText.Substring(0, $match.Index) + $managedText + $existingText.Substring($match.Index + $match.Length)
} else {
    $separator = if ($existingText.Length -gt 0) { "`r`n`r`n" } else { '' }
    $newText = $existingText + $separator + $managedText + "`r`n"
}
if ($newText -ceq $existingText) { Write-Host "MCP configuration is current: $configPath"; return }
if ($PSCmdlet.ShouldProcess($configPath, 'Write project-local Godot MCP configuration while preserving other settings')) {
    # Let protected-directory permission errors surface; never redirect into global config.
    [void](New-Item -ItemType Directory -Path $configDirectory -Force)
    [IO.File]::WriteAllText($configPath, $newText, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote project-local MCP configuration: $configPath"
    Write-Host 'Reconnect the client, open this trusted project in Godot, and enable the Godot MCP addon before verifying tools.'
}
