#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = (Get-Location).Path,

    [Parameter()]
    [string]$ManifestPath,

    [Parameter()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found: $ManifestPath"
}

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GH_TOKEN = $env:GITHUB_TOKEN
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$rollout = $manifest.installer_contract.container_parity_contract.required_check_rollout
if ($null -eq $rollout) {
    throw 'installer_contract.container_parity_contract.required_check_rollout is missing from manifest.'
}

$mode = [string]$rollout.mode
$condition = [string]$rollout.promotion_condition
$state = [string]$rollout.promotion_state
$targetRepo = [string]$rollout.promotion_target_repo
$targetBranch = [string]$rollout.promotion_target_branch
$workflowFile = [string]$rollout.promotion_workflow_file
$requiredSuccesses = [int]$rollout.promotion_required_successes
$window = [int]$rollout.promotion_observation_window
$failClosed = [bool]$rollout.fail_closed
$contextTokens = @($rollout.promotion_required_context_tokens | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($mode -ne 'stage_then_required') {
    throw "Unsupported rollout mode '$mode'. Expected 'stage_then_required'."
}
if ($condition -ne 'single_green_run') {
    throw "Unsupported promotion_condition '$condition'. Expected 'single_green_run'."
}
if ($state -notin @('staged', 'required')) {
    throw "Unsupported promotion_state '$state'. Expected 'staged' or 'required'."
}
if ([string]::IsNullOrWhiteSpace($targetRepo)) {
    throw 'promotion_target_repo is required.'
}
if ([string]::IsNullOrWhiteSpace($targetBranch)) {
    throw 'promotion_target_branch is required.'
}
if ([string]::IsNullOrWhiteSpace($workflowFile)) {
    throw 'promotion_workflow_file is required.'
}
if ($requiredSuccesses -lt 1) {
    throw "promotion_required_successes must be >= 1. Found '$requiredSuccesses'."
}
if ($window -lt $requiredSuccesses) {
    throw "promotion_observation_window must be >= promotion_required_successes. Found window=$window successes=$requiredSuccesses."
}
if (@($contextTokens).Count -eq 0) {
    throw 'promotion_required_context_tokens must include at least one token.'
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $gh) {
    throw 'gh CLI is required for promotion evaluation but is not available in PATH.'
}
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and $failClosed) {
    throw 'GH_TOKEN is required for fail-closed promotion evaluation.'
}

$endpoint = "repos/$targetRepo/actions/workflows/$workflowFile/runs?branch=$targetBranch&status=completed&per_page=$window"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $ghOutput = & gh api $endpoint 2>&1
    $ghExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($ghExitCode -ne 0) {
    throw ("promotion_evidence_unavailable: gh api call failed for endpoint '{0}'. Output:`n{1}" -f $endpoint, ([string]::Join("`n", @($ghOutput))))
}

try {
    $runsPayload = $ghOutput | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw ("promotion_evidence_unavailable: failed to parse gh api JSON output for endpoint '{0}'." -f $endpoint)
}

$runs = @($runsPayload.workflow_runs)
$successRuns = @($runs | Where-Object { [string]$_.conclusion -eq 'success' })
$promotionDue = (@($successRuns).Count -ge $requiredSuccesses)

$targetRepoContract = @($manifest.managed_repos | Where-Object { [string]$_.required_gh_repo -eq $targetRepo }) | Select-Object -First 1
if ($null -eq $targetRepoContract) {
    throw "managed_repos does not define promotion target repo '$targetRepo'."
}

$requiredStatusChecks = @($targetRepoContract.required_status_checks | ForEach-Object { [string]$_ })
$hasRequiredLinuxContext = $false
foreach ($ctx in $requiredStatusChecks) {
    foreach ($token in $contextTokens) {
        if ($ctx -match [regex]::Escape($token)) {
            $hasRequiredLinuxContext = $true
            break
        }
    }
    if ($hasRequiredLinuxContext) { break }
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    manifest_path = $ManifestPath
    target_repo = $targetRepo
    target_branch = $targetBranch
    workflow_file = $workflowFile
    rollout = [ordered]@{
        mode = $mode
        promotion_condition = $condition
        promotion_state = $state
        promotion_required_successes = $requiredSuccesses
        promotion_observation_window = $window
        promotion_required_context_tokens = @($contextTokens)
        fail_closed = $failClosed
    }
    evaluation = [ordered]@{
        observed_runs = @($runs).Count
        observed_success_runs = @($successRuns).Count
        promotion_due = $promotionDue
        latest_run = if (@($runs).Count -gt 0) { [string]$runs[0].html_url } else { '' }
        latest_success_run = if (@($successRuns).Count -gt 0) { [string]$successRuns[0].html_url } else { '' }
        required_status_checks = @($requiredStatusChecks)
        linux_gate_required_context_present = $hasRequiredLinuxContext
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Promotion report written: $OutputPath"
}

$reportJson = $report | ConvertTo-Json -Depth 10
Write-Output $reportJson

if ($state -eq 'staged' -and $promotionDue) {
    throw 'linux_gate_required_promotion_due: promotion condition is met but rollout state is still staged. Set promotion_state=required and require linux gate context in branch protection contract.'
}

if ($state -eq 'required' -and -not $hasRequiredLinuxContext) {
    throw 'linux_gate_required_context_missing: rollout state is required but linux gate required status check context is missing from manifest contract.'
}

exit 0
