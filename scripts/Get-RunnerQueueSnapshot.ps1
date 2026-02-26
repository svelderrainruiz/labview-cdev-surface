#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter()]
    [string]$WorkflowFile = '',

    [Parameter()]
    [string]$Branch = '',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$runnerLines = Invoke-GhText -Arguments @('api', "repos/$Repository/actions/runners", '--paginate', '--jq', '.runners[] | @json')
$runnerObjects = @()
foreach ($line in @($runnerLines -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
    $runnerObjects += @(([string]$line | ConvertFrom-Json -ErrorAction Stop))
}

$runArgs = @('run', 'list', '-R', $Repository, '--limit', '50', '--json', 'databaseId,status,conclusion,url,createdAt,headSha,workflowName')
if (-not [string]::IsNullOrWhiteSpace($WorkflowFile)) {
    $runArgs += @('--workflow', $WorkflowFile)
}
if (-not [string]::IsNullOrWhiteSpace($Branch)) {
    $runArgs += @('--branch', $Branch)
}
$runObjects = @(Invoke-GhJson -Arguments $runArgs)

$activeStatuses = @('queued', 'in_progress', 'requested', 'waiting', 'pending')
$activeRuns = @($runObjects | Where-Object { $activeStatuses -contains [string]$_.status })

$statusCounts = [ordered]@{}
foreach ($status in @($runObjects | ForEach-Object { [string]$_.status } | Sort-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($status)) { continue }
    $statusCounts[$status] = @($runObjects | Where-Object { [string]$_.status -eq $status }).Count
}

$report = [ordered]@{
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    workflow = $WorkflowFile
    branch = $Branch
    runner_summary = [ordered]@{
        total = @($runnerObjects).Count
        online = @($runnerObjects | Where-Object { [string]$_.status -eq 'online' }).Count
        busy = @($runnerObjects | Where-Object { [bool]$_.busy }).Count
    }
    run_summary = [ordered]@{
        total = @($runObjects).Count
        active = @($activeRuns).Count
        status_counts = $statusCounts
    }
    active_runs = @($activeRuns | Sort-Object { Parse-RunTimestamp -Run $_ } -Descending | ForEach-Object {
        [ordered]@{
            run_id = [string]$_.databaseId
            status = [string]$_.status
            conclusion = [string]$_.conclusion
            workflow = [string]$_.workflowName
            head_sha = [string]$_.headSha
            url = [string]$_.url
            created_at = [string]$_.createdAt
        }
    })
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath
