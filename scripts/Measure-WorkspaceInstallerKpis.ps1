#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DiagnosticsPath,

    [Parameter()]
    [string]$KpiConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics-kpi.json'),

    [Parameter()]
    [ValidateSet('Mutation', 'WorkspaceAudit', 'Harness')]
    [string]$ScopeProfile = 'Harness',

    [Parameter()]
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\governance-debt\workspace-installer-kpi-latest.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-SafeArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-Average {
    param([double[]]$Values)
    if (@($Values).Count -eq 0) { return 0.0 }
    return [Math]::Round((($Values | Measure-Object -Average).Average), 6)
}

if (-not (Test-Path -LiteralPath $DiagnosticsPath)) {
    throw "Diagnostics path not found: $DiagnosticsPath"
}
if (-not (Test-Path -LiteralPath $KpiConfigPath -PathType Leaf)) {
    throw "KPI config not found: $KpiConfigPath"
}

$kpiConfig = Get-Content -LiteralPath $KpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$diagnosticFiles = @()
if (Test-Path -LiteralPath $DiagnosticsPath -PathType Leaf) {
    $diagnosticFiles = @([System.IO.Path]::GetFullPath($DiagnosticsPath))
} else {
    $diagnosticFiles = @(
        Get-ChildItem -LiteralPath $DiagnosticsPath -Recurse -File -Filter '*.json' |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -ExpandProperty FullName
    )
}

$diagnosticRuns = @()
foreach ($file in $diagnosticFiles) {
    try {
        $payload = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $payload.kpi_inputs) {
            continue
        }
        $diagnosticRuns += [pscustomobject]@{
            path = $file
            status = [string]$payload.status
            inputs = $payload.kpi_inputs
        }
    } catch {
        # Keep processing other files; malformed files reduce schema conformance KPI.
        $diagnosticRuns += [pscustomobject]@{
            path = $file
            status = 'failed'
            inputs = [pscustomobject]@{
                schema_version = 'invalid'
                required_artifact_status = @()
                missing_required_artifacts = @()
                failure_summary_completeness = 0
                estimated_time_to_diagnose_minutes = 30
                actionable_error_count = 0
                terminal_within_60m = $false
                stuck_process_count = 0
            }
        }
    }
}

$runCount = @($diagnosticRuns).Count
if ($runCount -eq 0) {
    throw "No diagnostics payloads with kpi_inputs were found at '$DiagnosticsPath'."
}

$requiredArtifactsPerRun = @($kpiConfig.required_artifacts | ForEach-Object { [string]$_ })
$totalExpectedArtifacts = $requiredArtifactsPerRun.Count * $runCount
$totalPresentArtifacts = 0
$allMissingArtifacts = @()

$failureSummaryValues = @()
$diagnoseTimeValues = @()
$terminalWithin60mCount = 0
$schemaConformingCount = 0
$failedRunCount = 0
$failedRunsWithActionableCount = 0
$timeoutRecoveryValues = @()
$maxStuckProcessCountObserved = 0
$maxPhaseDurationSecondsObserved = 0.0

foreach ($run in $diagnosticRuns) {
    $inputs = $run.inputs
    $artifactStatus = Get-SafeArray -Value $inputs.required_artifact_status
    foreach ($artifact in $artifactStatus) {
        if ([bool]$artifact.exists) {
            $totalPresentArtifacts++
        }
    }

    $missing = Get-SafeArray -Value $inputs.missing_required_artifacts
    $allMissingArtifacts += @($missing | ForEach-Object { [string]$_ })

    $failureSummaryValues += [double]$inputs.failure_summary_completeness
    $diagnoseTimeValues += [double]$inputs.estimated_time_to_diagnose_minutes
    if ([bool]$inputs.terminal_within_60m) {
        $terminalWithin60mCount++
    }
    if ([string]$inputs.schema_version -eq '1.0') {
        $schemaConformingCount++
    }

    if ([string]$run.status -ne 'succeeded') {
        $failedRunCount++
        if ([int]$inputs.actionable_error_count -gt 0) {
            $failedRunsWithActionableCount++
        }
    }

    if (@(Get-SafeArray -Value $inputs.timeout_artifacts_present).Count -gt 0) {
        $timeoutRecoveryValues += [double]$inputs.estimated_time_to_diagnose_minutes
    }

    $maxStuckProcessCountObserved = [Math]::Max($maxStuckProcessCountObserved, [int]$inputs.stuck_process_count)
    $maxPhaseDurationSecondsObserved = [Math]::Max([double]$maxPhaseDurationSecondsObserved, [double]$inputs.phase_duration_seconds)
}

$artifactCoverageRate = if ($totalExpectedArtifacts -gt 0) {
    [Math]::Round(($totalPresentArtifacts / $totalExpectedArtifacts), 6)
} else {
    0.0
}
$failureSummaryCompleteness = Get-Average -Values $failureSummaryValues
$meanTimeToDiagnoseMinutes = Get-Average -Values $diagnoseTimeValues
$hangRecoveryTimeMinutes = if (@($timeoutRecoveryValues).Count -gt 0) {
    Get-Average -Values $timeoutRecoveryValues
} else {
    0.0
}
$terminalRunRate60m = [Math]::Round(($terminalWithin60mCount / $runCount), 6)
$schemaConformanceRate = [Math]::Round(($schemaConformingCount / $runCount), 6)
$actionableErrorRate = if ($failedRunCount -eq 0) {
    1.0
} else {
    [Math]::Round(($failedRunsWithActionableCount / $failedRunCount), 6)
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    scope_profile = $ScopeProfile
    source_diagnostics_path = [System.IO.Path]::GetFullPath($DiagnosticsPath)
    run_count = $runCount
    burn_in_mode = [string]$kpiConfig.burn_in_mode
    kpis = [ordered]@{
        artifact_coverage_rate = $artifactCoverageRate
        failure_summary_completeness = $failureSummaryCompleteness
        mean_time_to_diagnose_minutes = $meanTimeToDiagnoseMinutes
        hang_recovery_time_minutes = $hangRecoveryTimeMinutes
        terminal_run_rate_60m = $terminalRunRate60m
        schema_conformance_rate = $schemaConformanceRate
        actionable_error_rate = $actionableErrorRate
    }
    operational_observations = [ordered]@{
        max_stuck_process_count_observed = [int]$maxStuckProcessCountObserved
        max_phase_duration_seconds_observed = [double]$maxPhaseDurationSecondsObserved
        missing_required_artifacts = @($allMissingArtifacts | Sort-Object -Unique)
    }
    thresholds = $kpiConfig.thresholds
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)
$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace installer KPI report: $resolvedOutputPath"
