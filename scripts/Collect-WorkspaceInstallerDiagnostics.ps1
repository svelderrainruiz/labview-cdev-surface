#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [Parameter()]
    [string]$KpiConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'diagnostics-kpi.json'),

    [Parameter()]
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\governance-debt\workspace-installer-diagnostics-latest.json')
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

function Get-DefaultKpiConfig {
    return [ordered]@{
        required_artifacts = @(
            'workspace-install-latest.json',
            'workspace-installer-launch.log',
            'harness-validation-report.json',
            'runner-baseline-report.json',
            'machine-preflight-report.json'
        )
        timeout_artifacts = @('smoke-installer-timeout-diagnostics.json')
    }
}

if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "Installer report not found: $ReportPath"
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
$kpiConfig = if (Test-Path -LiteralPath $KpiConfigPath -PathType Leaf) {
    Get-Content -LiteralPath $KpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
} else {
    [pscustomobject](Get-DefaultKpiConfig)
}

$diagnostics = $report.diagnostics
if ($null -eq $diagnostics) {
    $diagnostics = [pscustomobject]@{
        schema_version = '1.0'
        platform = [ordered]@{
            name = 'unknown'
        }
        execution_context = [ordered]@{}
        phase_metrics = [ordered]@{
            total_duration_seconds = 0
            phase_count = 0
            phases = [ordered]@{}
        }
        command_diagnostics = [ordered]@{}
        artifact_index = @()
        failure_fingerprint = [ordered]@{
            hash = ''
        }
        developer_feedback = [ordered]@{
            failure_summary_completeness = 0
            estimated_time_to_diagnose_minutes = 15
            actionable_error_count = 0
            warning_count = 0
        }
    }
}

$artifactIndex = Get-SafeArray -Value $diagnostics.artifact_index
$requiredArtifacts = @($kpiConfig.required_artifacts | ForEach-Object { [string]$_ })
$timeoutArtifacts = @($kpiConfig.timeout_artifacts | ForEach-Object { [string]$_ })

$requiredArtifactStatus = @()
$missingRequiredArtifacts = @()
foreach ($artifactId in $requiredArtifacts) {
    $match = @($artifactIndex | Where-Object { [string]$_.id -eq $artifactId } | Select-Object -First 1)
    if (@($match).Count -eq 0) {
        $requiredArtifactStatus += [pscustomobject]@{
            id = $artifactId
            exists = $false
            reason = 'missing_from_artifact_index'
        }
        $missingRequiredArtifacts += $artifactId
        continue
    }

    $exists = [bool]$match[0].exists
    $requiredArtifactStatus += [pscustomobject]@{
        id = $artifactId
        exists = $exists
        reason = if ($exists) { 'present' } else { 'not_found' }
    }
    if (-not $exists) {
        $missingRequiredArtifacts += $artifactId
    }
}

$stuckProcessCount = 0
$commandDiagnostics = $diagnostics.command_diagnostics
if ($null -ne $commandDiagnostics) {
    $pplBuild = $commandDiagnostics.ppl_build
    if ($null -ne $pplBuild) {
        foreach ($bitness in @('x32', 'x64')) {
            $entry = $pplBuild.$bitness
            if ($null -ne $entry -and [bool]$entry.timed_out) {
                $children = Get-SafeArray -Value $entry.timeout_process_tree.child_processes
                $stuckProcessCount += @($children).Count
            }
        }
    }
    $vipHarness = $commandDiagnostics.vip_harness
    if ($null -ne $vipHarness -and [bool]$vipHarness.timed_out) {
        $children = Get-SafeArray -Value $vipHarness.timeout_process_tree.child_processes
        $stuckProcessCount += @($children).Count
    }
    $governanceAudit = $commandDiagnostics.governance_audit
    if ($null -ne $governanceAudit -and [bool]$governanceAudit.timed_out) {
        $children = Get-SafeArray -Value $governanceAudit.timeout_process_tree.child_processes
        $stuckProcessCount += @($children).Count
    }
}

$timeoutArtifactsPresent = @()
foreach ($artifactId in $timeoutArtifacts) {
    $match = @($artifactIndex | Where-Object { [string]$_.id -eq $artifactId } | Select-Object -First 1)
    if (@($match).Count -eq 0) {
        continue
    }
    if ([bool]$match[0].exists) {
        $timeoutArtifactsPresent += $artifactId
    }
}

$phaseMetrics = if ($null -ne $diagnostics.phase_metrics) {
    $diagnostics.phase_metrics
} else {
    [pscustomobject]@{
        total_duration_seconds = 0
        phase_count = 0
        phases = [ordered]@{}
    }
}

$durationSeconds = [double]$phaseMetrics.total_duration_seconds
$failureFingerprintHash = ''
if ($null -ne $diagnostics.failure_fingerprint -and $null -ne $diagnostics.failure_fingerprint.hash) {
    $failureFingerprintHash = [string]$diagnostics.failure_fingerprint.hash
}
$feedback = if ($null -ne $diagnostics.developer_feedback) {
    $diagnostics.developer_feedback
} else {
    [pscustomobject]@{
        failure_summary_completeness = 0
        estimated_time_to_diagnose_minutes = 15
        actionable_error_count = 0
        warning_count = 0
    }
}
$taxonomy = @()
if ($null -ne $diagnostics.failure_fingerprint -and $null -ne $diagnostics.failure_fingerprint.canonical_input) {
    $taxonomy = @($diagnostics.failure_fingerprint.canonical_input.taxonomy | ForEach-Object { [string]$_ })
}
$normalized = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    source_report_path = [System.IO.Path]::GetFullPath($ReportPath)
    status = [string]$report.status
    diagnostics = $diagnostics
    kpi_inputs = [ordered]@{
        schema_version = [string]$diagnostics.schema_version
        failure_fingerprint = $failureFingerprintHash
        taxonomy = @($taxonomy)
        required_artifact_status = $requiredArtifactStatus
        missing_required_artifacts = @($missingRequiredArtifacts)
        timeout_artifacts_present = @($timeoutArtifactsPresent)
        failure_summary_completeness = [double]$feedback.failure_summary_completeness
        estimated_time_to_diagnose_minutes = [double]$feedback.estimated_time_to_diagnose_minutes
        actionable_error_count = [int]$feedback.actionable_error_count
        warning_count = [int]$feedback.warning_count
        phase_duration_seconds = $durationSeconds
        terminal_within_60m = ($durationSeconds -le 3600)
        stuck_process_count = [int]$stuckProcessCount
    }
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)
$normalized | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace installer diagnostics report: $resolvedOutputPath"
