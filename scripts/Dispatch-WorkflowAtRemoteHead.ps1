#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workflow,

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$Remote = 'origin',

    [Parameter()]
    [string]$Branch = '',

    [Parameter()]
    [string[]]$Input = @(),

    [Parameter()]
    [switch]$SkipPush,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$RunSearchAttempts = 20,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$RunSearchPollSeconds = 3,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $tool = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $tool -or [string]::IsNullOrWhiteSpace([string]$tool.Source)) {
        throw "Required command '$Name' was not found on PATH."
    }
    return [string]$tool.Source
}

function Invoke-GitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git @Arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-GhCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& gh @Arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-CurrentGitBranch {
    $branchResult = Invoke-GitCommand -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    if ([int]$branchResult.exit_code -ne 0) {
        throw "Unable to resolve current branch. git rev-parse failed: $([string]::Join('`n', @($branchResult.output)))"
    }

    $resolved = ([string]($branchResult.output | Select-Object -First 1)).Trim()
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -eq 'HEAD') {
        throw "Current repository is in detached HEAD state. Specify -Branch explicitly."
    }

    return $resolved
}

function Resolve-GitHubRepoFromRemoteUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $url = $RemoteUrl.Trim()
    if ($url -match '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$') {
        return ("{0}/{1}" -f $Matches[1], $Matches[2])
    }
    if ($url -match '^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$') {
        return ("{0}/{1}" -f $Matches[1], $Matches[2])
    }
    if ($url -match '^ssh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
        return ("{0}/{1}" -f $Matches[1], $Matches[2])
    }

    throw "Unable to infer GitHub repository slug from remote URL '$RemoteUrl'. Provide -Repository explicitly."
}

function Parse-WorkflowInputs {
    param(
        [Parameter()]
        [string[]]$Pairs
    )

    $parsed = @()
    foreach ($pair in @($Pairs)) {
        $rawPair = [string]$pair
        if ([string]::IsNullOrWhiteSpace($rawPair)) {
            continue
        }
        $separator = $rawPair.IndexOf('=')
        if ($separator -lt 1) {
            throw "Invalid -Input value '$rawPair'. Expected key=value."
        }
        $key = $rawPair.Substring(0, $separator).Trim()
        $value = $rawPair.Substring($separator + 1)
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "Invalid -Input value '$rawPair'. Key is empty."
        }
        $parsed += [pscustomobject]@{
            key = $key
            value = $value
        }
    }

    return @($parsed)
}

[void](Ensure-Tool -Name 'git')
[void](Ensure-Tool -Name 'gh')

if ([string]::IsNullOrWhiteSpace($Workflow)) {
    throw '-Workflow is required.'
}

$resolvedBranch = if ([string]::IsNullOrWhiteSpace($Branch)) { Get-CurrentGitBranch } else { $Branch.Trim() }
$localHeadResult = Invoke-GitCommand -Arguments @('rev-parse', 'HEAD')
if ([int]$localHeadResult.exit_code -ne 0) {
    throw "Unable to resolve local HEAD SHA: $([string]::Join('`n', @($localHeadResult.output)))"
}
$localHeadSha = ([string]($localHeadResult.output | Select-Object -First 1)).Trim().ToLowerInvariant()
if ($localHeadSha -notmatch '^[0-9a-f]{40}$') {
    throw "Resolved local HEAD SHA is invalid: '$localHeadSha'"
}

$pushOutput = @()
if (-not $SkipPush.IsPresent) {
    $pushResult = Invoke-GitCommand -Arguments @('push', $Remote, ("HEAD:refs/heads/{0}" -f $resolvedBranch))
    $pushOutput = @($pushResult.output)
    if ([int]$pushResult.exit_code -ne 0) {
        throw "git push failed for '$Remote/$resolvedBranch': $([string]::Join('`n', @($pushResult.output)))"
    }
}

$lsRemoteResult = Invoke-GitCommand -Arguments @('ls-remote', $Remote, ("refs/heads/{0}" -f $resolvedBranch))
if ([int]$lsRemoteResult.exit_code -ne 0) {
    throw "git ls-remote failed for '$Remote/$resolvedBranch': $([string]::Join('`n', @($lsRemoteResult.output)))"
}
$lsLine = [string]($lsRemoteResult.output | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($lsLine)) {
    throw "No remote ref found for '$Remote/$resolvedBranch'."
}
$remoteHeadSha = (($lsLine -split '\s+')[0]).Trim().ToLowerInvariant()
if ($remoteHeadSha -notmatch '^[0-9a-f]{40}$') {
    throw "Resolved remote SHA is invalid for '$Remote/$resolvedBranch': '$remoteHeadSha'"
}
if ($remoteHeadSha -ne $localHeadSha) {
    throw "remote_head_mismatch: local='$localHeadSha' remote='$remoteHeadSha' branch='$resolvedBranch' remote='$Remote'"
}

