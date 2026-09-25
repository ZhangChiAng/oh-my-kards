#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GodotPath,
    [ValidateSet('prototype')][string]$Label = 'prototype',
    [switch]$SkipUi,
    [switch]$Art,
    [switch]$Workshop,
    [switch]$Sizes,
    [ValidateRange(1, 3600)][int]$ImportTimeoutSeconds = 120,
    [ValidateRange(1, 3600)][int]$RulesTimeoutSeconds = 30,
    [ValidateRange(1, 3600)][int]$UiTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$ScenePath = 'res://scenes/battle.tscn'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.godot') -PathType Leaf)) {
    throw "Missing project.godot in $ProjectRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $ScenePath.Substring(6)) -PathType Leaf)) {
    throw "Missing target scene: $ScenePath"
}
if (-not $GodotPath) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'tools/godot/4.7.2') -Filter '*_console.exe' -File -Recurse)
    if ($candidates.Count -ne 1) { throw 'Expected one Godot console executable under tools/godot/4.7.2. Supply -GodotPath explicitly.' }
    $GodotPath = $candidates[0].FullName
}
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path

function Assert-EditorClosed {
    $recordPath = Join-Path $ProjectRoot 'artifacts/editor-process.json'
    if (Test-Path -LiteralPath $recordPath) {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($record.project_path -eq $ProjectRoot) {
            $knownProcess = Get-Process -Id $record.process_id -ErrorAction SilentlyContinue
            if ($knownProcess -and $record.start_time_utc -and
                [Math]::Abs(($knownProcess.StartTime.ToUniversalTime() - ([datetime]$record.start_time_utc).ToUniversalTime()).TotalSeconds) -lt 2) {
                throw "This project's editor is still running (PID $($record.process_id)). Close it before CLI verification."
            }
        }
    }
    $godotProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -Like 'Godot*')
    if ($godotProcesses.Count -eq 0) { return }
    try {
        $processDetails = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" -ErrorAction Stop)
    } catch {
        throw 'Godot processes exist, but their command lines cannot be inspected. Close this project in Godot before verification; no process was terminated.'
    }
    $escapedRoot = [regex]::Escape($ProjectRoot)
    $escapedProject = [regex]::Escape((Join-Path $ProjectRoot 'project.godot'))
    $pathPattern = '(?i)(?:^|\s)--path(?:=|\s+)(?:"' + $escapedRoot + '\\?"|' + $escapedRoot + '\\?(?=\s|$))'
    $projectPattern = '(?i)(?:^|\s)(?:"' + $escapedProject + '"|' + $escapedProject + '(?=\s|$))'
    foreach ($detail in $processDetails) {
        $commandLine = ([string]$detail.CommandLine).Replace('/', '\')
        if (-not $commandLine) {
            throw "Cannot inspect Godot PID $($detail.ProcessId). Close this project's editor before verification; no process was terminated."
        }
        if ($commandLine -match '(?i)(?:^|\s)(?:--editor|-e)(?:\s|$)' -and
            ($commandLine -match $pathPattern -or $commandLine -match $projectPattern)) {
            throw "This project's editor is still running (PID $($detail.ProcessId)). Close it before CLI verification."
        }
    }
}

Assert-EditorClosed
$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
$runDirectory = Join-Path $ProjectRoot "artifacts/$runId"
[void](New-Item -ItemType Directory -Path $runDirectory)
$startedAt = [datetime]::UtcNow

