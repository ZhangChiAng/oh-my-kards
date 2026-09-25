#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotPath
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot') -PathType Leaf)) { throw 'Missing project.godot.' }
if (-not $GodotPath) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'tools/godot/4.7.2') -Filter '*.exe' -File -Recurse | Where-Object Name -NotLike '*_console.exe')
    if ($candidates.Count -ne 1) { throw 'Expected one Godot GUI executable under tools/godot/4.7.2. Supply -GodotPath explicitly.' }
    $GodotPath = $candidates[0].FullName
}
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path
$artifactDirectory = Join-Path $ProjectRoot 'artifacts'
$recordPath = Join-Path $artifactDirectory 'editor-process.json'
if (Test-Path -LiteralPath $recordPath) {
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $existingProcess = Get-Process -Id $record.process_id -ErrorAction SilentlyContinue
    if ($existingProcess -and $record.project_path -eq $ProjectRoot -and $record.start_time_utc -and
        [Math]::Abs(($existingProcess.StartTime.ToUniversalTime() - ([datetime]$record.start_time_utc).ToUniversalTime()).TotalSeconds) -lt 2) {
        throw "This project's editor is already running (PID $($record.process_id))."
    }
}

$occupiedPorts = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
    Where-Object { $_.Port -in @(6005, 6006, 6007, 6550) })
if ($occupiedPorts.Count -gt 0) {
    throw "Godot ports are occupied: $($occupiedPorts -join ', '). Inspect the owning process before retrying; no process was stopped."
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $GodotPath
$startInfo.WorkingDirectory = $ProjectRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $false
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
[void](New-Item -ItemType Directory -Path $artifactDirectory -Force)
$editorLogPath = Join-Path $artifactDirectory 'editor.log'
foreach ($argument in @('--editor', '--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--lsp-port', '6005', '--dap-port', '6006', '--debug-server', 'tcp://127.0.0.1:6007', '--log-file', $editorLogPath)) {
    [void]$startInfo.ArgumentList.Add($argument)
}
$editorProcess = [Diagnostics.Process]::Start($startInfo)
if (-not $editorProcess) { throw 'Godot editor did not start.' }
$record = [ordered]@{
    process_id = $editorProcess.Id
    start_time_utc = $editorProcess.StartTime.ToUniversalTime().ToString('o')
    project_path = $ProjectRoot
    godot_path = $GodotPath
    log_path = $editorLogPath
    recorded_at = [datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
Write-Host "Godot editor started: PID $($editorProcess.Id)"
Write-Host "Project: $ProjectRoot"
Write-Host 'Confirm that the editor is visible on your desktop; process creation alone does not prove visibility.'
$editorProcess.Dispose()