$resolvedRepository = [string]$Repository
if ([string]::IsNullOrWhiteSpace($resolvedRepository)) {
    $remoteUrlResult = Invoke-GitCommand -Arguments @('remote', 'get-url', $Remote)
    if ([int]$remoteUrlResult.exit_code -ne 0) {
        throw "Unable to resolve remote URL for '$Remote': $([string]::Join('`n', @($remoteUrlResult.output)))"
    }
    $remoteUrl = ([string]($remoteUrlResult.output | Select-Object -First 1)).Trim()
    $resolvedRepository = Resolve-GitHubRepoFromRemoteUrl -RemoteUrl $remoteUrl
}

$dispatchArgs = @('workflow', 'run', $Workflow, '--repo', $resolvedRepository, '--ref', $resolvedBranch)
$workflowInputs = Parse-WorkflowInputs -Pairs $Input
foreach ($entry in @($workflowInputs)) {
    $dispatchArgs += @('-f', ("{0}={1}" -f [string]$entry.key, [string]$entry.value))
}

$dispatchRequestedAt = (Get-Date).ToUniversalTime()
$dispatchResult = Invoke-GhCommand -Arguments $dispatchArgs
if ([int]$dispatchResult.exit_code -ne 0) {
    throw "gh workflow run failed for '$Workflow' on '$resolvedRepository/$resolvedBranch': $([string]::Join('`n', @($dispatchResult.output)))"
}

$matchedRun = $null
$runListSnapshots = @()
for ($attempt = 1; $attempt -le $RunSearchAttempts; $attempt++) {
    $listArgs = @(
        'run', 'list',
        '--repo', $resolvedRepository,
        '--workflow', $Workflow,
        '--branch', $resolvedBranch,
        '--limit', '20',
        '--json', 'databaseId,headSha,status,conclusion,createdAt,displayTitle,event,url'
    )
    $listResult = Invoke-GhCommand -Arguments $listArgs
    if ([int]$listResult.exit_code -ne 0) {
        throw "gh run list failed while locating dispatched run: $([string]::Join('`n', @($listResult.output)))"
    }

    $jsonText = [string]::Join("`n", @($listResult.output))
    $runs = @()
    if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
        $decoded = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
        $runs = @($decoded)
    }
    $runListSnapshots += [ordered]@{
        attempt = $attempt
        count = @($runs).Count
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    }

    foreach ($run in @($runs)) {
        $runHead = ([string]$run.headSha).Trim().ToLowerInvariant()
        if ($runHead -ne $localHeadSha) {
            continue
        }

        $createdAt = [datetime]::MinValue
        try {
            $createdAt = [datetime]::Parse([string]$run.createdAt).ToUniversalTime()
        } catch {
            continue
        }

        if ($createdAt -lt $dispatchRequestedAt.AddMinutes(-5)) {
            continue
        }

        $matchedRun = $run
        break
    }

    if ($null -ne $matchedRun) {
        break
    }

    Start-Sleep -Seconds $RunSearchPollSeconds
}

if ($null -eq $matchedRun) {
    throw "Dispatched workflow run was not observed at expected head SHA '$localHeadSha' after $RunSearchAttempts attempts."
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workflow = $Workflow
    repository = $resolvedRepository
    remote = $Remote
    branch = $resolvedBranch
    local_head_sha = $localHeadSha
    remote_head_sha = $remoteHeadSha
    skip_push = [bool]$SkipPush
    push_output = @($pushOutput)
    dispatch_requested_at_utc = $dispatchRequestedAt.ToString('o')
    dispatch_output = @($dispatchResult.output)
    workflow_inputs = @($workflowInputs)
    matched_run = [ordered]@{
        database_id = [int64]$matchedRun.databaseId
        head_sha = [string]$matchedRun.headSha
        status = [string]$matchedRun.status
        conclusion = [string]$matchedRun.conclusion
        created_at = [string]$matchedRun.createdAt
        event = [string]$matchedRun.event
        url = [string]$matchedRun.url
        display_title = [string]$matchedRun.displayTitle
    }
    run_search_attempts = @($runListSnapshots)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    Write-Host ("Dispatch verification report: {0}" -f $resolvedOutputPath)
}

$report | ConvertTo-Json -Depth 12 | Write-Output
