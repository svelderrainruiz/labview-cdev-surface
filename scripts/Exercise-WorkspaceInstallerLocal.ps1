#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\local-installer-exercise'),

    [Parameter()]
    [string]$SmokeWorkspaceRoot = 'C:\dev-smoke-lvie',

    [Parameter()]
    [switch]$SkipSmokeInstall,

    [Parameter()]
    [switch]$SkipSmokeBuild,

    [Parameter()]
    [switch]$KeepSmokeWorkspace,

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter()]
    [string]$ReleaseInstallerName = 'lvie-cdev-workspace-installer.exe',

    [Parameter()]
    [string]$SmokeInstallerName = 'lvie-cdev-workspace-installer-smoke.exe',

    [Parameter()]
    [ValidateRange(60, 7200)]
    [int]$SmokeInstallerTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Sha256File {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $name = Split-Path -Path $FilePath -Leaf
    "{0} *{1}" -f $hash, $name | Set-Content -LiteralPath $OutputPath -Encoding ascii
    return $hash
}

function Write-SmokeLaunchLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
}

function Get-SmokeFailureSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SmokeReportPath,
        [Parameter()]
        [string]$SmokeWorkspaceRoot = ''
    )

    $execLogPath = ''
    $governanceReportPath = ''
    if (-not [string]::IsNullOrWhiteSpace($SmokeWorkspaceRoot)) {
        $execLogPath = Join-Path $SmokeWorkspaceRoot 'artifacts\workspace-installer-exec.log'
        $governanceReportPath = Join-Path $SmokeWorkspaceRoot 'artifacts\workspace-governance-latest.json'
    }

    if (-not (Test-Path -LiteralPath $SmokeReportPath -PathType Leaf)) {
        $details = @("Smoke report not found: $SmokeReportPath")
        if (-not [string]::IsNullOrWhiteSpace($execLogPath) -and (Test-Path -LiteralPath $execLogPath -PathType Leaf)) {
            $execTail = [string]::Join(' | ', @(
                    Get-Content -LiteralPath $execLogPath -ErrorAction SilentlyContinue |
                        Select-Object -Last 20 |
                        ForEach-Object { [string]$_ }
                ))
            $details += "exec_log=$execLogPath"
            if (-not [string]::IsNullOrWhiteSpace($execTail)) {
                $details += "exec_log_tail=$execTail"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($governanceReportPath) -and (Test-Path -LiteralPath $governanceReportPath -PathType Leaf)) {
            try {
                $governanceReport = Get-Content -LiteralPath $governanceReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $failedRepos = [int]$governanceReport.summary.failed
                $details += ("governance_report={0}; failed_repos={1}" -f $governanceReportPath, $failedRepos)
            } catch {
                $details += ("governance_report_parse_error={0}" -f $_.Exception.Message)
            }
        }
        return [string]::Join('; ', $details)
    }

    try {
        $report = Get-Content -LiteralPath $SmokeReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $status = [string]$report.status
        $errors = @(
            @($report.errors | ForEach-Object { [string]$_ }) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $warnings = @(
            @($report.warnings | ForEach-Object { [string]$_ }) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $topErrors = [string]::Join(' | ', @($errors | Select-Object -First 5))
        if ([string]::IsNullOrWhiteSpace($topErrors)) {
            $topErrors = '<none>'
        }
        return ("report_status={0}; errors={1}; warnings={2}; top_errors={3}" -f $status, $errors.Count, $warnings.Count, $topErrors)
    } catch {
        return "Failed to parse smoke report '$SmokeReportPath': $($_.Exception.Message)"
    }
}

function Write-SmokeTimeoutDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$SmokeReportPath
    )

    $process = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
    $children = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $ProcessId })
    $reportTail = if (Test-Path -LiteralPath $SmokeReportPath -PathType Leaf) {
        Get-SmokeFailureSummary -SmokeReportPath $SmokeReportPath
    } else {
        "Smoke report not found: $SmokeReportPath"
    }

    [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        smoke_installer_pid = $ProcessId
        smoke_report_path = $SmokeReportPath
        smoke_report_summary = $reportTail
        process = if ($null -ne $process) {
            [ordered]@{
                pid = $process.ProcessId
                parent_pid = $process.ParentProcessId
                executable = [string]$process.ExecutablePath
                command_line = [string]$process.CommandLine
            }
        } else {
            $null
        }
        child_processes = @($children | ForEach-Object {
            [ordered]@{
                pid = $_.ProcessId
                parent_pid = $_.ParentProcessId
                name = [string]$_.Name
                executable = [string]$_.ExecutablePath
                command_line = [string]$_.CommandLine
            }
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8

    return $OutputPath
}

function Stage-Payload {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PayloadRoot
    )

    $canonicalPayloadRoot = Join-Path $RepoRoot 'workspace-governance-payload'
    if (-not (Test-Path -LiteralPath $canonicalPayloadRoot -PathType Container)) {
        throw "Canonical payload root not found: $canonicalPayloadRoot"
    }

    Ensure-Directory -Path $PayloadRoot
    Copy-Item -Path (Join-Path $canonicalPayloadRoot '*') -Destination $PayloadRoot -Recurse -Force
    Ensure-Directory -Path (Join-Path $PayloadRoot 'scripts')
    Ensure-Directory -Path (Join-Path $PayloadRoot 'workspace-governance\tools\runner-cli\win-x64')

    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\Install-WorkspaceFromManifest.ps1') -Destination (Join-Path $PayloadRoot 'scripts\Install-WorkspaceFromManifest.ps1') -Force
}

function Convert-ManifestToWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $sourceRoot = [string]$manifest.workspace_root
    if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
        throw "Manifest is missing workspace_root: $ManifestPath"
    }

    $normalizedSource = [System.IO.Path]::GetFullPath($sourceRoot)
    $normalizedTarget = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $manifest.workspace_root = $normalizedTarget

    foreach ($repo in @($manifest.managed_repos)) {
        $repoPath = [string]$repo.path
        if ([string]::IsNullOrWhiteSpace($repoPath)) {
            throw "Managed repo path is empty in manifest: $ManifestPath"
        }

        $fullRepoPath = [System.IO.Path]::GetFullPath($repoPath)
        if ($fullRepoPath.StartsWith($normalizedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            $suffix = $fullRepoPath.Substring($normalizedSource.Length).TrimStart('\')
            $repo.path = if ([string]::IsNullOrWhiteSpace($suffix)) { $normalizedTarget } else { Join-Path $normalizedTarget $suffix }
        } else {
            # Keep non-workspace paths unchanged, but make deterministic absolute.
            $repo.path = $fullRepoPath
        }
    }

    $manifest | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $repoRoot 'scripts\Build-WorkspaceBootstrapInstaller.ps1'
$bundleRunnerCliScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "Build script not found: $buildScript"
}
if (-not (Test-Path -LiteralPath $bundleRunnerCliScript -PathType Leaf)) {
    throw "Runner CLI bundle script not found: $bundleRunnerCliScript"
}

foreach ($commandName in @('pwsh', 'git', 'gh', 'dotnet', 'g-cli')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found on PATH."
    }
}

