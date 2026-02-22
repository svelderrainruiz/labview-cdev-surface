#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoSlug = 'svelderrainruiz/labview-cdev-surface',

    [Parameter()]
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GH_TOKEN = $env:GITHUB_TOKEN
}

if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
    throw 'RepoSlug is required.'
}
if ([string]::IsNullOrWhiteSpace($Branch)) {
    throw 'Branch is required.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI is required.'
}

$requiredContexts = @(
    'CI Pipeline',
    'Workspace Installer Contract',
    'Reproducibility Contract',
    'Provenance Contract'
)

$endpoint = "repos/$RepoSlug/branches/$([uri]::EscapeDataString($Branch))/protection"
$response = & gh api $endpoint 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read branch protection for $RepoSlug:$Branch. $([string]::Join([Environment]::NewLine, @($response)))"
}

$protection = $response | ConvertFrom-Json -ErrorAction Stop
$issues = @()

if ($null -eq $protection.required_status_checks -or -not [bool]$protection.required_status_checks.strict) {
    $issues += 'required_status_checks.strict is not enabled'
}

$actualContexts = @()
if ($null -ne $protection.required_status_checks -and $null -ne $protection.required_status_checks.contexts) {
    $actualContexts = @($protection.required_status_checks.contexts)
}

foreach ($context in $requiredContexts) {
    if ($actualContexts -notcontains $context) {
        $issues += "missing required status context: $context"
    }
}

if ($null -eq $protection.required_pull_request_reviews) {
    $issues += 'required_pull_request_reviews is not enabled'
}

if ($null -ne $protection.allow_force_pushes -and [bool]$protection.allow_force_pushes.enabled) {
    $issues += 'force pushes are allowed'
}

if ($null -ne $protection.allow_deletions -and [bool]$protection.allow_deletions.enabled) {
    $issues += 'branch deletions are allowed'
}

if ($issues.Count -gt 0) {
    $issues | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Governance contract satisfied for $RepoSlug:$Branch"
exit 0

