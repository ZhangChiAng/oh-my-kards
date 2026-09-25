#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Profile,
    [switch]$GeometryDebug,
    [int]$Seed = 20260917,
    [string]$CardLibraryRoot
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ($Profile) {
    if (-not $Profile.StartsWith('res://resources/art/')) { throw 'Profile must be a project resource under res://resources/art/.' }
    $profileFile = [IO.Path]::GetFullPath((Join-Path $projectRoot $Profile.Substring(6)))
    $profileRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'resources/art')) + [IO.Path]::DirectorySeparatorChar
    if (-not $profileFile.StartsWith($profileRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $profileFile -PathType Leaf)) {
        throw "Profile not found under resources/art: $Profile"
    }
}
$engine = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tools/godot/4.7.2') -Filter '*.exe' -File | Where-Object Name -NotLike '*_console.exe')
if ($engine.Count -ne 1) { throw 'Run tools/setup.ps1 to install the project Godot version.' }
$scene = 'res://scenes/battle.tscn'
$artifactsPath = Join-Path $projectRoot 'artifacts'
[void][IO.Directory]::CreateDirectory($artifactsPath)
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $engine[0].FullName
$startInfo.WorkingDirectory = $projectRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $false
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
$battleArguments = @('--path', $projectRoot, '--rendering-method', 'gl_compatibility', '--maximized', $scene, '--', '--seed', "$Seed")
if ($Profile) { $battleArguments += @('--profile', $Profile) }
if ($GeometryDebug) { $battleArguments += '--geometry-debug' }
if ($CardLibraryRoot) { $battleArguments += @('--card-library-root', [IO.Path]::GetFullPath($CardLibraryRoot)) }
foreach ($argument in $battleArguments) {
    [void]$startInfo.ArgumentList.Add($argument)
}
$game = [Diagnostics.Process]::Start($startInfo)
if (-not $game) { throw 'Battle did not start.' }
$record = @{process_id=$game.Id; start_time_utc=$game.StartTime.ToUniversalTime().ToString('o'); project_path=$projectRoot; scene_path=$scene; profile_override=$Profile; geometry_debug=[bool]$GeometryDebug}
[IO.File]::WriteAllText((Join-Path $artifactsPath 'battle-process.json'), ($record | ConvertTo-Json))
Write-Host "Battle started: PID $($game.Id)."
$game.Dispose()
