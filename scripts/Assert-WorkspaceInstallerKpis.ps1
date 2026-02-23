#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KpiReportPath,

    [Parameter()]
    [string]$KpiConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics-kpi.json'),

    [Parameter()]
    [ValidateSet('advisory', 'blocking')]
    [string]$BurnInModeOverride = '',

    [Parameter()]
    [switch]$FailOnWarning,

    [Parameter()]
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\governance-debt\workspace-installer-kpi-assertion-latest.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $KpiReportPath -PathType Leaf)) {
    throw "KPI report not found: $KpiReportPath"
}
if (-not (Test-Path -LiteralPath $KpiConfigPath -PathType Leaf)) {
    throw "KPI config not found: $KpiConfigPath"
}

$kpiReport = Get-Content -LiteralPath $KpiReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
$kpiConfig = Get-Content -LiteralPath $KpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$kpis = $kpiReport.kpis
$thresholds = $kpiConfig.thresholds

$burnInMode = if ([string]::IsNullOrWhiteSpace($BurnInModeOverride)) {
    [string]$kpiConfig.burn_in_mode
} else {
    [string]$BurnInModeOverride
}
if ([string]::IsNullOrWhiteSpace($burnInMode)) {
    $burnInMode = 'advisory'
}

$breaches = @()
function Add-Breach {
    param(
        [Parameter(Mandatory = $true)][string]$Metric,
        [Parameter(Mandatory = $true)][double]$Actual,
        [Parameter(Mandatory = $true)][double]$Expected,
        [Parameter(Mandatory = $true)][string]$Operator
    )

    $severity = if ($burnInMode -eq 'blocking') { 'blocking' } else { 'advisory' }
    $script:breaches += [pscustomobject]@{
        metric = $Metric
        actual = $Actual
        expected = $Expected
        operator = $Operator
        severity = $severity
    }
}

if ([double]$kpis.artifact_coverage_rate -lt [double]$thresholds.artifact_coverage_rate_min) {
    Add-Breach -Metric 'artifact_coverage_rate' -Actual ([double]$kpis.artifact_coverage_rate) -Expected ([double]$thresholds.artifact_coverage_rate_min) -Operator '>='
}
if ([double]$kpis.failure_summary_completeness -lt [double]$thresholds.failure_summary_completeness_min) {
    Add-Breach -Metric 'failure_summary_completeness' -Actual ([double]$kpis.failure_summary_completeness) -Expected ([double]$thresholds.failure_summary_completeness_min) -Operator '>='
}
if ([double]$kpis.mean_time_to_diagnose_minutes -gt [double]$thresholds.mean_time_to_diagnose_minutes_max) {
    Add-Breach -Metric 'mean_time_to_diagnose_minutes' -Actual ([double]$kpis.mean_time_to_diagnose_minutes) -Expected ([double]$thresholds.mean_time_to_diagnose_minutes_max) -Operator '<='
}
if ([double]$kpis.hang_recovery_time_minutes -gt [double]$thresholds.hang_recovery_time_minutes_max) {
    Add-Breach -Metric 'hang_recovery_time_minutes' -Actual ([double]$kpis.hang_recovery_time_minutes) -Expected ([double]$thresholds.hang_recovery_time_minutes_max) -Operator '<='
}
if ([double]$kpis.terminal_run_rate_60m -lt [double]$thresholds.terminal_run_rate_60m_min) {
    Add-Breach -Metric 'terminal_run_rate_60m' -Actual ([double]$kpis.terminal_run_rate_60m) -Expected ([double]$thresholds.terminal_run_rate_60m_min) -Operator '>='
}
if ([double]$kpis.schema_conformance_rate -lt [double]$thresholds.schema_conformance_rate_min) {
    Add-Breach -Metric 'schema_conformance_rate' -Actual ([double]$kpis.schema_conformance_rate) -Expected ([double]$thresholds.schema_conformance_rate_min) -Operator '>='
}
if ([double]$kpis.actionable_error_rate -lt [double]$thresholds.actionable_error_rate_min) {
    Add-Breach -Metric 'actionable_error_rate' -Actual ([double]$kpis.actionable_error_rate) -Expected ([double]$thresholds.actionable_error_rate_min) -Operator '>='
}

$maxStuckAllowed = [int]$kpiConfig.max_stuck_process_count
$maxStuckObserved = [int]$kpiReport.operational_observations.max_stuck_process_count_observed
if ($maxStuckObserved -gt $maxStuckAllowed) {
    Add-Breach -Metric 'max_stuck_process_count_observed' -Actual ([double]$maxStuckObserved) -Expected ([double]$maxStuckAllowed) -Operator '<='
}

$phaseDurationThresholds = @($kpiConfig.max_phase_duration_seconds.PSObject.Properties | ForEach-Object { [double]$_.Value })
$maxPhaseDurationAllowed = if (@($phaseDurationThresholds).Count -gt 0) { ($phaseDurationThresholds | Measure-Object -Maximum).Maximum } else { 0 }
$maxPhaseDurationObserved = [double]$kpiReport.operational_observations.max_phase_duration_seconds_observed
if ($maxPhaseDurationAllowed -gt 0 -and $maxPhaseDurationObserved -gt [double]$maxPhaseDurationAllowed) {
    Add-Breach -Metric 'max_phase_duration_seconds_observed' -Actual $maxPhaseDurationObserved -Expected ([double]$maxPhaseDurationAllowed) -Operator '<='
}

$missingArtifacts = @($kpiReport.operational_observations.missing_required_artifacts | ForEach-Object { [string]$_ })
if ($missingArtifacts.Count -gt 0) {
    Add-Breach -Metric 'missing_required_artifacts' -Actual ([double]$missingArtifacts.Count) -Expected 0 -Operator '=='
}

$blockingFailures = @($breaches | Where-Object { [string]$_.severity -eq 'blocking' }).Count
$advisoryFailures = @($breaches | Where-Object { [string]$_.severity -eq 'advisory' }).Count
$warnings = @()
if ($FailOnWarning -and $advisoryFailures -gt 0 -and $burnInMode -eq 'advisory') {
    $warnings += 'FailOnWarning was set and advisory KPI breaches were observed.'
}

$result = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    kpi_report_path = [System.IO.Path]::GetFullPath($KpiReportPath)
    kpi_config_path = [System.IO.Path]::GetFullPath($KpiConfigPath)
    burn_in_mode = $burnInMode
    summary = [ordered]@{
        blocking_failures = [int]$blockingFailures
        advisory_failures = [int]$advisoryFailures
        warnings = @($warnings)
    }
    breaches = $breaches
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace installer KPI assertion report: $resolvedOutputPath"

$shouldFail = $false
if ($blockingFailures -gt 0) {
    $shouldFail = $true
}
if ($FailOnWarning -and $advisoryFailures -gt 0 -and $burnInMode -eq 'advisory') {
    $shouldFail = $true
}

if ($shouldFail) {
    exit 1
}

exit 0
