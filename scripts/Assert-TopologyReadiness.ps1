#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ForkRepository = 'svelderrainruiz/labview-cdev-surface',

    [Parameter()]
    [string]$UpstreamRepository = 'LabVIEW-Community-CI-CD/labview-cdev-surface',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [switch]$RequireNotBehind,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Split-RepositorySlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $parts = $Repository.Split('/', 2)
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw ("repository_slug_invalid: '{0}' must use owner/name format." -f $Repository)
    }

    return @($parts[0], $parts[1])
}

$forkParts = Split-RepositorySlug -Repository $ForkRepository
$upstreamParts = Split-RepositorySlug -Repository $UpstreamRepository
$forkOwner = $forkParts[0]
$forkRepoName = $forkParts[1]
$upstreamRepoName = $upstreamParts[1]

if (-not [string]::Equals($forkRepoName, $upstreamRepoName, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("repository_name_mismatch: fork '{0}' and upstream '{1}' must reference the same repository name." -f $ForkRepository, $UpstreamRepository)
}

$compareRef = "{0}...{1}:{0}" -f $Branch, $forkOwner
$compareEndpoint = "repos/{0}/compare/{1}" -f $UpstreamRepository, $compareRef
$compare = Invoke-GhJson -Arguments @('api', $compareEndpoint)
if ($null -eq $compare) {
    throw ("compare_response_empty: unable to resolve topology comparison for '{0}'." -f $compareEndpoint)
}

$aheadBy = [int]$compare.ahead_by
$behindBy = [int]$compare.behind_by
$status = [string]$compare.status

$classification = if ($RequireNotBehind) { 'require_not_behind' } else { 'audit_only' }
$pass = $true
if ($RequireNotBehind -and $behindBy -gt 0) {
    $pass = $false
}

$headSha = ''
$compareCommits = @($compare.commits)
if ($compareCommits.Count -gt 0) {
    $headSha = [string]$compareCommits[-1].sha
} elseif ($null -ne $compare.PSObject.Properties['merge_base_commit']) {
    $headSha = [string]$compare.merge_base_commit.sha
}

$report = [ordered]@{
    timestamp_utc = Get-UtcNowIso
    fork_repository = $ForkRepository
    upstream_repository = $UpstreamRepository
    branch = $Branch
    compare_endpoint = $compareEndpoint
    compare_url = [string]$compare.html_url
    status = $status
    ahead_by = $aheadBy
    behind_by = $behindBy
    require_not_behind = [bool]$RequireNotBehind
    pass = $pass
    classification = $classification
    base_sha = [string]$compare.base_commit.sha
    merge_base_sha = [string]$compare.merge_base_commit.sha
    head_sha = $headSha
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath

if (-not $pass) {
    throw ("topology_not_ready: fork repository '{0}' is behind upstream '{1}' on branch '{2}' by {3} commit(s). Sync fork main with upstream main before pinning changes." -f $ForkRepository, $UpstreamRepository, $Branch, $behindBy)
}