$makensisPath = Join-Path $NsisRoot 'makensis.exe'
if (-not (Test-Path -LiteralPath $makensisPath -PathType Leaf)) {
    throw "Required NSIS binary not found at '$makensisPath'."
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$resolvedSmokeRoot = [System.IO.Path]::GetFullPath($SmokeWorkspaceRoot)
Ensure-Directory -Path $resolvedOutputRoot
Ensure-Directory -Path (Join-Path $resolvedOutputRoot 'bundle')
Ensure-Directory -Path (Join-Path $resolvedOutputRoot 'tmp')

$canonicalPayload = Join-Path $resolvedOutputRoot 'tmp\payload-canonical'
$smokePayload = Join-Path $resolvedOutputRoot 'tmp\payload-smoke'
if (Test-Path -LiteralPath $canonicalPayload -PathType Container) { Remove-Item -LiteralPath $canonicalPayload -Recurse -Force }
if (Test-Path -LiteralPath $smokePayload -PathType Container) { Remove-Item -LiteralPath $smokePayload -Recurse -Force }

Stage-Payload -RepoRoot $repoRoot -PayloadRoot $canonicalPayload
& $bundleRunnerCliScript `
    -ManifestPath (Join-Path $canonicalPayload 'workspace-governance\workspace-governance.json') `
    -OutputRoot (Join-Path $canonicalPayload 'workspace-governance\tools\runner-cli\win-x64') `
    -RepoName 'labview-icon-editor' `
    -Runtime 'win-x64'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build deterministic runner-cli payload bundle. Exit code: $LASTEXITCODE"
}

