#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('fast', 'full')]
    [string]$Mode = 'full',

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$Iterations = 1,

    [Parameter()]
    [switch]$Watch,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$PollSeconds = 5,

    [Parameter()]
    [ValidateRange(0, 500)]
    [int]$MaxRuns = 0,

    [Parameter()]
    [string]$OutputRoot = 'D:\_lvie-ci\surface\iteration',

    [Parameter()]
    [string]$SmokeWorkspaceRoot = 'D:\_lvie-ci\surface\smoke',

    [Parameter()]
    [switch]$KeepSmokeWorkspace,

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter()]
    [switch]$EmitSummaryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    Write-Host ("`n=== {0} ===" -f $Title)
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$iterationScript = Join-Path $repoRoot 'scripts\Invoke-WorkspaceInstallerIteration.ps1'
if (-not (Test-Path -LiteralPath $iterationScript -PathType Leaf)) {
    throw "Iteration script not found: $iterationScript"
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$resolvedSmokeRoot = [System.IO.Path]::GetFullPath($SmokeWorkspaceRoot)

$invokeArgs = @(
    '-Mode', $Mode,
    '-Iterations', $Iterations,
    '-OutputRoot', $resolvedOutputRoot,
    '-SmokeWorkspaceRoot', $resolvedSmokeRoot,
    '-NsisRoot', $NsisRoot
)
if ($Watch) {
    $invokeArgs += @('-Watch', '-PollSeconds', $PollSeconds, '-MaxRuns', $MaxRuns)
}
if ($KeepSmokeWorkspace) {
    $invokeArgs += '-KeepSmokeWorkspace'
}

$iterationExit = 0
$iterationError = ''
try {
    & $iterationScript @invokeArgs
    $iterationExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($iterationExit -ne 0) {
        $iterationError = "Invoke-WorkspaceInstallerIteration exited with code $iterationExit."
    }
} catch {
    $iterationExit = if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { [int]$LASTEXITCODE } else { 1 }
    $iterationError = $_.Exception.Message
}

$iterationSummaryPath = Join-Path $resolvedOutputRoot 'iteration-summary.json'
$iterationSummary = Read-JsonFile -Path $iterationSummaryPath

$latestRunName = ''
if ($null -ne $iterationSummary -and $null -ne $iterationSummary.latest -and -not [string]::IsNullOrWhiteSpace([string]$iterationSummary.latest.run)) {
    $latestRunName = [string]$iterationSummary.latest.run
} elseif (Test-Path -LiteralPath $resolvedOutputRoot -PathType Container) {
    $latestRunDir = Get-ChildItem -LiteralPath $resolvedOutputRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'run-*' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $latestRunDir) {
        $latestRunName = $latestRunDir.Name
    }
}

$exercisePath = if ([string]::IsNullOrWhiteSpace($latestRunName)) { '' } else { Join-Path $resolvedOutputRoot (Join-Path $latestRunName 'exercise-report.json') }
$smokeReportPath = Join-Path $resolvedSmokeRoot 'artifacts\workspace-install-latest.json'
$smokeLaunchLogPath = Join-Path $resolvedSmokeRoot 'artifacts\workspace-installer-launch.log'

$exerciseReport = if ([string]::IsNullOrWhiteSpace($exercisePath)) { $null } else { Read-JsonFile -Path $exercisePath }
$smokeReport = Read-JsonFile -Path $smokeReportPath

Write-Section -Title 'Installer Harness Local Debug Summary'
Write-Host ("mode={0}" -f $Mode)
Write-Host ("watch={0}" -f ([bool]$Watch))
Write-Host ("iterations={0}" -f $Iterations)
Write-Host ("output_root={0}" -f $resolvedOutputRoot)
Write-Host ("smoke_workspace_root={0}" -f $resolvedSmokeRoot)
Write-Host ("iteration_summary={0}" -f $iterationSummaryPath)
if (-not [string]::IsNullOrWhiteSpace($latestRunName)) {
    Write-Host ("latest_run={0}" -f $latestRunName)
}
if (-not [string]::IsNullOrWhiteSpace($exercisePath)) {
    Write-Host ("exercise_report={0}" -f $exercisePath)
}
Write-Host ("smoke_report={0}" -f $smokeReportPath)
Write-Host ("smoke_launch_log={0}" -f $smokeLaunchLogPath)

$smokeStatus = if ($null -ne $smokeReport) { [string]$smokeReport.status } else { 'missing' }
$exerciseStatus = if ($null -ne $exerciseReport -and $null -ne $exerciseReport.smoke_installer) { [string]$exerciseReport.smoke_installer.status } else { 'unknown' }
Write-Host ("smoke_status={0}" -f $smokeStatus)
Write-Host ("exercise_smoke_status={0}" -f $exerciseStatus)

$smokeErrors = @()
if ($null -ne $smokeReport -and $null -ne $smokeReport.errors) {
    $smokeErrors = @($smokeReport.errors)
}

if ($smokeErrors.Count -gt 0) {
    Write-Section -Title 'Top Smoke Errors'
    foreach ($line in ($smokeErrors | Select-Object -First 10)) {
        Write-Host $line
    }
}

if (-not [string]::IsNullOrWhiteSpace($iterationError)) {
    Write-Section -Title 'Iteration Error'
    Write-Host $iterationError
}

$debugSummary = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    watch = [bool]$Watch
    iterations = $Iterations
    output_root = $resolvedOutputRoot
    smoke_workspace_root = $resolvedSmokeRoot
    iteration_exit_code = $iterationExit
    iteration_error = $iterationError
    iteration_summary_path = $iterationSummaryPath
    latest_run = $latestRunName
    exercise_report_path = $exercisePath
    smoke_report_path = $smokeReportPath
    smoke_launch_log_path = $smokeLaunchLogPath
    smoke_status = $smokeStatus
    exercise_smoke_status = $exerciseStatus
    top_smoke_errors = @($smokeErrors | Select-Object -First 10)
}

if ($EmitSummaryJson) {
    $debugSummaryPath = Join-Path $resolvedOutputRoot 'local-debug-summary.json'
    $debugSummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $debugSummaryPath -Encoding utf8
    Write-Host ("debug_summary_json={0}" -f $debugSummaryPath)
}

if ($iterationExit -ne 0) {
    exit $iterationExit
}
