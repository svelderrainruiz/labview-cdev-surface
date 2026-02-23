#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KpiReportPath,

    [Parameter()]
    [string]$AssertionReportPath = '',

    [Parameter()]
    [string]$RepoSlug = '',

    [Parameter()]
    [string]$IssueTitle = 'Workspace Installer KPI Signal',

    [Parameter()]
    [string[]]$IssueLabels = @('governance', 'dx', 'kpi'),

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [string]$OutputMarkdownPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\governance-debt\workspace-installer-kpi-summary.md'),

    [Parameter()]
    [string]$OutputJsonPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\governance-debt\workspace-installer-kpi-summary.json')
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

$kpiReport = Get-Content -LiteralPath $KpiReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
$assertion = $null
if (-not [string]::IsNullOrWhiteSpace($AssertionReportPath) -and (Test-Path -LiteralPath $AssertionReportPath -PathType Leaf)) {
    $assertion = Get-Content -LiteralPath $AssertionReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
}

$resolvedRepoSlug = if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_REPOSITORY)) {
        [string]$env:GITHUB_REPOSITORY
    } else {
        'svelderrainruiz/labview-cdev-surface'
    }
} else {
    $RepoSlug
}

$kpis = $kpiReport.kpis
$summaryLines = @(
    "# Workspace Installer KPI Signal"
    ""
    ("- Generated (UTC): {0}" -f ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')))
    ("- Scope profile: {0}" -f [string]$kpiReport.scope_profile)
    ("- Burn-in mode: {0}" -f [string]$kpiReport.burn_in_mode)
    ("- Run count: {0}" -f [string]$kpiReport.run_count)
    ""
    "## KPI Snapshot"
    ""
    "| KPI | Value |"
    "| --- | ---: |"
    ("| artifact_coverage_rate | {0} |" -f [string]$kpis.artifact_coverage_rate)
    ("| failure_summary_completeness | {0} |" -f [string]$kpis.failure_summary_completeness)
    ("| mean_time_to_diagnose_minutes | {0} |" -f [string]$kpis.mean_time_to_diagnose_minutes)
    ("| hang_recovery_time_minutes | {0} |" -f [string]$kpis.hang_recovery_time_minutes)
    ("| terminal_run_rate_60m | {0} |" -f [string]$kpis.terminal_run_rate_60m)
    ("| schema_conformance_rate | {0} |" -f [string]$kpis.schema_conformance_rate)
    ("| actionable_error_rate | {0} |" -f [string]$kpis.actionable_error_rate)
    ""
)

if ($null -ne $assertion) {
    $summaryLines += "## Gate Outcome"
    $summaryLines += ""
    $summaryLines += ("- blocking_failures: {0}" -f [string]$assertion.summary.blocking_failures)
    $summaryLines += ("- advisory_failures: {0}" -f [string]$assertion.summary.advisory_failures)
    $summaryLines += ("- mode: {0}" -f [string]$assertion.burn_in_mode)
    $summaryLines += ""
    if (@($assertion.breaches).Count -gt 0) {
        $summaryLines += "| Metric | Actual | Expected | Operator | Severity |"
        $summaryLines += "| --- | ---: | ---: | --- | --- |"
        foreach ($breach in @($assertion.breaches)) {
            $summaryLines += ("| {0} | {1} | {2} | {3} | {4} |" -f [string]$breach.metric, [string]$breach.actual, [string]$breach.expected, [string]$breach.operator, [string]$breach.severity)
        }
        $summaryLines += ""
    }
}

$resolvedMarkdownPath = [System.IO.Path]::GetFullPath($OutputMarkdownPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedMarkdownPath)
$summaryLines -join [Environment]::NewLine | Set-Content -LiteralPath $resolvedMarkdownPath -Encoding UTF8

$publishResult = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repo = $resolvedRepoSlug
    issue_title = $IssueTitle
    markdown_path = $resolvedMarkdownPath
    mode = if ($Apply) { 'apply' } else { 'dry_run' }
    issue_number = $null
    action = 'none'
}

if ($Apply) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh CLI was not found on PATH."
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:GH_TOKEN)) {
        throw "GH_TOKEN is required when -Apply is set."
    }

    $search = ('"{0}" in:title state:open' -f $IssueTitle)
    $existingNumber = gh issue list -R $resolvedRepoSlug --search $search --json number --jq '.[0].number'
    $body = Get-Content -LiteralPath $resolvedMarkdownPath -Raw
    if ([string]::IsNullOrWhiteSpace([string]$existingNumber)) {
        $labelArg = [string]::Join(',', @($IssueLabels | ForEach-Object { [string]$_ }))
        $newIssueUrl = gh issue create -R $resolvedRepoSlug --title $IssueTitle --body $body --label $labelArg
        $issueNumberText = gh issue view $newIssueUrl --json number --jq '.number'
        $publishResult.issue_number = [int]$issueNumberText
        $publishResult.action = 'created'
    } else {
        gh issue comment -R $resolvedRepoSlug $existingNumber --body $body | Out-Null
        $publishResult.issue_number = [int]$existingNumber
        $publishResult.action = 'commented'
    }
}

$resolvedJsonPath = [System.IO.Path]::GetFullPath($OutputJsonPath)
Ensure-Directory -Path (Split-Path -Parent $resolvedJsonPath)
$publishResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedJsonPath -Encoding UTF8
Write-Host "Workspace installer KPI summary markdown: $resolvedMarkdownPath"
Write-Host "Workspace installer KPI publish report: $resolvedJsonPath"