if (-not $SkipSmokeBuild) {
    Stage-Payload -RepoRoot $repoRoot -PayloadRoot $smokePayload
    $runnerCliPayloadRoot = Join-Path $canonicalPayload 'workspace-governance\tools\runner-cli\win-x64'
    foreach ($runnerCliFile in @('runner-cli.exe', 'runner-cli.exe.sha256', 'runner-cli.metadata.json')) {
        Copy-Item `
            -LiteralPath (Join-Path $runnerCliPayloadRoot $runnerCliFile) `
            -Destination (Join-Path $smokePayload 'workspace-governance\tools\runner-cli\win-x64') `
            -Force
    }
    Convert-ManifestToWorkspace -ManifestPath (Join-Path $smokePayload 'workspace-governance\workspace-governance.json') -WorkspaceRoot $resolvedSmokeRoot
} elseif (-not $SkipSmokeInstall) {
    Write-Host "SkipSmokeBuild was set; forcing SkipSmokeInstall."
    $SkipSmokeInstall = $true
}

$releaseInstallerPath = Join-Path $resolvedOutputRoot $ReleaseInstallerName
$releaseShaPath = Join-Path $resolvedOutputRoot "$ReleaseInstallerName.sha256"
$smokeInstallerPath = Join-Path $resolvedOutputRoot $SmokeInstallerName

if (Test-Path -LiteralPath $releaseInstallerPath -PathType Leaf) { Remove-Item -LiteralPath $releaseInstallerPath -Force }
if (Test-Path -LiteralPath $smokeInstallerPath -PathType Leaf) { Remove-Item -LiteralPath $smokeInstallerPath -Force }

& $buildScript -PayloadRoot $canonicalPayload -OutputPath $releaseInstallerPath -WorkspaceRootDefault 'C:\dev' -NsisRoot $NsisRoot
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build release installer. Exit code: $LASTEXITCODE"
}

if (-not $SkipSmokeBuild) {
    & $buildScript -PayloadRoot $smokePayload -OutputPath $smokeInstallerPath -WorkspaceRootDefault $resolvedSmokeRoot -NsisRoot $NsisRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build smoke installer. Exit code: $LASTEXITCODE"
    }
}

$releaseSha = Write-Sha256File -FilePath $releaseInstallerPath -OutputPath $releaseShaPath
$smokeReportPath = Join-Path $resolvedSmokeRoot 'artifacts\workspace-install-latest.json'
$smokeStatus = if ($SkipSmokeBuild) { 'build_skipped' } elseif ($SkipSmokeInstall) { 'install_skipped' } else { 'pending' }
$smokeExitCode = $null

if ((-not $SkipSmokeInstall) -and (-not $SkipSmokeBuild)) {
    if ((Test-Path -LiteralPath $resolvedSmokeRoot -PathType Container) -and (-not $KeepSmokeWorkspace)) {
        Remove-Item -LiteralPath $resolvedSmokeRoot -Recurse -Force
    }
    Ensure-Directory -Path $resolvedSmokeRoot
    $smokeArtifactsRoot = Join-Path $resolvedSmokeRoot 'artifacts'
    Ensure-Directory -Path $smokeArtifactsRoot
    $smokeLaunchLogPath = Join-Path $smokeArtifactsRoot 'workspace-installer-launch.log'
    Set-Content -LiteralPath $smokeLaunchLogPath -Value '' -Encoding utf8
    Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Starting smoke installer launch. installer={0}; timeout_seconds={1}; workspace_root={2}" -f $smokeInstallerPath, $SmokeInstallerTimeoutSeconds, $resolvedSmokeRoot)

    Write-Host ("Launching smoke installer: {0} (timeout={1}s)" -f $smokeInstallerPath, $SmokeInstallerTimeoutSeconds)
    $smokeProcess = Start-Process -FilePath $smokeInstallerPath -ArgumentList '/S' -PassThru
    Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke installer process started. pid={0}" -f $smokeProcess.Id)
    if (-not $smokeProcess.WaitForExit($SmokeInstallerTimeoutSeconds * 1000)) {
        $diagnosticsPath = Join-Path $resolvedOutputRoot 'smoke-installer-timeout-diagnostics.json'
        $writtenPath = Write-SmokeTimeoutDiagnostics -ProcessId $smokeProcess.Id -OutputPath $diagnosticsPath -SmokeReportPath $smokeReportPath
        Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke installer timeout reached. pid={0}; diagnostics={1}" -f $smokeProcess.Id, $writtenPath)
        try {
            Stop-Process -Id $smokeProcess.Id -Force -ErrorAction Stop
            Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Timed-out smoke installer process terminated. pid={0}" -f $smokeProcess.Id)
        } catch {
            Write-Warning ("Failed to terminate timed-out smoke installer process {0}: {1}" -f $smokeProcess.Id, $_.Exception.Message)
            Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Failed to terminate timed-out process pid={0}. error={1}" -f $smokeProcess.Id, $_.Exception.Message)
        }
        $summary = Get-SmokeFailureSummary -SmokeReportPath $smokeReportPath -SmokeWorkspaceRoot $resolvedSmokeRoot
        Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke timeout summary: {0}" -f $summary)
        throw "Smoke installer timed out after $SmokeInstallerTimeoutSeconds seconds (pid=$($smokeProcess.Id)). Diagnostics: $writtenPath. Launch log: $smokeLaunchLogPath. $summary"
    }
    $smokeExitCode = $smokeProcess.ExitCode
    Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke installer process exited. pid={0}; exit_code={1}" -f $smokeProcess.Id, $smokeExitCode)
    if ($smokeExitCode -ne 0) {
        $summary = Get-SmokeFailureSummary -SmokeReportPath $smokeReportPath -SmokeWorkspaceRoot $resolvedSmokeRoot
        Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke installer failed. summary={0}" -f $summary)
        throw "Smoke installer failed with exit code $smokeExitCode. Launch log: $smokeLaunchLogPath. $summary"
    }

    if (-not (Test-Path -LiteralPath $smokeReportPath -PathType Leaf)) {
        $summary = Get-SmokeFailureSummary -SmokeReportPath $smokeReportPath -SmokeWorkspaceRoot $resolvedSmokeRoot
        Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke install report missing after successful process exit. summary={0}" -f $summary)
        throw "Smoke install report not found after process exit. Launch log: $smokeLaunchLogPath. $summary"
    }

    $smokeInstallReport = Get-Content -LiteralPath $smokeReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $smokeStatus = [string]$smokeInstallReport.status
    Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke install report parsed. status={0}; report={1}" -f $smokeStatus, $smokeReportPath)
    if ($smokeStatus -ne 'succeeded') {
        $summary = Get-SmokeFailureSummary -SmokeReportPath $smokeReportPath -SmokeWorkspaceRoot $resolvedSmokeRoot
        Write-SmokeLaunchLog -LogPath $smokeLaunchLogPath -Message ("Smoke install report indicates failure. summary={0}" -f $summary)
        throw "Smoke install report status is '$smokeStatus' (expected 'succeeded'). Launch log: $smokeLaunchLogPath. $summary"
    }
}

$bundleRoot = Join-Path $resolvedOutputRoot 'bundle'
$bundleInstallerPath = Join-Path $bundleRoot $ReleaseInstallerName
$bundleShaPath = Join-Path $bundleRoot "$ReleaseInstallerName.sha256"
$bundleManifestPath = Join-Path $bundleRoot 'workspace-governance.json'
$bundleReadmePath = Join-Path $bundleRoot 'README-install.txt'
$bundleVerifyScriptPath = Join-Path $bundleRoot 'Verify-And-Install.ps1'

Copy-Item -LiteralPath $releaseInstallerPath -Destination $bundleInstallerPath -Force
Copy-Item -LiteralPath $releaseShaPath -Destination $bundleShaPath -Force
Copy-Item -LiteralPath (Join-Path $canonicalPayload 'workspace-governance\workspace-governance.json') -Destination $bundleManifestPath -Force

@"
LVIE C:\dev Workspace Installer Bundle

Files:
- $ReleaseInstallerName
- $ReleaseInstallerName.sha256
- workspace-governance.json
- Verify-And-Install.ps1

Target prerequisites:
- pwsh
- git
- gh (authenticated for GitHub API access)
- g-cli

Install:
1) Verify hash:
   Get-FileHash .\$ReleaseInstallerName -Algorithm SHA256
2) Run silent installer:
   .\$ReleaseInstallerName /S

Report path after install:
- C:\dev\artifacts\workspace-install-latest.json
"@ | Set-Content -LiteralPath $bundleReadmePath -Encoding utf8

@"
param(
  [string]`$InstallerPath = '.\$ReleaseInstallerName',
  [string]`$ShaFile = '.\$ReleaseInstallerName.sha256'
)
`$ErrorActionPreference = 'Stop'
foreach (`$cmd in @('pwsh','git','gh')) {
  if (-not (Get-Command `$cmd -ErrorAction SilentlyContinue)) {
    throw "Required command '`$cmd' is missing."
  }
}
if (-not (Test-Path -LiteralPath `$InstallerPath -PathType Leaf)) { throw "Installer not found: `$InstallerPath" }
if (-not (Test-Path -LiteralPath `$ShaFile -PathType Leaf)) { throw "SHA file not found: `$ShaFile" }
`$expected = (Get-Content -LiteralPath `$ShaFile -Raw).Split(' ')[0].Trim().ToLowerInvariant()
`$actual = (Get-FileHash -LiteralPath `$InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$expected -ne `$actual) { throw "SHA mismatch. Expected `$expected, got `$actual" }
Write-Host "SHA verified: `$actual"
`$p = Start-Process -FilePath `$InstallerPath -ArgumentList '/S' -Wait -PassThru
if (`$p.ExitCode -ne 0) { throw ('Installer failed with exit code ' + `$p.ExitCode) }
Write-Host 'Installer completed successfully.'
"@ | Set-Content -LiteralPath $bundleVerifyScriptPath -Encoding utf8

$bundleZipPath = Join-Path $resolvedOutputRoot 'lvie-cdev-workspace-installer-bundle.zip'
if (Test-Path -LiteralPath $bundleZipPath -PathType Leaf) { Remove-Item -LiteralPath $bundleZipPath -Force }
Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $bundleZipPath
$bundleZipSha = (Get-FileHash -LiteralPath $bundleZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$reportPath = Join-Path $resolvedOutputRoot 'exercise-report.json'
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repo_root = $repoRoot
    output_root = $resolvedOutputRoot
    release_installer = [ordered]@{
        path = $releaseInstallerPath
        sha256 = $releaseSha
    }
    smoke_installer = [ordered]@{
        path = $smokeInstallerPath
        workspace_root = $resolvedSmokeRoot
        status = $smokeStatus
        exit_code = $smokeExitCode
        report_path = $smokeReportPath
    }
    bundle = [ordered]@{
        root = $bundleRoot
        zip_path = $bundleZipPath
        zip_sha256 = $bundleZipSha
    }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host "Release installer: $releaseInstallerPath"
Write-Host "Release installer sha256: $releaseSha"
Write-Host "Bundle zip: $bundleZipPath"
Write-Host "Bundle zip sha256: $bundleZipSha"
Write-Host "Exercise report: $reportPath"