function Invoke-GodotProcess {
    param([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Executable = $GodotPath)
    # Select the isolated library before any scene or store can initialize it.
    if ($Arguments -contains '--script' -and $Arguments -notcontains '--card-library-root') {
        $libraryName = if ($Name -like 'workshop-persistence-*') { 'persistent-library' } else { "$Name-library" }
        $Arguments += @('--card-library-root', (Join-Path $runDirectory $libraryName))
    }
    $stdoutPath = Join-Path $runDirectory "$Name-stdout.log"
    $stderrPath = Join-Path $runDirectory "$Name-stderr.log"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $step = [ordered]@{
        status = 'failed'; started_at = [datetime]::UtcNow.ToString('o'); duration_seconds = 0
        executable = $Executable; arguments = $Arguments; exit_code = $null; timed_out = $false
        stdout_log = $stdoutPath; stderr_log = $stderrPath; failures = @()
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stdout = ''
    $stderr = ''
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $step.process_id = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $step.timed_out = $true
            $step.failures += "Wall-clock timeout after $TimeoutSeconds seconds."
            # This Process object belongs only to the command launched above.
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { throw 'Timed-out child did not exit after termination.' }
        }
        if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
            throw 'Child output streams did not close.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $step.exit_code = $process.ExitCode
        if ($step.exit_code -ne 0) { $step.failures += "Process exited with code $($step.exit_code)." }
        if (($stdout + "`n" + $stderr) -match '(?im)(?:^|\s)(?:SCRIPT ERROR|ERROR:|Parse Error:)') {
            $step.failures += 'Godot emitted an error; inspect the logs.'
        }
        if ($step.failures.Count -eq 0) { $step.status = 'passed' }
    } catch {
        $step.failures += $_.Exception.Message
    } finally {
        $timer.Stop()
        $step.duration_seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        [IO.File]::WriteAllText($stdoutPath, $stdout)
        [IO.File]::WriteAllText($stderrPath, $stderr)
        $process.Dispose()
    }
    return $step
}

function Test-EngineLog {
    param([System.Collections.IDictionary]$Step, [string]$LogPath)
    $Step.engine_log = $LogPath
    try {
        $logFile = Get-Item -LiteralPath $LogPath
        if ($logFile.LastWriteTimeUtc -lt $startedAt.AddSeconds(-1)) { throw 'Engine log predates this run.' }
        $logText = Get-Content -LiteralPath $LogPath -Raw
        if ($logText -match '(?im)(?:^|\s)(?:SCRIPT ERROR|ERROR:|Parse Error:)') { throw 'Engine log contains errors.' }
    } catch {
        $Step.status = 'failed'
        $Step.failures += $_.Exception.Message
    }
}

function Test-ResultFile {
    param([string]$Name, [System.Collections.IDictionary]$Step, [switch]$RequireScreenshots)
    $resultPath = Join-Path $runDirectory "$Name-result.json"
    $Step.result_file = $resultPath
    try {
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Missing $Name-result.json." }
        if ((Get-Item -LiteralPath $resultPath).LastWriteTimeUtc -lt $startedAt.AddSeconds(-1)) { throw 'Result predates this run.' }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 100
        foreach ($field in @('run_id', 'status', 'assertions', 'failures', 'trace')) {
            if ($null -eq $result.PSObject.Properties[$field]) { throw "Result lacks required field: $field" }
        }
        if ($result.run_id -cne $runId) { throw 'Result run_id does not match this run.' }
        if ($result.status -cne 'passed' -or @($result.failures).Count -ne 0) { throw 'Test reports failed assertions.' }
        if ($result.assertions -isnot [ValueType] -or $result.assertions -le 0) { throw 'Test reported no assertion count.' }
        $Step.assertions = [int]$result.assertions
        if ($Name -in @('geometry', 'ui', 'presentation')) {
            if ($null -eq $result.scope -or $result.scope.art -isnot [bool] -or $result.scope.art -ne [bool]$Art) { throw 'Test art scope differs from the requested scope.' }
            if ($Name -ne 'presentation' -and ($result.scope.sizes -isnot [bool] -or $result.scope.sizes -ne [bool]$Sizes)) { throw 'Test size scope differs from the requested scope.' }
        }
        if ($Name -eq 'ui') {
            if ($null -eq $result.timings -or @($result.timings.PSObject.Properties).Count -eq 0) { throw 'UI result lacks group timings.' }
            $Step.timings = $result.timings
            $expectedSizes = if ($Sizes) { @('1024x640', '3440x1440') } else { @() }
            $actualSizes = @($result.resolutions | ForEach-Object { if ($_.status -ne 'passed') { throw 'Size check failed.' }; "$($_.window.x)x$($_.window.y)" })
            if (($actualSizes -join ',') -cne ($expectedSizes -join ',')) { throw 'Executed size matrix differs from requested scope.' }
        }
        if ($RequireScreenshots) {
            if ($Name -in @('ui', 'presentation')) {
                if ($result.scene_path -cne $ScenePath -or $result.loaded_scene_path -cne $ScenePath) { throw 'UI result does not identify the requested and actually loaded scene.' }
                $Step.scene_path = $result.scene_path
                $requiredScreenshots = if ($Name -eq 'ui') { @('board.png', 'hand-nine.png') } else { @('presentation-terminal.png') }
            } elseif ($Name -eq 'navigation') {
                $requiredScreenshots = @('main-menu.png')
            } else {
                if ($result.component -cne 'CardWorkshop') { throw 'Independent workshop result has the wrong component.' }
                $Step.component = $result.component
                $requiredScreenshots = @('workshop.png', 'workshop-editing.png', 'workshop-confirm.png')
                if ($Sizes) { $requiredScreenshots += @('workshop-confirm-1024x640.png', 'workshop-confirm-3440x1440.png') }
            }
            if ($Name -eq 'ui' -and $Art) { $requiredScreenshots += @('geometry-debug.png') }
            if ($Name -eq 'ui' -and $Sizes) {
                foreach ($size in $expectedSizes) {
                    $requiredScreenshots += "resolution-$size-board.png"
                }
            }
            foreach ($requiredScreenshot in $requiredScreenshots) {
                if (@($result.screenshots | ForEach-Object { [IO.Path]::GetFileName($_) }) -cnotcontains $requiredScreenshot) {
                    throw "UI result lacks required evidence: $requiredScreenshot"
                }
            }
            $verifiedScreenshots = @()
            foreach ($screenshot in $result.screenshots) {
                if ($screenshot -isnot [string] -or [string]::IsNullOrWhiteSpace($screenshot)) { throw 'Screenshot entries must be paths.' }
                $imagePath = [IO.Path]::GetFullPath([IO.Path]::Combine($runDirectory, $screenshot))
                if (-not $imagePath.StartsWith($runDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Screenshot is outside this run directory.'
                }
                $imageFile = Get-Item -LiteralPath $imagePath
                if ($imageFile.Length -le 8 -or $imageFile.LastWriteTimeUtc -lt $startedAt.AddSeconds(-1)) { throw 'Screenshot is empty or stale.' }
                $stream = [IO.File]::OpenRead($imagePath)
                try {
                    $header = [byte[]]::new(8)
                    if ($stream.Read($header, 0, 8) -ne 8 -or [Convert]::ToHexString($header) -ne '89504E470D0A1A0A') {
                        throw 'Screenshot is not a PNG.'
                    }
                } finally { $stream.Dispose() }
                $sidecarPath = $imagePath + '.json'
                $sidecarFile = Get-Item -LiteralPath $sidecarPath
                if ($sidecarFile.LastWriteTimeUtc -lt $startedAt.AddSeconds(-1)) { throw 'Screenshot configuration is stale.' }
                $sidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json -Depth 100
                if ($sidecar.run_id -cne $runId -or $null -eq $sidecar.state -or $null -eq $sidecar.viewport) { throw 'Screenshot lacks matching run, viewport or state.' }
                if ($Name -in @('ui', 'presentation') -and ($null -eq $sidecar.presentation -or [string]::IsNullOrWhiteSpace($sidecar.presentation.appearance_fingerprint))) { throw 'Battle screenshot lacks actual presentation fingerprints.' }
                $verifiedScreenshots += $imagePath
            }
            if (@($verifiedScreenshots | Select-Object -Unique).Count -lt $requiredScreenshots.Count) { throw 'UI screenshots must be distinct files.' }
            $Step.screenshots = $verifiedScreenshots
        }
    } catch {
        $Step.status = 'failed'
        $Step.failures += $_.Exception.Message
    }
}

$verification = [ordered]@{
    scope = [ordered]@{ art = [bool]$Art; workshop = [bool]$Workshop; sizes = [bool]$Sizes; ui = -not [bool]$SkipUi }; run_id = $runId; label = $Label; seed = 20260917; project_path = $ProjectRoot; scene_path = $ScenePath; started_at = $startedAt.ToString('o')
    completed_at = $null; status = 'pending'; automated_status = 'pending'
    versions = [ordered]@{
        godot_path = $GodotPath; godot = $null; powershell = $PSVersionTable.PSVersion.ToString()
        node_path = $null; node = $null; mcp_packages = @()
    }
    checks = [ordered]@{ workshop_ui = [ordered]@{ status = $(if ($Workshop) { 'pending' } else { 'not_run' }); reason = $(if ($Workshop) { 'Selected workshop check.' } else { 'Not selected; use -Workshop.' }) } }
    mcp = [ordered]@{ status = 'not_run'; reason = 'Optional live-editor integration check.' }
    visual = [ordered]@{ status = 'not_run'; reason = 'Screenshot inspection is recorded separately from automated checks.' }
    manual = [ordered]@{ status = 'not_run'; reason = 'User playtest is recorded separately from automated checks.' }
}
$verificationPath = Join-Path $runDirectory 'verification.json'
$failed = $false
try {
    $versionCheck = Invoke-GodotProcess -Name 'version' -Arguments @('--version') -TimeoutSeconds 15
    $verification.checks.version = $versionCheck
    if ($versionCheck.status -ne 'passed') { throw 'Godot version check failed.' }
    $verification.versions.godot = (Get-Content -LiteralPath $versionCheck.stdout_log -Raw).Trim()

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nodeCommand) {
        $verification.versions.node_path = $nodeCommand.Source
        $nodeVersion = Invoke-GodotProcess -Name 'node-version' -Executable $nodeCommand.Source -Arguments @('--version') -TimeoutSeconds 15
        $verification.versions.node = if ($nodeVersion.status -eq 'passed') { (Get-Content -LiteralPath $nodeVersion.stdout_log -Raw).Trim() } else { 'unavailable' }
    }
    foreach ($packageName in @('@satelliteoflove/godot-mcp', '@ryanmazzolini/minimal-godot-mcp')) {
        $manifestPath = Join-Path $ProjectRoot "tools/mcp/node_modules/$packageName/package.json"
        $packageRecord = [ordered]@{ name = $packageName; manifest_path = $manifestPath; version = $null; status = 'unavailable' }
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                $packageManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $packageRecord.version = $packageManifest.version
                $packageRecord.status = 'installed'
            } catch { $packageRecord.reason = $_.Exception.Message }
        }
        $verification.versions.mcp_packages += $packageRecord
    }

    $importLog = Join-Path $runDirectory 'import-engine.log'
    $importCheck = Invoke-GodotProcess -Name 'import' -Arguments @('--headless', '--path', $ProjectRoot, '--import', '--log-file', $importLog) -TimeoutSeconds $ImportTimeoutSeconds
    Test-EngineLog -Step $importCheck -LogPath $importLog
    $verification.checks.import = $importCheck
    if ($importCheck.status -ne 'passed') { throw 'Godot import failed.' }

    $libraryLog = Join-Path $runDirectory 'library-engine.log'
    $libraryCheck = Invoke-GodotProcess -Name 'library' -Arguments @('--headless', '--path', $ProjectRoot, '--script', 'res://tests/library_smoke.gd', '--log-file', $libraryLog, '--', '--run-id', $runId, '--output-dir', $runDirectory) -TimeoutSeconds $RulesTimeoutSeconds
    Test-EngineLog -Step $libraryCheck -LogPath $libraryLog
    Test-ResultFile -Name 'library' -Step $libraryCheck
    $verification.checks.library = $libraryCheck
    if ($libraryCheck.status -ne 'passed') { throw 'Shared library verification failed.' }

    $geometryLog = Join-Path $runDirectory 'geometry-engine.log'
    $geometryOptions = @()
    if ($Art) { $geometryOptions += '--art' }
    if ($Sizes) { $geometryOptions += '--sizes' }
    $geometryCheck = Invoke-GodotProcess -Name 'geometry' -Arguments (@('--headless', '--path', $ProjectRoot, '--script', 'res://tests/geometry_contract.gd', '--log-file', $geometryLog, '--', '--run-id', $runId, '--output-dir', $runDirectory) + $geometryOptions) -TimeoutSeconds $RulesTimeoutSeconds
    Test-EngineLog -Step $geometryCheck -LogPath $geometryLog
    Test-ResultFile -Name 'geometry' -Step $geometryCheck
    $verification.checks.geometry = $geometryCheck
    if ($geometryCheck.status -ne 'passed') { throw 'Shared geometry verification failed.' }

    $rulesLog = Join-Path $runDirectory 'rules-engine.log'
    $rulesCheck = Invoke-GodotProcess -Name 'rules' -Arguments @('--headless', '--path', $ProjectRoot, '--script', 'res://tests/battle_smoke.gd', '--log-file', $rulesLog, '--', '--run-id', $runId, '--output-dir', $runDirectory, '--seed', '20260917') -TimeoutSeconds $RulesTimeoutSeconds
    Test-EngineLog -Step $rulesCheck -LogPath $rulesLog
    Test-ResultFile -Name 'rules' -Step $rulesCheck
    $verification.checks.rules = $rulesCheck
    if ($rulesCheck.status -ne 'passed') { throw 'Rules verification failed.' }

    if ($SkipUi) {
        $verification.checks.ui = [ordered]@{ status = 'pending'; reason = 'Skipped by -SkipUi; UI input and screenshot generation are unverified.' }
        $verification.checks.presentation = [ordered]@{ status = 'pending'; reason = 'Skipped by -SkipUi; real-input motion and cancellation are unverified.' }
        if ($Workshop) { $verification.checks.workshop_ui = [ordered]@{ status = 'pending'; reason = 'Selected workshop skipped by -SkipUi.' } }
    } else {
        $navigationLog = Join-Path $runDirectory 'navigation-engine.log'
        $navigationCheck = Invoke-GodotProcess -Name 'navigation' -Arguments @('--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/navigation_smoke.gd', '--log-file', $navigationLog, '--', '--run-id', $runId, '--output-dir', $runDirectory, '--seed', '20260917', '--workshop-store', (Join-Path $runDirectory 'navigation-collection')) -TimeoutSeconds $UiTimeoutSeconds
        Test-EngineLog -Step $navigationCheck -LogPath $navigationLog
        Test-ResultFile -Name 'navigation' -Step $navigationCheck -RequireScreenshots
        $verification.checks.navigation = $navigationCheck
        if ($navigationCheck.status -ne 'passed') { throw 'Navigation verification failed.' }

        $uiLog = Join-Path $runDirectory 'ui-engine.log'
        $uiCheck = Invoke-GodotProcess -Name 'ui' -Arguments (@('--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/ui_smoke.gd', '--log-file', $uiLog, '--', '--run-id', $runId, '--output-dir', $runDirectory, '--seed', '20260917') + $geometryOptions) -TimeoutSeconds $UiTimeoutSeconds
        Test-EngineLog -Step $uiCheck -LogPath $uiLog
        Test-ResultFile -Name 'ui' -Step $uiCheck -RequireScreenshots
        $verification.checks.ui = $uiCheck
        if ($uiCheck.status -ne 'passed') { throw 'UI verification failed.' }

        $presentationLog = Join-Path $runDirectory 'presentation-engine.log'
        $presentationCheck = Invoke-GodotProcess -Name 'presentation' -Arguments (@('--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/presentation_smoke.gd', '--log-file', $presentationLog, '--', '--run-id', $runId, '--output-dir', $runDirectory, '--seed', '20260917') + $(if ($Art) { @('--art') } else { @() })) -TimeoutSeconds $UiTimeoutSeconds
        Test-EngineLog -Step $presentationCheck -LogPath $presentationLog
        Test-ResultFile -Name 'presentation' -Step $presentationCheck -RequireScreenshots
        $verification.checks.presentation = $presentationCheck
        if ($presentationCheck.status -ne 'passed') { throw 'Basic presentation verification failed.' }

        if ($Workshop) {
            $workshopLog = Join-Path $runDirectory 'workshop-ui-engine.log'
            $workshopOptions = if ($Sizes) { @('--sizes') } else { @() }
            $workshopCheck = Invoke-GodotProcess -Name 'workshop-ui' -Arguments (@('--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/workshop_ui_smoke.gd', '--log-file', $workshopLog, '--', '--run-id', $runId, '--output-dir', $runDirectory) + $workshopOptions) -TimeoutSeconds $UiTimeoutSeconds
            Test-EngineLog -Step $workshopCheck -LogPath $workshopLog
            Test-ResultFile -Name 'workshop-ui' -Step $workshopCheck -RequireScreenshots
            $verification.checks.workshop_ui = $workshopCheck
            if ($workshopCheck.status -ne 'passed') { throw 'Independent workshop UI verification failed.' }
            foreach ($phase in @('create', 'update', 'delete', 'empty')) {
                $name = "workshop-persistence-$phase"
                $persistentLog = Join-Path $runDirectory "$name-engine.log"
                $persistentCheck = Invoke-GodotProcess -Name $name -Arguments @('--path', $ProjectRoot, '--rendering-method', 'gl_compatibility', '--script', 'res://tests/workshop_persistence.gd', '--log-file', $persistentLog, '--', '--run-id', $runId, '--output-dir', $runDirectory, '--phase', $phase, '--workshop-store', (Join-Path $runDirectory 'persistent-collection')) -TimeoutSeconds $UiTimeoutSeconds
                Test-EngineLog -Step $persistentCheck -LogPath $persistentLog
                Test-ResultFile -Name $name -Step $persistentCheck
                $verification.checks[$name] = $persistentCheck
                if ($persistentCheck.status -ne 'passed') { throw "Workshop persistence phase $phase failed." }
            }
        }
    }
    $verification.automated_status = if ($SkipUi) { 'pending' } else { 'passed' }
} catch {
    $failed = $true
    $verification.status = 'failed'
    $verification.automated_status = 'failed'
    $verification.failure = $_.Exception.Message
    Write-Warning $_.Exception.Message
} finally {
    foreach ($missingCheck in @('import', 'library', 'geometry', 'rules', 'navigation', 'ui', 'presentation', 'workshop_ui')) {
        if (-not $verification.checks.Contains($missingCheck)) {
            $verification.checks[$missingCheck] = [ordered]@{ status = 'pending'; reason = 'Not reached because an earlier check failed.' }
        }
    }
    foreach ($specialty in @('art', 'sizes')) {
        $selected = if ($specialty -eq 'art') { [bool]$Art } else { [bool]$Sizes }
        $dependencies = if ($specialty -eq 'art') { @('geometry', 'ui', 'presentation') } else { @('geometry', 'ui') }
        $states = @($dependencies | ForEach-Object { $verification.checks[$_].status })
        $specialtyStatus = if (-not $selected) { 'not_run' } elseif ($states -contains 'failed') { 'failed' } elseif (@($states | Where-Object { $_ -ne 'passed' }).Count) { 'pending' } else { 'passed' }
        $verification.checks[$specialty] = [ordered]@{ status = $specialtyStatus; checks = $dependencies; reason = $(if ($selected) { 'Selected specialty; see suite reports.' } else { 'Not selected.' }) }
    }
    $verification.status = $verification.automated_status
    $verification.completed_at = [datetime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($verificationPath, ($verification | ConvertTo-Json -Depth 100))
    Write-Host "Verification report: $verificationPath"
    Write-Host "Automated: $($verification.automated_status); MCP, visual review and user playtest are recorded separately."
}
if ($failed) { exit 1 }
exit 0
