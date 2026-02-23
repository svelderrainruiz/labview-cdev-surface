#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter()]
    [ValidateSet('Install', 'Verify')]
    [string]$Mode = 'Install',

    [Parameter()]
    [Alias('ExecutionContext')]
    [string]$InstallExecutionContext = '',

    [Parameter()]
    [ValidateRange(60, 7200)]
    [int]$RunnerCliCommandTimeoutSeconds = 1800,

    [Parameter()]
    [ValidateRange(30, 1800)]
    [int]$GovernanceAuditTimeoutSeconds = 300,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Normalize-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    return ($Url.Trim().TrimEnd('/')).ToLowerInvariant()
}

function To-Bool {
    param($Value)
    return [bool]$Value
}

function Write-InstallerFeedback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[workspace-installer] {0}" -f $Message)
}

function Add-PostActionSequenceEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Sequence,
        [Parameter(Mandatory = $true)]
        [string]$Phase,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter()]
        [string]$Bitness = '',
        [Parameter()]
        [string]$Message = ''
    )

    $entry = [ordered]@{
        index = $Sequence.Count + 1
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        phase = $Phase
        bitness = $Bitness
        status = $Status
        message = $Message
    }
    [void]$Sequence.Add([pscustomobject]$entry)
}

function Get-PlatformName {
    if ($IsWindows) { return 'windows' }
    if ($IsLinux) { return 'linux' }
    if ($IsMacOS) { return 'macos' }
    return 'unknown'
}

function Convert-ToStableSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return [BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
}

function Resolve-ErrorTaxonomyTag {
    param(
        [Parameter()]
        [string]$Message = ''
    )

    $candidate = [string]$Message
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return 'unexpected_shape'
    }

    if ($candidate -match '(?i)\btimeout|timed out|hang\b') { return 'orchestration_timeout' }
    if ($candidate -match '(?i)\bproperty .* cannot be found|unexpected payload type|ConvertFrom-Json') { return 'unexpected_shape' }
    if ($candidate -match '(?i)\bgovernance audit|branch[-_ ]protection|Assert-WorkspaceGovernance') { return 'governance_audit' }
    if ($candidate -match '(?i)\bvip\b|vipc|vipm') { return 'vip_harness' }
    if ($candidate -match '(?i)\bppl\b|labview .* capability|supported-bitness|LabVIEW .* not found') { return 'labview_capability' }
    if ($candidate -match '(?i)\brunner-cli\b|metadata source_commit|SHA256 mismatch|bundle verification') { return 'runner_cli_contract' }
    if ($candidate -match '(?i)\bpayload\b|workspace-governance|manifest') { return 'payload_contract' }
    if ($candidate -match '(?i)Required command|not found on PATH|dependency') { return 'platform_dependency' }
    return 'unexpected_shape'
}

function Get-ErrorTaxonomy {
    param(
        [Parameter()][AllowEmptyCollection()][string[]]$Errors = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$Warnings = @()
    )

    $tags = @()
    foreach ($message in @($Errors + $Warnings)) {
        $tags += Resolve-ErrorTaxonomyTag -Message ([string]$message)
    }

    return @($tags | Sort-Object -Unique)
}

function Convert-ToUtcTimestamp {
    param(
        [Parameter()]
        [string]$Value = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
    } catch {
        return $null
    }
}

function Get-PhaseMetrics {
    param(
        [Parameter()][AllowEmptyCollection()]
        [System.Collections.ArrayList]$Sequence
    )

    $entries = @($Sequence)
    $phaseMap = [ordered]@{}
    $previousTimestamp = $null
    foreach ($entry in $entries) {
        $phase = [string]$entry.phase
        if ([string]::IsNullOrWhiteSpace($phase)) {
            continue
        }

        $parsedTimestamp = Convert-ToUtcTimestamp -Value ([string]$entry.timestamp_utc)
        $durationFromPrevious = 0.0
        if ($null -ne $previousTimestamp -and $null -ne $parsedTimestamp) {
            $durationFromPrevious = [Math]::Max(0, ($parsedTimestamp - $previousTimestamp).TotalSeconds)
        }
        if ($null -ne $parsedTimestamp) {
            $previousTimestamp = $parsedTimestamp
        }

        if (-not $phaseMap.Contains($phase)) {
            $phaseMap[$phase] = [ordered]@{
                occurrences = 0
                total_duration_seconds = 0.0
                last_status = ''
                last_message = ''
                last_bitness = ''
                last_timestamp_utc = ''
            }
        }

        $phaseMap[$phase].occurrences = [int]$phaseMap[$phase].occurrences + 1
        $phaseMap[$phase].total_duration_seconds = [Math]::Round(([double]$phaseMap[$phase].total_duration_seconds + [double]$durationFromPrevious), 3)
        $phaseMap[$phase].last_status = [string]$entry.status
        $phaseMap[$phase].last_message = [string]$entry.message
        $phaseMap[$phase].last_bitness = [string]$entry.bitness
        $phaseMap[$phase].last_timestamp_utc = [string]$entry.timestamp_utc
    }

    $firstTimestamp = $null
    $lastTimestamp = $null
    if ($entries.Count -gt 0) {
        $firstTimestamp = Convert-ToUtcTimestamp -Value ([string]$entries[0].timestamp_utc)
        $lastTimestamp = Convert-ToUtcTimestamp -Value ([string]$entries[-1].timestamp_utc)
    }

    $totalDurationSeconds = 0.0
    if ($null -ne $firstTimestamp -and $null -ne $lastTimestamp) {
        $totalDurationSeconds = [Math]::Round([Math]::Max(0, ($lastTimestamp - $firstTimestamp).TotalSeconds), 3)
    }

    return [ordered]@{
        total_duration_seconds = $totalDurationSeconds
        phase_count = $phaseMap.Count
        phases = $phaseMap
    }
}

function Get-InstallerArtifactIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRootPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputReportPath,
        [Parameter(Mandatory = $true)]
        [string]$GovernanceReportPath,
        [Parameter()]
        [string]$RunnerTemp = ''
    )

    $harnessRoot = if ([string]::IsNullOrWhiteSpace($RunnerTemp)) { '' } else { Join-Path $RunnerTemp 'installer-harness' }
    $artifacts = @(
        [ordered]@{ id = 'workspace-install-latest.json'; path = $OutputReportPath; scope = 'installer' },
        [ordered]@{ id = 'workspace-installer-launch.log'; path = Join-Path $WorkspaceRootPath 'artifacts\workspace-installer-launch.log'; scope = 'installer' },
        [ordered]@{ id = 'workspace-installer-phase-summary.json'; path = Join-Path (Split-Path -Parent $OutputReportPath) 'workspace-installer-phase-summary.json'; scope = 'installer' },
        [ordered]@{ id = 'workspace-governance-latest.json'; path = $GovernanceReportPath; scope = 'installer' },
        [ordered]@{ id = 'workspace-installer-vip-build.json'; path = Join-Path $WorkspaceRootPath 'labview-icon-editor\builds\status\workspace-installer-vip-build.json'; scope = 'installer' },
        [ordered]@{ id = 'harness-validation-report.json'; path = if ($harnessRoot -ne '') { Join-Path $harnessRoot 'harness-validation-report.json' } else { '' }; scope = 'harness' },
        [ordered]@{ id = 'runner-baseline-report.json'; path = if ($harnessRoot -ne '') { Join-Path $harnessRoot 'runner-baseline-report.json' } else { '' }; scope = 'harness' },
        [ordered]@{ id = 'machine-preflight-report.json'; path = if ($harnessRoot -ne '') { Join-Path $harnessRoot 'machine-preflight-report.json' } else { '' }; scope = 'harness' },
        [ordered]@{ id = 'smoke-installer-timeout-diagnostics.json'; path = if ($harnessRoot -ne '') { Join-Path $harnessRoot 'run-001\smoke-installer-timeout-diagnostics.json' } else { '' }; scope = 'harness' }
    )

    return @($artifacts | ForEach-Object {
        $resolvedPath = [string]$_.path
        $isResolvable = -not [string]::IsNullOrWhiteSpace($resolvedPath)
        [pscustomobject]@{
            id = [string]$_.id
            path = $resolvedPath
            scope = [string]$_.scope
            exists = if ($isResolvable) { [bool](Test-Path -LiteralPath $resolvedPath -PathType Leaf) } else { $false }
            resolvable = $isResolvable
        }
    })
}

function Get-DeveloperFeedback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter()][AllowEmptyCollection()][string[]]$Errors = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$Warnings = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$Taxonomy = @(),
        [Parameter()][AllowEmptyCollection()]$ArtifactIndex = @(),
        [Parameter()][AllowEmptyCollection()]$PostActionSequence = @()
    )

    $nextActions = @()
    if (@($Taxonomy) -contains 'orchestration_timeout') {
        $nextActions += 'Inspect workspace-installer-launch.log and smoke-installer-timeout-diagnostics.json for the blocked process.'
    }
    if (@($Taxonomy) -contains 'vip_harness') {
        $nextActions += 'Inspect workspace-installer-vip-build.json and VIPM logs under labview-icon-editor/builds/logs/vipm/.'
    }
    if (@($Taxonomy) -contains 'governance_audit') {
        $nextActions += 'Inspect workspace-governance-latest.json and branch-protection contract failures.'
    }
    if (@($Taxonomy) -contains 'runner_cli_contract') {
        $nextActions += 'Verify runner-cli bundle files (exe/sha256/metadata) and manifest pin alignment.'
    }
    if (@($Taxonomy) -contains 'labview_capability') {
        $nextActions += 'Check LabVIEW install roots and required bitness support for PPL/VIP gates.'
    }
    if (@($Taxonomy) -contains 'payload_contract') {
        $nextActions += 'Verify workspace-governance payload files were copied to the workspace root.'
    }
    if ($nextActions.Count -eq 0) {
        $nextActions += 'Inspect errors[] and post_action_sequence for the first failing phase.'
    }

    $failureSummaryCompleteness = 0.0
    if ($Status -eq 'succeeded') {
        $failureSummaryCompleteness = 1.0
    } else {
        if (@($Errors).Count -gt 0) { $failureSummaryCompleteness += 0.25 }
        if (@($Taxonomy).Count -gt 0) { $failureSummaryCompleteness += 0.25 }
        if (@($nextActions).Count -gt 0) { $failureSummaryCompleteness += 0.25 }
        if (@($ArtifactIndex | Where-Object { $_.id -eq 'workspace-installer-launch.log' -and $_.exists }).Count -gt 0) {
            $failureSummaryCompleteness += 0.25
        }
    }

    $estimatedDiagnoseMinutes = if ($Status -eq 'succeeded') { 5 } elseif (@($Taxonomy) -contains 'orchestration_timeout') { 12 } else { 15 }

    $firstFailing = @(
        $PostActionSequence |
            Where-Object { [string]$_.status -in @('fail', 'failed', 'blocked') } |
            Select-Object -First 1
    )

    return [ordered]@{
        summary = if ($Status -eq 'succeeded') { 'Installer completed successfully with diagnostics attached.' } else { 'Installer failed; follow next_actions and artifact pointers for one-pass triage.' }
        next_actions = @($nextActions | Select-Object -Unique)
        estimated_time_to_diagnose_minutes = $estimatedDiagnoseMinutes
        actionable_error_count = @($Errors).Count
        warning_count = @($Warnings).Count
        failure_summary_completeness = [Math]::Round($failureSummaryCompleteness, 3)
        first_failing_phase = if (@($firstFailing).Count -gt 0) { [string]$firstFailing[0].phase } else { '' }
    }
}

function Invoke-PowerShellFileWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter()]
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    return Invoke-ExecutableWithTimeout `
        -FilePath 'pwsh' `
        -Arguments (@('-NoProfile', '-File', $FilePath) + @($Arguments)) `
        -TimeoutSeconds $TimeoutSeconds
}

function Get-TimeoutProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    if (-not $IsWindows) {
        return [ordered]@{
            process = $null
            child_processes = @()
        }
    }

    $process = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
    $children = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ParentProcessId -eq $ProcessId }
    )

    return [ordered]@{
        process = if ($null -ne $process) {
            [ordered]@{
                pid = [int]$process.ProcessId
                parent_pid = [int]$process.ParentProcessId
                name = [string]$process.Name
                executable = [string]$process.ExecutablePath
                command_line = [string]$process.CommandLine
            }
        } else {
            $null
        }
        child_processes = @(
            $children | ForEach-Object {
                [ordered]@{
                    pid = [int]$_.ProcessId
                    parent_pid = [int]$_.ParentProcessId
                    name = [string]$_.Name
                    executable = [string]$_.ExecutablePath
                    command_line = [string]$_.CommandLine
                }
            }
        )
    }
}

function Convert-ToProcessArgumentString {
    param(
        [Parameter()]
        [string[]]$Arguments = @()
    )

    if (@($Arguments).Count -eq 0) {
        return ''
    }

    $escapedArguments = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value.Length -eq 0) {
            '""'
            continue
        }

        if ($value -notmatch '[\s"]') {
            $value
            continue
        }

        # Escape according to CreateProcess command-line rules.
        $escapedValue = $value -replace '(\\*)"', '$1$1\"'
        $escapedValue = $escapedValue -replace '(\\+)$', '$1$1'
        '"' + $escapedValue + '"'
    }

    return [string]::Join(' ', @($escapedArguments))
}

function Invoke-ExecutableWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter()]
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [Parameter()]
        [string]$WorkingDirectory = ''
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("workspace-installer-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("workspace-installer-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $startUtc = (Get-Date).ToUniversalTime()
    $argumentString = Convert-ToProcessArgumentString -Arguments $Arguments

    try {
        $startProcessParams = @{
            FilePath = $FilePath
            ArgumentList = $argumentString
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startProcessParams['WorkingDirectory'] = $WorkingDirectory
        }

        $process = Start-Process `
            @startProcessParams

        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        $timeoutProcessTree = [ordered]@{
            process = $null
            child_processes = @()
        }
        if ($timedOut) {
            $timeoutProcessTree = Get-TimeoutProcessTree -ProcessId $process.Id
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                # Keep timeout semantics even if process already exited.
            }
            foreach ($child in @($timeoutProcessTree.child_processes)) {
                try {
                    Stop-Process -Id ([int]$child.pid) -Force -ErrorAction Stop
                } catch {
                    # Child process may already be gone; keep timeout semantics.
                }
            }
        }

        $durationSeconds = [Math]::Round([Math]::Max(0, ((Get-Date).ToUniversalTime() - $startUtc).TotalSeconds), 3)
        $stdoutLines = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) } else { @() }
        $stderrLines = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue) } else { @() }
        $combined = @($stdoutLines + $stderrLines) | ForEach-Object { [string]$_ }

        return [pscustomobject]@{
            timed_out = $timedOut
            exit_code = if ($timedOut) { 124 } else { $process.ExitCode }
            duration_seconds = $durationSeconds
            output = @($combined)
            timeout_process_tree = $timeoutProcessTree
        }
    } finally {
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-LabVIEWInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionYear,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    $candidates = @()
    $regPaths = @()
    if ($Bitness -eq '32') {
        $candidates += "C:\Program Files (x86)\National Instruments\LabVIEW $VersionYear"
        $regPaths += "HKLM:\SOFTWARE\WOW6432Node\National Instruments\LabVIEW $VersionYear"
    } else {
        $candidates += "C:\Program Files\National Instruments\LabVIEW $VersionYear"
        $regPaths += "HKLM:\SOFTWARE\National Instruments\LabVIEW $VersionYear"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    foreach ($regPath in $regPaths) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            foreach ($name in @('Path', 'InstallDir', 'InstallPath')) {
                $value = [string]$props.$name
                if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value -PathType Container)) {
                    return $value
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-ExpectedShaFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShaFilePath
    )

    if (-not (Test-Path -LiteralPath $ShaFilePath -PathType Leaf)) {
        throw "SHA256 file not found: $ShaFilePath"
    }

    $raw = (Get-Content -LiteralPath $ShaFilePath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "SHA256 file is empty: $ShaFilePath"
    }

    $expected = ($raw.Split(' ')[0]).Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        throw "SHA256 file has invalid hash format: $ShaFilePath"
    }
    return $expected
}

function Get-LatestVipPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $vipRoot = Join-Path -Path $RepoRoot -ChildPath 'builds\VI Package'
    if (-not (Test-Path -LiteralPath $vipRoot -PathType Container)) {
        return ''
    }

    $latestVip = Get-ChildItem -Path $vipRoot -Filter '*.vip' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestVip) {
        return ''
    }

    return [string]$latestVip.FullName
}

function Get-IsContainerExecution {
    param(
        [Parameter()]
        [string]$InstallerExecutionContext = ''
    )

    $containerModeFlag = [string]$env:LVIE_INSTALLER_CONTAINER_MODE
    if ($containerModeFlag -match '^(?i:1|true|yes)$') {
        return $true
    }

    $dotnetContainerFlag = [string]$env:DOTNET_RUNNING_IN_CONTAINER
    if ($dotnetContainerFlag -match '^(?i:1|true|yes)$') {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($InstallerExecutionContext) -and $InstallerExecutionContext -match '(?i)container') {
        return $true
    }

    if ($IsWindows) {
        if (Test-Path -LiteralPath 'C:\.dockerenv' -PathType Leaf -ErrorAction SilentlyContinue) {
            return $true
        }
    } else {
        if (Test-Path -LiteralPath '/.dockerenv' -PathType Leaf -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    return $false
}

function Get-LabVIEWContainerExecutionContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $contractPath = Join-Path -Path $RepoRoot -ChildPath '.lvcontainer'
    $result = [ordered]@{
        status = 'not_found'
        contract_path = $contractPath
        raw = ''
        execution_year = ''
        os = ''
        message = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
            $result.message = ".lvcontainer was not found at '$contractPath'."
            return [pscustomobject]$result
        }

        $raw = (Get-Content -LiteralPath $contractPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw ".lvcontainer is empty: $contractPath"
        }

        $result.raw = $raw
        if ($raw -match '^(?<year>\d{4})(?:q\d+)?-(?<os>linux|windows)$') {
            $result.execution_year = [string]$Matches.year
            $result.os = [string]$Matches.os
            $result.status = 'resolved'
            $result.message = "Resolved execution LabVIEW year '$($result.execution_year)' from .lvcontainer."
            return [pscustomobject]$result
        }

        if ($raw -match '^latest-(?<os>linux|windows)$') {
            $result.os = [string]$Matches.os
            $result.status = 'unresolved_year'
            $result.message = "Container tag '$raw' does not encode a specific LabVIEW year."
            return [pscustomobject]$result
        }

        throw "Unsupported .lvcontainer value '$raw'. Expected '<year>q<quarter>-<os>' or 'latest-<os>'."
    } catch {
        $result.status = 'invalid'
        $result.message = $_.Exception.Message
        return [pscustomobject]$result
    }
}

function Get-LabVIEWSourceVersionFromRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $versionPath = Join-Path -Path $RepoRoot -ChildPath '.lvversion'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        return ''
    }

    return [string]((Get-Content -LiteralPath $versionPath -Raw).Trim())
}

function Set-LabVIEWSourceVersionInRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $versionPath = Join-Path -Path $RepoRoot -ChildPath '.lvversion'
    $result = [ordered]@{
        status = 'not_run'
        path = $versionPath
        previous = ''
        current = $Version
        message = ''
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Version)) {
            throw 'Requested LabVIEW source version is empty.'
        }

        $existing = ''
        if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
            $existing = [string]((Get-Content -LiteralPath $versionPath -Raw).Trim())
        }
        $result.previous = $existing

        if ([string]$existing -eq [string]$Version) {
            $result.status = 'already_aligned'
            $result.message = ".lvversion already matches '$Version'."
            return [pscustomobject]$result
        }

        Set-Content -LiteralPath $versionPath -Value $Version -Encoding ascii
        $result.status = 'updated'
        $result.message = "Set .lvversion to '$Version' for container runner-cli compatibility."
    } catch {
        $result.status = 'failed'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Unblock-ExecutableForAutomation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = [ordered]@{
        status = 'skipped'
        message = ''
        attempted = $false
    }

    if (-not $IsWindows) {
        $result.message = 'Unblock step is only applicable on Windows.'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.message = "Executable not found for unblock step: $Path"
        return [pscustomobject]$result
    }

    $result.attempted = $true
    try {
        Unblock-File -LiteralPath $Path -ErrorAction Stop
        $result.status = 'unblocked'
        $result.message = "Unblocked executable '$Path'."
    } catch {
        $zoneIdentifierPath = '{0}:Zone.Identifier' -f $Path
        try {
            if (Test-Path -LiteralPath $zoneIdentifierPath -PathType Leaf -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $zoneIdentifierPath -Force -ErrorAction Stop
                $result.status = 'zone_identifier_removed'
                $result.message = "Removed Zone.Identifier from '$Path'."
            } else {
                $result.status = 'warning'
                $result.message = "Unable to unblock '$Path'. $($_.Exception.Message)"
            }
        } catch {
            $result.status = 'warning'
            $result.message = "Unable to unblock '$Path'. $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$result
}

function Set-RunnerCliPreflightEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliPath,
        [Parameter()]
        [string]$WorktreeRoot = ''
    )

    $env:LVIE_RUNNER_CLI_PATH = $RunnerCliPath
    $env:LVIE_RUNNER_CLI_SKIP_BUILD = '1'
    $env:LVIE_RUNNER_CLI_SKIP_DOWNLOAD = '1'
    if (-not [string]::IsNullOrWhiteSpace($WorktreeRoot)) {
        $env:LVIE_WORKTREE_ROOT = $WorktreeRoot
    }
}

function Invoke-RunnerCliPplCapabilityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliPath,
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$PinnedSha,
        [Parameter(Mandatory = $true)]
        [string]$ExecutionLabviewYear,
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliLabviewVersion,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$RequiredBitness,
        [Parameter(Mandatory = $true)]
        [int]$CommandTimeoutSeconds
    )

    $statusRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\status'

    $result = [ordered]@{
        status = 'pending'
        message = ''
        runner_cli_path = $RunnerCliPath
        repo_path = $IconEditorRepoPath
        required_labview_year = $ExecutionLabviewYear
        runner_cli_labview_version = $RunnerCliLabviewVersion
        required_bitness = $RequiredBitness
        output_ppl_path = Join-Path $IconEditorRepoPath 'resource\plugins\lv_icon.lvlibp'
        output_ppl_snapshot_path = Join-Path $statusRoot ("workspace-installer-ppl-{0}.lvlibp" -f $RequiredBitness)
        command = @()
        command_output = @()
        command_timeout_seconds = $CommandTimeoutSeconds
        timed_out = $false
        timeout_process_tree = [ordered]@{
            process = $null
            child_processes = @()
        }
        duration_seconds = 0.0
        exit_code = $null
        labview_install_root = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $RunnerCliPath -PathType Leaf)) {
            throw "runner-cli executable not found: $RunnerCliPath"
        }
        if (-not (Test-Path -LiteralPath $IconEditorRepoPath -PathType Container)) {
            throw "Icon editor repository path not found: $IconEditorRepoPath"
        }
        if ($PinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Pinned SHA is invalid for capability check: $PinnedSha"
        }

        Ensure-Directory -Path $statusRoot

        $labviewRoot = Get-LabVIEWInstallRoot -VersionYear $ExecutionLabviewYear -Bitness $RequiredBitness
        if ([string]::IsNullOrWhiteSpace($labviewRoot)) {
            throw "LabVIEW $ExecutionLabviewYear ($RequiredBitness-bit) is required for runner-cli PPL capability but was not found."
        }
        $result.labview_install_root = $labviewRoot

        $commitArg = if ($PinnedSha.Length -gt 12) { $PinnedSha.Substring(0, 12) } else { $PinnedSha }
        $commandArgs = @(
            'ppl', 'build',
            '--repo-root', $IconEditorRepoPath,
            '--labview-version', $RunnerCliLabviewVersion,
            '--supported-bitness', $RequiredBitness,
            '--major', '0',
            '--minor', '0',
            '--patch', '0',
            '--build', '1',
            '--commit', $commitArg,
            '--skip-worktree-root-check'
        )
        $result.command = @($commandArgs)

        Set-RunnerCliPreflightEnvironment `
            -RunnerCliPath $RunnerCliPath `
            -WorktreeRoot (Split-Path -Parent $IconEditorRepoPath)
        $commandInvocation = Invoke-ExecutableWithTimeout `
            -FilePath $RunnerCliPath `
            -Arguments $commandArgs `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -WorkingDirectory $IconEditorRepoPath
        $result.command_output = @($commandInvocation.output | ForEach-Object { [string]$_ })
        $result.timed_out = [bool]$commandInvocation.timed_out
        $result.timeout_process_tree = $commandInvocation.timeout_process_tree
        $result.duration_seconds = [double]$commandInvocation.duration_seconds
        $result.exit_code = $commandInvocation.exit_code
        if ($result.timed_out) {
            throw "runner-cli ppl build timed out after $CommandTimeoutSeconds seconds."
        }
        if ($result.exit_code -ne 0) {
            $outputSummary = [string]::Join(' | ', @($result.command_output | Select-Object -First 20))
            throw "runner-cli ppl build failed with exit code $($result.exit_code). Output: $outputSummary"
        }

        if (-not (Test-Path -LiteralPath $result.output_ppl_path -PathType Leaf)) {
            throw "runner-cli reported success, but PPL output was not found: $($result.output_ppl_path)"
        }
        Copy-Item -LiteralPath $result.output_ppl_path -Destination $result.output_ppl_snapshot_path -Force

        $result.status = 'pass'
        $result.message = "runner-cli PPL capability check passed for execution LabVIEW $ExecutionLabviewYear x$RequiredBitness (source version $RunnerCliLabviewVersion)."
    } catch {
        if ($null -eq $result.exit_code) {
            $result.exit_code = 1
        }
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Invoke-RunnerCliVipPackageHarnessCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliPath,
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$PinnedSha,
        [Parameter(Mandatory = $true)]
        [string]$ExecutionLabviewYear,
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliLabviewVersion,
        [Parameter(Mandatory = $true)]
        [string]$RequiredBitness,
        [Parameter(Mandatory = $true)]
        [int]$CommandTimeoutSeconds
    )

    $statusRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\status'
    $releaseNotesPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-release-notes.md'
    $displayInfoPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vip-display-info.json'
    $vipcAuditPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vipc-audit.json'
    $vipBuildStatusPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vip-build.json'
    $vipcPath = '.github/actions/apply-vipc/runner_dependencies.vipc'
    $vipbPath = 'Tooling/deployment/NI Icon editor.vipb'
    $vipLabviewVersion = if ($ExecutionLabviewYear -match '^\d{4}$') { [string]$ExecutionLabviewYear } else { [string]$RunnerCliLabviewVersion }

    $result = [ordered]@{
        status = 'pending'
        message = ''
        runner_cli_path = $RunnerCliPath
        repo_path = $IconEditorRepoPath
        required_labview_year = $ExecutionLabviewYear
        runner_cli_labview_version = $RunnerCliLabviewVersion
        vip_labview_version = $vipLabviewVersion
        required_bitness = $RequiredBitness
        vipb_path = $vipbPath
        vipc_path = $vipcPath
        vipc_assert_output_path = $vipcAuditPath
        vip_build_status_path = $vipBuildStatusPath
        release_notes_path = $releaseNotesPath
        display_information_path = $displayInfoPath
        output_vip_path = ''
        command = [ordered]@{
            vipc_assert = @()
            vipc_apply = @()
            vip_build = @()
        }
        command_output = [ordered]@{
            vipc_assert = @()
            vipc_apply = @()
            vip_build = @()
        }
        command_timeout_seconds = $CommandTimeoutSeconds
        timed_out = $false
        timeout_process_tree = [ordered]@{
            process = $null
            child_processes = @()
        }
        duration_seconds = 0.0
        exit_code = $null
        labview_install_root = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $RunnerCliPath -PathType Leaf)) {
            throw "runner-cli executable not found: $RunnerCliPath"
        }
        if (-not (Test-Path -LiteralPath $IconEditorRepoPath -PathType Container)) {
            throw "Icon editor repository path not found: $IconEditorRepoPath"
        }
        if ($PinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Pinned SHA is invalid for VIP harness check: $PinnedSha"
        }
        if ($RequiredBitness -ne '64') {
            throw "VIP harness currently supports only 64-bit execution. requested=$RequiredBitness"
        }

        $labviewRoot = Get-LabVIEWInstallRoot -VersionYear $ExecutionLabviewYear -Bitness $RequiredBitness
        if ([string]::IsNullOrWhiteSpace($labviewRoot)) {
            throw "LabVIEW $ExecutionLabviewYear ($RequiredBitness-bit) is required for runner-cli VIP harness but was not found."
        }
        $result.labview_install_root = $labviewRoot

        Ensure-Directory -Path $statusRoot
        if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) {
            @(
                "# Workspace Installer Harness"
                ""
                "Automated VI package build initiated by the workspace bootstrap installer."
            ) | Set-Content -LiteralPath $releaseNotesPath -Encoding UTF8
        }

        $displayPayload = [ordered]@{
            'Company Name' = 'LabVIEW Community CI/CD'
            'Product Name' = 'LabVIEW Icon Editor'
            'Product Description Summary' = 'Automated VI Package harness build from workspace installer.'
            'Product Description' = 'Workspace bootstrap installer harness execution.'
            'License Agreement Name' = ''
            'Author Name (Person or Company)' = 'LabVIEW Community CI/CD'
            'Product Homepage (URL)' = 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor'
            'Legal Copyright' = '(c) LabVIEW Community CI/CD'
            'Release Notes - Change Log' = 'Workspace installer harness run.'
            'Package Version' = [ordered]@{
                major = 0
                minor = 0
                patch = 0
                build = 1
            }
        }
        $displayPayload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $displayInfoPath -Encoding UTF8

        $vipcAssertArgs = @(
            'vipc', 'assert',
            '--repo-root', $IconEditorRepoPath,
            '--supported-bitness', $RequiredBitness,
            '--vipc-path', $vipcPath,
            '--labview-version', $vipLabviewVersion,
            '--output-path', $vipcAuditPath,
            '--fail-on-mismatch'
        )
        $result.command.vipc_assert = @($vipcAssertArgs)
        Write-InstallerFeedback -Message 'Running runner-cli vipc assert.'
        Set-RunnerCliPreflightEnvironment `
            -RunnerCliPath $RunnerCliPath `
            -WorktreeRoot (Split-Path -Parent $IconEditorRepoPath)
        $vipcAssertInvocation = Invoke-ExecutableWithTimeout `
            -FilePath $RunnerCliPath `
            -Arguments $vipcAssertArgs `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -WorkingDirectory $IconEditorRepoPath
        $result.command_output.vipc_assert = @($vipcAssertInvocation.output | ForEach-Object { [string]$_ })
        $result.duration_seconds = [double]$result.duration_seconds + [double]$vipcAssertInvocation.duration_seconds
        $result.timed_out = [bool]$vipcAssertInvocation.timed_out
        if ($result.timed_out) {
            $result.timeout_process_tree = $vipcAssertInvocation.timeout_process_tree
            throw "runner-cli vipc assert timed out after $CommandTimeoutSeconds seconds."
        }
        $vipcAssertExit = $vipcAssertInvocation.exit_code
        if ($vipcAssertExit -ne 0) {
            $vipcApplyArgs = @(
                'vipc', 'apply',
                '--repo-root', $IconEditorRepoPath,
                '--supported-bitness', $RequiredBitness,
                '--vipc-path', $vipcPath,
                '--labview-version', $vipLabviewVersion,
                '--skip-worktree-root-check'
            )
            $result.command.vipc_apply = @($vipcApplyArgs)
            Write-InstallerFeedback -Message 'VIPC assert reported dependency drift; applying VIPC dependencies.'
            $vipcApplyInvocation = Invoke-ExecutableWithTimeout `
                -FilePath $RunnerCliPath `
                -Arguments $vipcApplyArgs `
                -TimeoutSeconds $CommandTimeoutSeconds `
                -WorkingDirectory $IconEditorRepoPath
            $result.command_output.vipc_apply = @($vipcApplyInvocation.output | ForEach-Object { [string]$_ })
            $result.duration_seconds = [double]$result.duration_seconds + [double]$vipcApplyInvocation.duration_seconds
            if ([bool]$vipcApplyInvocation.timed_out) {
                $result.timed_out = $true
                $result.timeout_process_tree = $vipcApplyInvocation.timeout_process_tree
                throw "runner-cli vipc apply timed out after $CommandTimeoutSeconds seconds."
            }
            $vipcApplyExit = $vipcApplyInvocation.exit_code
            if ($vipcApplyExit -ne 0) {
                $applySummary = [string]::Join(' | ', @($result.command_output.vipc_apply | Select-Object -First 20))
                throw "runner-cli vipc apply failed with exit code $vipcApplyExit. Output: $applySummary"
            }

            Write-InstallerFeedback -Message 'Re-running runner-cli vipc assert after apply.'
            $vipcAssertAfterApplyInvocation = Invoke-ExecutableWithTimeout `
                -FilePath $RunnerCliPath `
                -Arguments $vipcAssertArgs `
                -TimeoutSeconds $CommandTimeoutSeconds `
                -WorkingDirectory $IconEditorRepoPath
            $result.command_output.vipc_assert += @($vipcAssertAfterApplyInvocation.output | ForEach-Object { [string]$_ })
            $result.duration_seconds = [double]$result.duration_seconds + [double]$vipcAssertAfterApplyInvocation.duration_seconds
            if ([bool]$vipcAssertAfterApplyInvocation.timed_out) {
                $result.timed_out = $true
                $result.timeout_process_tree = $vipcAssertAfterApplyInvocation.timeout_process_tree
                throw "runner-cli vipc assert timed out after apply ($CommandTimeoutSeconds seconds)."
            }
            $vipcAssertAfterApplyExit = $vipcAssertAfterApplyInvocation.exit_code
            if ($vipcAssertAfterApplyExit -ne 0) {
                $assertSummary = [string]::Join(' | ', @($result.command_output.vipc_assert | Select-Object -First 20))
                throw "runner-cli vipc assert failed after apply with exit code $vipcAssertAfterApplyExit. Output: $assertSummary"
            }
        }

        $commitArg = if ($PinnedSha.Length -gt 12) { $PinnedSha.Substring(0, 12) } else { $PinnedSha }
        $vipBuildArgs = @(
            'vip', 'build',
            '--repo-root', $IconEditorRepoPath,
            '--supported-bitness', $RequiredBitness,
            '--vipb-path', $vipbPath,
            '--labview-version', $vipLabviewVersion,
            '--labview-minor-revision', '0',
            '--major', '0',
            '--minor', '0',
            '--patch', '0',
            '--build', '1',
            '--commit', $commitArg,
            '--release-notes-file', $releaseNotesPath,
            '--display-information-json-path', $displayInfoPath,
            '--status-path', $vipBuildStatusPath,
            '--vipm-timeout-seconds', '1200',
            '--skip-worktree-root-check'
        )
        $result.command.vip_build = @($vipBuildArgs)
        Write-InstallerFeedback -Message 'Running runner-cli vip build.'
        $vipBuildInvocation = Invoke-ExecutableWithTimeout `
            -FilePath $RunnerCliPath `
            -Arguments $vipBuildArgs `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -WorkingDirectory $IconEditorRepoPath
        $result.command_output.vip_build = @($vipBuildInvocation.output | ForEach-Object { [string]$_ })
        $result.duration_seconds = [double]$result.duration_seconds + [double]$vipBuildInvocation.duration_seconds
        $result.timed_out = [bool]$vipBuildInvocation.timed_out
        if ($result.timed_out) {
            $result.timeout_process_tree = $vipBuildInvocation.timeout_process_tree
            throw "runner-cli vip build timed out after $CommandTimeoutSeconds seconds."
        }
        $result.exit_code = $vipBuildInvocation.exit_code
        if ($result.exit_code -ne 0) {
            $buildSummary = [string]::Join(' | ', @($result.command_output.vip_build | Select-Object -First 20))
            throw "runner-cli vip build failed with exit code $($result.exit_code). Output: $buildSummary"
        }

        $vipPath = ''
        if (Test-Path -LiteralPath $vipBuildStatusPath -PathType Leaf) {
            try {
                $vipStatus = Get-Content -LiteralPath $vipBuildStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $vipPath = [string]$vipStatus.vip_path
            } catch {
                # Fall back to filesystem scan when status parsing fails.
            }
        }
        if ([string]::IsNullOrWhiteSpace($vipPath)) {
            $vipPath = Get-LatestVipPath -RepoRoot $IconEditorRepoPath
        }
        $result.output_vip_path = $vipPath

        if ([string]::IsNullOrWhiteSpace($vipPath) -or -not (Test-Path -LiteralPath $vipPath -PathType Leaf)) {
            throw "runner-cli vip build reported success, but no .vip output was found."
        }

        $result.status = 'pass'
        $result.message = 'runner-cli VIP harness build passed.'
    } catch {
        if ($null -eq $result.exit_code) {
            $result.exit_code = 1
        }
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

$resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$payloadRoot = Split-Path -Parent $resolvedManifestPath

$errors = @()
$warnings = @()
$dependencyChecks = @()
$repositoryResults = @()
$payloadSync = [ordered]@{
    status = 'pending'
    files = @()
    message = ''
}
$runnerCliBundle = [ordered]@{
    status = 'not_checked'
    message = ''
    root = Join-Path $payloadRoot 'tools\runner-cli\win-x64'
    exe_path = ''
    sha_file = ''
    metadata_file = ''
    expected_sha256 = ''
    actual_sha256 = ''
    unblock_status = 'not_run'
    unblock_message = ''
}
$labviewVersionResolution = [ordered]@{
    is_container_execution = $false
    lvcontainer_path = ''
    lvcontainer_raw = ''
    lvversion_container_shim = [ordered]@{
        status = 'not_run'
        path = ''
        previous = ''
        current = ''
        message = ''
    }
    execution_labview_year = '2020'
    runner_cli_labview_version = '2020'
    message = ''
}
$pplCapabilityChecks = [ordered]@{
    '32' = [ordered]@{
        status = 'not_run'
        message = ''
        runner_cli_path = ''
        repo_path = ''
        required_labview_year = '2020'
        runner_cli_labview_version = '2020'
        required_bitness = '32'
        output_ppl_path = ''
        output_ppl_snapshot_path = ''
        command = @()
        command_output = @()
        command_timeout_seconds = $RunnerCliCommandTimeoutSeconds
        timed_out = $false
        timeout_process_tree = [ordered]@{
            process = $null
            child_processes = @()
        }
        duration_seconds = 0.0
        exit_code = $null
        labview_install_root = ''
    }
    '64' = [ordered]@{
        status = 'not_run'
        message = ''
        runner_cli_path = ''
        repo_path = ''
        required_labview_year = '2020'
        runner_cli_labview_version = '2020'
        required_bitness = '64'
        output_ppl_path = ''
        output_ppl_snapshot_path = ''
        command = @()
        command_output = @()
        command_timeout_seconds = $RunnerCliCommandTimeoutSeconds
        timed_out = $false
        timeout_process_tree = [ordered]@{
            process = $null
            child_processes = @()
        }
        duration_seconds = 0.0
        exit_code = $null
        labview_install_root = ''
    }
}
$vipPackageBuildCheck = [ordered]@{
    status = 'not_run'
    message = ''
    runner_cli_path = ''
    repo_path = ''
    required_labview_year = '2020'
    runner_cli_labview_version = '2020'
    vip_labview_version = '2020'
    required_bitness = '64'
    vipb_path = ''
    vipc_path = ''
    vipc_assert_output_path = ''
    vip_build_status_path = ''
    release_notes_path = ''
    display_information_path = ''
    output_vip_path = ''
    command = [ordered]@{
        vipc_assert = @()
        vipc_apply = @()
        vip_build = @()
    }
    command_output = [ordered]@{
        vipc_assert = @()
        vipc_apply = @()
        vip_build = @()
    }
    command_timeout_seconds = $RunnerCliCommandTimeoutSeconds
    timed_out = $false
    timeout_process_tree = [ordered]@{
        process = $null
        child_processes = @()
    }
    duration_seconds = 0.0
    exit_code = $null
    labview_install_root = ''
}
$governanceAudit = [ordered]@{
    invoked = $false
    status = 'not_run'
    exit_code = $null
    report_path = Join-Path $resolvedWorkspaceRoot 'artifacts\workspace-governance-latest.json'
    command_timeout_seconds = $GovernanceAuditTimeoutSeconds
    timed_out = $false
    timeout_process_tree = [ordered]@{
        process = $null
        child_processes = @()
    }
    duration_seconds = 0.0
    command_output = @()
    branch_only_failure = $false
    branch_failures = @()
    non_branch_failures = @()
    message = ''
}
$postActionSequence = New-Object System.Collections.ArrayList

try {
    Write-InstallerFeedback -Message ("Starting workspace {0} run. workspace={1}" -f $Mode.ToLowerInvariant(), $resolvedWorkspaceRoot)
    Ensure-Directory -Path $resolvedWorkspaceRoot
    Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)

    Write-InstallerFeedback -Message 'Checking required commands on PATH.'
    foreach ($commandName in @('pwsh', 'git', 'gh', 'g-cli')) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        $check = [ordered]@{
            command = $commandName
            present = To-Bool ($null -ne $cmd)
            path = if ($null -ne $cmd) { $cmd.Source } else { '' }
        }
        $dependencyChecks += [pscustomobject]$check
        if (-not $check.present) {
            $errors += "Required command '$commandName' was not found on PATH."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        throw "Manifest not found: $resolvedManifestPath"
    }

    Write-InstallerFeedback -Message ("Loading manifest: {0}" -f $resolvedManifestPath)
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest.managed_repos -or @($manifest.managed_repos).Count -eq 0) {
        throw "Manifest does not contain managed_repos entries: $resolvedManifestPath"
    }

    $requiredLabviewYear = '2020'
    $requiredPplBitnesses = @('32', '64')
    $requiredVipBitness = '64'
    $skipVipHarness = ([string]$env:LVIE_SKIP_VIP_HARNESS -match '^(?i:1|true|yes)$')
    $runnerCliRelativeRoot = 'tools\runner-cli\win-x64'
    if ($null -ne $manifest.PSObject.Properties['installer_contract']) {
        $installerContract = $manifest.installer_contract
        if ($null -ne $installerContract.PSObject.Properties['labview_gate']) {
            $labviewGate = $installerContract.labview_gate
            if (($null -ne $labviewGate.PSObject.Properties['required_year']) -and -not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_year)) {
                $requiredLabviewYear = [string]$labviewGate.required_year
            }
            if ($null -ne $labviewGate.PSObject.Properties['required_ppl_bitnesses']) {
                $requiredPplBitnesses = @($labviewGate.required_ppl_bitnesses)
            }
            if (($null -ne $labviewGate.PSObject.Properties['required_vip_bitness']) -and -not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_vip_bitness)) {
                $requiredVipBitness = [string]$labviewGate.required_vip_bitness
            }
            if (($null -ne $labviewGate.PSObject.Properties['required_bitness']) -and -not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_bitness)) {
                $requiredVipBitness = [string]$labviewGate.required_bitness
            }
        }
        if ($null -ne $installerContract.PSObject.Properties['runner_cli_bundle']) {
            $runnerCliBundleContract = $installerContract.runner_cli_bundle
            if (($null -ne $runnerCliBundleContract.PSObject.Properties['relative_root']) -and -not [string]::IsNullOrWhiteSpace([string]$runnerCliBundleContract.relative_root)) {
                $runnerCliRelativeRoot = [string]$runnerCliBundleContract.relative_root
            }
        }
    }

    $requiredPplBitnesses = @(
        @($requiredPplBitnesses |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -in @('32', '64') } |
            Select-Object -Unique |
            Sort-Object)
    )
    if (@($requiredPplBitnesses).Count -eq 0) {
        throw "Installer contract requires at least one supported PPL bitness ['32','64']."
    }
    if ($requiredVipBitness -notin @('32', '64')) {
        throw "Installer contract requires VIP bitness to be one of ['32','64']; received '$requiredVipBitness'."
    }
    if ($requiredVipBitness -notin $requiredPplBitnesses) {
        throw "Installer contract requires VIP bitness '$requiredVipBitness' to be included in required_ppl_bitnesses."
    }
    $runnerCliLabviewVersion = [string]$requiredLabviewYear
    if ($skipVipHarness) {
        Write-InstallerFeedback -Message 'VIP harness is disabled by LVIE_SKIP_VIP_HARNESS.'
    }

    if ($Mode -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($InstallExecutionContext)) {
            throw "Install mode requires -ExecutionContext NsisInstall (or LocalInstallerExercise)."
        }
        if ($InstallExecutionContext -notin @('NsisInstall', 'LocalInstallerExercise')) {
            throw "Unsupported execution context '$InstallExecutionContext'. Expected NsisInstall or LocalInstallerExercise."
        }
    }

    foreach ($bitness in $requiredPplBitnesses) {
        $pplCapabilityChecks[$bitness].required_labview_year = $requiredLabviewYear
        $pplCapabilityChecks[$bitness].runner_cli_labview_version = $runnerCliLabviewVersion
        $pplCapabilityChecks[$bitness].required_bitness = $bitness
    }
    $vipPackageBuildCheck.required_labview_year = $requiredLabviewYear
    $vipPackageBuildCheck.runner_cli_labview_version = $runnerCliLabviewVersion
    $vipPackageBuildCheck.vip_labview_version = $requiredLabviewYear
    $vipPackageBuildCheck.required_bitness = $requiredVipBitness

    $repoTotal = @($manifest.managed_repos).Count
    $repoIndex = 0
    foreach ($repo in @($manifest.managed_repos)) {
        $repoIndex++
        $repoPath = [string]$repo.path
        $repoName = [string]$repo.repo_name
        $defaultBranch = [string]$repo.default_branch
        $requiredGhRepo = [string]$repo.required_gh_repo
        $pinnedSha = ([string]$repo.pinned_sha).ToLowerInvariant()
        $existsBefore = Test-Path -LiteralPath $repoPath -PathType Container

        $repoResult = [ordered]@{
            path = $repoPath
            repo_name = $repoName
            required_gh_repo = $requiredGhRepo
            default_branch = $defaultBranch
            pinned_sha = $pinnedSha
            exists_before = $existsBefore
            action = if ($existsBefore) { 'verify_existing' } else { 'clone_missing' }
            status = 'pass'
            issues = @()
            message = ''
            remote_checks = @()
            head_sha = ''
            branch_state = ''
        }

        try {
            Write-InstallerFeedback -Message ("[{0}/{1}] Verifying repository contract: {2}" -f $repoIndex, $repoTotal, $repoPath)
            if ($pinnedSha -notmatch '^[0-9a-f]{40}$') {
                throw "Manifest entry '$repoPath' has invalid pinned_sha '$pinnedSha'."
            }

            if (-not $existsBefore) {
                if ($Mode -eq 'Verify') {
                    throw "Repository path missing in Verify mode: $repoPath"
                }

                $originUrl = [string]$repo.required_remotes.origin
                if ([string]::IsNullOrWhiteSpace($originUrl)) {
                    throw "Manifest entry '$repoPath' is missing required_remotes.origin."
                }

                Ensure-Directory -Path (Split-Path -Parent $repoPath)
                $cloneOutput = & git clone $originUrl $repoPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git clone failed for '$repoPath'. $([string]::Join("`n", @($cloneOutput)))"
                }
            }

            if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -PathType Container)) {
                throw "Path is not a git repository: $repoPath"
            }

            foreach ($remoteProp in $repo.required_remotes.PSObject.Properties) {
                $remoteName = [string]$remoteProp.Name
                $expectedUrl = [string]$remoteProp.Value
                if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($expectedUrl)) {
                    continue
                }

                $currentUrlRaw = & git -C $repoPath remote get-url $remoteName 2>$null
                $currentExit = $LASTEXITCODE
                $currentUrl = if ($currentExit -eq 0) { [string]$currentUrlRaw.Trim() } else { '' }
                $remoteCheck = [ordered]@{
                    remote = $remoteName
                    expected = $expectedUrl
                    before = $currentUrl
                    after = $currentUrl
                    status = 'ok'
                    message = ''
                }

                if ($currentExit -ne 0) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'missing'
                        $remoteCheck.message = 'Remote is missing on an existing repository.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_missing_$remoteName"
                    } else {
                        $addOutput = & git -C $repoPath remote add $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to add remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($addOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'added'
                        } else {
                            $remoteCheck.status = 'add_mismatch'
                            $remoteCheck.message = 'Added remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_add_mismatch_$remoteName"
                        }
                    }
                } elseif ((Normalize-Url $currentUrl) -ne (Normalize-Url $expectedUrl)) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'mismatch'
                        $remoteCheck.message = 'Existing remote URL does not match expected value.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_mismatch_$remoteName"
                    } else {
                        $setOutput = & git -C $repoPath remote set-url $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to set remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($setOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'updated'
                        } else {
                            $remoteCheck.status = 'update_mismatch'
                            $remoteCheck.message = 'Updated remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_update_mismatch_$remoteName"
                        }
                    }
                }

                $repoResult.remote_checks += [pscustomobject]$remoteCheck
            }

            if (-not [string]::IsNullOrWhiteSpace($defaultBranch)) {
                $fetchOutput = & git -C $repoPath fetch --no-tags origin $defaultBranch 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to fetch origin/$defaultBranch for '$repoPath'. $([string]::Join("`n", @($fetchOutput)))"
                }

                & git -C $repoPath show-ref --verify "refs/remotes/origin/$defaultBranch" *> $null
                if ($LASTEXITCODE -ne 0) {
                    $repoResult.status = 'fail'
                    $repoResult.issues += 'default_branch_missing_on_origin'
                }
            }

            if (-not $existsBefore -and $Mode -eq 'Install') {
                $checkoutOutput = & git -C $repoPath checkout --detach $pinnedSha 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to checkout pinned_sha '$pinnedSha' in '$repoPath'. $([string]::Join("`n", @($checkoutOutput)))"
                }
            }

            $headOutput = & git -C $repoPath rev-parse HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to resolve HEAD for '$repoPath'. $([string]::Join("`n", @($headOutput)))"
            }
            $headSha = [string]$headOutput.Trim().ToLowerInvariant()
            $repoResult.head_sha = $headSha
            if ($headSha -ne $pinnedSha) {
                $repoResult.status = 'fail'
                $repoResult.issues += 'head_sha_mismatch'
            }

            $branchOutput = & git -C $repoPath symbolic-ref --quiet --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0) {
                $branchName = [string]$branchOutput.Trim()
                $repoResult.branch_state = $branchName
                if (-not [string]::IsNullOrWhiteSpace($defaultBranch) -and $branchName -ne $defaultBranch) {
                    $repoResult.status = 'fail'
                    $repoResult.issues += 'branch_identity_mismatch'
                }
            } else {
                $repoResult.branch_state = 'detached'
            }

            if ($repoResult.status -eq 'pass') {
                $repoResult.message = 'Repository satisfies deterministic manifest contract.'
            } else {
                $repoResult.message = 'Repository violates deterministic manifest contract.'
            }
        } catch {
            $repoResult.status = 'fail'
            $repoResult.issues += 'exception'
            $repoResult.message = $_.Exception.Message
        }

        if ($repoResult.status -ne 'pass') {
            $errors += "$repoPath :: $($repoResult.message)"
        }

        $repositoryResults += [pscustomobject]$repoResult
    }
    $repoFailureCount = @($repositoryResults | Where-Object { [string]$_.status -ne 'pass' }).Count
    if ($repoFailureCount -eq 0) {
        Add-PostActionSequenceEntry `
            -Sequence $postActionSequence `
            -Phase 'repository-contracts' `
            -Status 'pass' `
            -Message ("Verified repository contract for {0} managed repos." -f $repoTotal)
    } else {
        Add-PostActionSequenceEntry `
            -Sequence $postActionSequence `
            -Phase 'repository-contracts' `
            -Status 'fail' `
            -Message ("Repository contract checks failed for {0} managed repos." -f $repoFailureCount)
    }

    Write-InstallerFeedback -Message 'Syncing governance payload into workspace root.'
    $payloadFiles = @(
        @{ source = (Join-Path $payloadRoot 'AGENTS.md'); destination = (Join-Path $resolvedWorkspaceRoot 'AGENTS.md') },
        @{ source = (Join-Path $payloadRoot 'workspace-governance.json'); destination = (Join-Path $resolvedWorkspaceRoot 'workspace-governance.json') },
        @{ source = (Join-Path $payloadRoot 'diagnostics-kpi.json'); destination = (Join-Path $resolvedWorkspaceRoot 'diagnostics-kpi.json') },
        @{ source = (Join-Path $payloadRoot 'scripts\Assert-WorkspaceGovernance.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1') },
        @{ source = (Join-Path $payloadRoot 'scripts\Test-PolicyContracts.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Test-PolicyContracts.ps1') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.exe'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.exe') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.exe.sha256'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.exe.sha256') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.metadata.json'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.metadata.json') }
    )

    try {
        Ensure-Directory -Path (Join-Path $resolvedWorkspaceRoot 'scripts')

        foreach ($item in $payloadFiles) {
            $sourcePath = [string]$item.source
            $destinationPath = [string]$item.destination
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Payload file is missing: $sourcePath"
            }
            Ensure-Directory -Path (Split-Path -Parent $destinationPath)
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $payloadSync.files += [pscustomobject]@{
                source = $sourcePath
                destination = $destinationPath
                status = 'copied'
            }
        }

        $payloadSync.status = 'success'
        $payloadSync.message = 'Workspace governance payload copied to workspace root.'
    } catch {
        $payloadSync.status = 'failed'
        $payloadSync.message = $_.Exception.Message
        $errors += "Payload sync failed. $($payloadSync.message)"
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'payload-sync' `
        -Status ([string]$payloadSync.status) `
        -Message ([string]$payloadSync.message)

    $runnerCliBundleRoot = Join-Path $resolvedWorkspaceRoot $runnerCliRelativeRoot
    $runnerCliExePath = Join-Path $runnerCliBundleRoot 'runner-cli.exe'
    $runnerCliShaPath = Join-Path $runnerCliBundleRoot 'runner-cli.exe.sha256'
    $runnerCliMetadataPath = Join-Path $runnerCliBundleRoot 'runner-cli.metadata.json'
    $runnerCliBundle.root = $runnerCliBundleRoot
    $runnerCliBundle.exe_path = $runnerCliExePath
    $runnerCliBundle.sha_file = $runnerCliShaPath
    $runnerCliBundle.metadata_file = $runnerCliMetadataPath

    $iconEditorRepoEntry = @($manifest.managed_repos | Where-Object { [string]$_.repo_name -eq 'labview-icon-editor' }) | Select-Object -First 1
    $iconEditorRepoPath = if ($null -ne $iconEditorRepoEntry) { [string]$iconEditorRepoEntry.path } else { '' }
    $iconEditorPinnedSha = if ($null -ne $iconEditorRepoEntry) { ([string]$iconEditorRepoEntry.pinned_sha).ToLowerInvariant() } else { '' }

    $labviewVersionResolution.is_container_execution = Get-IsContainerExecution -InstallerExecutionContext $InstallExecutionContext
    $labviewVersionResolution.execution_labview_year = [string]$requiredLabviewYear
    $labviewVersionResolution.runner_cli_labview_version = [string]$runnerCliLabviewVersion
    if (-not [string]::IsNullOrWhiteSpace($iconEditorRepoPath)) {
        if ($labviewVersionResolution.is_container_execution) {
            $containerContract = Get-LabVIEWContainerExecutionContract -RepoRoot $iconEditorRepoPath
            $labviewVersionResolution.lvcontainer_path = [string]$containerContract.contract_path
            $labviewVersionResolution.lvcontainer_raw = [string]$containerContract.raw

            if ([string]$containerContract.status -eq 'resolved') {
                $requiredLabviewYear = [string]$containerContract.execution_year
                $runnerCliLabviewVersion = [string]$containerContract.execution_year
                $labviewVersionResolution.execution_labview_year = [string]$requiredLabviewYear
                $labviewVersionResolution.runner_cli_labview_version = [string]$runnerCliLabviewVersion
                $labviewVersionResolution.message = "Container execution resolved execution and runner-cli source version from .lvcontainer: '$([string]$containerContract.raw)' => '$requiredLabviewYear'. .lvversion is ignored in container execution."
                Write-InstallerFeedback -Message ("Container LabVIEW contract resolved from .lvcontainer: execution_year={0}; source_version={1}; tag={2}; source_contract=.lvcontainer" -f $requiredLabviewYear, $runnerCliLabviewVersion, [string]$containerContract.raw)
            } else {
                $warnings += "Container execution detected but .lvcontainer could not resolve an execution year. $([string]$containerContract.message)"
                Write-InstallerFeedback -Message ("Container LabVIEW contract warning: {0}" -f [string]$containerContract.message)
                $runnerCliLabviewVersion = [string]$requiredLabviewYear
                $labviewVersionResolution.runner_cli_labview_version = [string]$runnerCliLabviewVersion
                $warnings += "Container execution kept runner-cli source version pinned to execution year '$requiredLabviewYear' because .lvcontainer was unresolved. .lvversion is not used in container execution."
            }
        } else {
            $sourceVersionRaw = Get-LabVIEWSourceVersionFromRepo -RepoRoot $iconEditorRepoPath
            if (-not [string]::IsNullOrWhiteSpace($sourceVersionRaw)) {
                $runnerCliLabviewVersion = [string]$sourceVersionRaw
                $labviewVersionResolution.runner_cli_labview_version = [string]$runnerCliLabviewVersion
                $labviewVersionResolution.message = "runner-cli source LabVIEW version resolved from .lvversion: '$runnerCliLabviewVersion'."
            } else {
                $warnings += "LabVIEW source version file '.lvversion' was not found at '$iconEditorRepoPath'; runner-cli will use execution year '$requiredLabviewYear' as source version."
            }
        }
    }

    if ($labviewVersionResolution.is_container_execution -and -not [string]::IsNullOrWhiteSpace($iconEditorRepoPath)) {
        $versionShim = Set-LabVIEWSourceVersionInRepo -RepoRoot $iconEditorRepoPath -Version ([string]$runnerCliLabviewVersion)
        $labviewVersionResolution.lvversion_container_shim = [ordered]@{
            status = [string]$versionShim.status
            path = [string]$versionShim.path
            previous = [string]$versionShim.previous
            current = [string]$versionShim.current
            message = [string]$versionShim.message
        }

        if ([string]$versionShim.status -eq 'failed') {
            $errors += "Container source version shim failed. $([string]$versionShim.message)"
        } else {
            Write-InstallerFeedback -Message ("Container source version shim status={0}; path={1}; previous='{2}'; current='{3}'." -f [string]$versionShim.status, [string]$versionShim.path, [string]$versionShim.previous, [string]$versionShim.current)
        }
    }

    foreach ($bitness in $requiredPplBitnesses) {
        $pplCapabilityChecks[$bitness].required_labview_year = $requiredLabviewYear
        $pplCapabilityChecks[$bitness].runner_cli_labview_version = $runnerCliLabviewVersion
    }
    $vipPackageBuildCheck.required_labview_year = $requiredLabviewYear
    $vipPackageBuildCheck.runner_cli_labview_version = $runnerCliLabviewVersion
    $vipPackageBuildCheck.vip_labview_version = $requiredLabviewYear

    try {
        Write-InstallerFeedback -Message 'Verifying bundled runner-cli integrity.'
        if ([string]::IsNullOrWhiteSpace($iconEditorRepoPath)) {
            throw "Manifest does not define managed repo entry 'labview-icon-editor'."
        }
        if ([string]::IsNullOrWhiteSpace($iconEditorPinnedSha) -or $iconEditorPinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Manifest entry 'labview-icon-editor' has invalid pinned_sha '$iconEditorPinnedSha'."
        }
        if (-not (Test-Path -LiteralPath $runnerCliExePath -PathType Leaf)) {
            throw "Bundled runner-cli executable was not found: $runnerCliExePath"
        }
        $expectedSha = Get-ExpectedShaFromFile -ShaFilePath $runnerCliShaPath
        $actualSha = (Get-FileHash -LiteralPath $runnerCliExePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $runnerCliBundle.expected_sha256 = $expectedSha
        $runnerCliBundle.actual_sha256 = $actualSha
        if ($expectedSha -ne $actualSha) {
            throw "Bundled runner-cli SHA256 mismatch. expected=$expectedSha actual=$actualSha"
        }

        if (-not (Test-Path -LiteralPath $runnerCliMetadataPath -PathType Leaf)) {
            throw "Bundled runner-cli metadata was not found: $runnerCliMetadataPath"
        }

        $runnerCliMetadata = Get-Content -LiteralPath $runnerCliMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $metadataSourceCommit = ([string]$runnerCliMetadata.source_commit).ToLowerInvariant()
        if ($metadataSourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "runner-cli metadata source_commit is invalid: $metadataSourceCommit"
        }
        if ($metadataSourceCommit -ne $iconEditorPinnedSha) {
            throw "runner-cli metadata source_commit does not match manifest pin for labview-icon-editor."
        }

        $unblockResult = Unblock-ExecutableForAutomation -Path $runnerCliExePath
        $runnerCliBundle.unblock_status = [string]$unblockResult.status
        $runnerCliBundle.unblock_message = [string]$unblockResult.message
        if ([string]$unblockResult.status -eq 'warning') {
            $warnings += "runner-cli unblock warning. $([string]$unblockResult.message)"
        } else {
            Write-InstallerFeedback -Message ([string]$unblockResult.message)
        }

        $runnerCliBundle.status = 'pass'
        $runnerCliBundle.message = 'Bundled runner-cli payload integrity checks passed.'
    } catch {
        $runnerCliBundle.status = 'fail'
        $runnerCliBundle.message = $_.Exception.Message
        $errors += "Runner CLI bundle verification failed. $($runnerCliBundle.message)"
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'runner-cli-bundle' `
        -Status ([string]$runnerCliBundle.status) `
        -Message ([string]$runnerCliBundle.message)

    if ($runnerCliBundle.status -eq 'pass') {
        $repoContractStatus = @($repositoryResults | Where-Object { [string]$_.path -eq $iconEditorRepoPath } | Select-Object -First 1)
        if ($null -eq $repoContractStatus -or [string]$repoContractStatus.status -ne 'pass') {
            $blockingMessage = "Cannot run runner-cli PPL capability checks because icon-editor repo contract failed at '$iconEditorRepoPath'."
            foreach ($bitness in $requiredPplBitnesses) {
                $pplCapabilityChecks[$bitness].status = 'fail'
                $pplCapabilityChecks[$bitness].message = $blockingMessage
                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status 'fail' -Message $blockingMessage
            }
            $vipPackageBuildCheck.status = 'blocked'
            $vipPackageBuildCheck.message = 'VIP harness was not run because icon-editor repository contract failed.'
            Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
            $errors += $blockingMessage
        } else {
            $allPplPass = $true
            foreach ($bitness in $requiredPplBitnesses) {
                Write-InstallerFeedback -Message ("Running runner-cli PPL capability gate ({0}-bit)." -f $bitness)
                $capabilityResult = Invoke-RunnerCliPplCapabilityCheck `
                    -RunnerCliPath $runnerCliExePath `
                    -IconEditorRepoPath $iconEditorRepoPath `
                    -PinnedSha $iconEditorPinnedSha `
                    -ExecutionLabviewYear ([string]$requiredLabviewYear) `
                    -RunnerCliLabviewVersion ([string]$runnerCliLabviewVersion) `
                    -RequiredBitness $bitness `
                    -CommandTimeoutSeconds $RunnerCliCommandTimeoutSeconds

                $pplCapabilityChecks[$bitness] = [ordered]@{
                    status = [string]$capabilityResult.status
                    message = [string]$capabilityResult.message
                    runner_cli_path = [string]$capabilityResult.runner_cli_path
                    repo_path = [string]$capabilityResult.repo_path
                    required_labview_year = [string]$capabilityResult.required_labview_year
                    runner_cli_labview_version = [string]$capabilityResult.runner_cli_labview_version
                    required_bitness = [string]$capabilityResult.required_bitness
                    output_ppl_path = [string]$capabilityResult.output_ppl_path
                    output_ppl_snapshot_path = [string]$capabilityResult.output_ppl_snapshot_path
                    command = @($capabilityResult.command)
                    command_output = @($capabilityResult.command_output)
                    command_timeout_seconds = $capabilityResult.command_timeout_seconds
                    timed_out = [bool]$capabilityResult.timed_out
                    timeout_process_tree = $capabilityResult.timeout_process_tree
                    duration_seconds = $capabilityResult.duration_seconds
                    exit_code = $capabilityResult.exit_code
                    labview_install_root = [string]$capabilityResult.labview_install_root
                }

                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status ([string]$capabilityResult.status) -Message ([string]$capabilityResult.message)

                if ([string]$capabilityResult.status -ne 'pass') {
                    $allPplPass = $false
                    $errors += "Runner CLI PPL capability check failed ($bitness-bit). $([string]$capabilityResult.message)"
                }
            }

            if (-not $allPplPass) {
                $vipPackageBuildCheck.status = 'blocked'
                $vipPackageBuildCheck.message = 'VIP harness was not run because one or more PPL capability checks failed.'
                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
            } elseif ($skipVipHarness) {
                $vipPackageBuildCheck.status = 'skipped'
                $vipPackageBuildCheck.message = 'VIP harness was skipped by LVIE_SKIP_VIP_HARNESS.'
                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'skipped' -Message $vipPackageBuildCheck.message
                Write-InstallerFeedback -Message $vipPackageBuildCheck.message
            } else {
                Write-InstallerFeedback -Message 'Running runner-cli VI Package harness gate.'
                $vipResult = Invoke-RunnerCliVipPackageHarnessCheck `
                    -RunnerCliPath $runnerCliExePath `
                    -IconEditorRepoPath $iconEditorRepoPath `
                    -PinnedSha $iconEditorPinnedSha `
                    -ExecutionLabviewYear ([string]$requiredLabviewYear) `
                    -RunnerCliLabviewVersion ([string]$runnerCliLabviewVersion) `
                    -RequiredBitness ([string]$requiredVipBitness) `
                    -CommandTimeoutSeconds $RunnerCliCommandTimeoutSeconds

                $vipResultHasStatus = ($null -ne $vipResult) -and ($vipResult.PSObject.Properties.Name -contains 'status')
                if (-not $vipResultHasStatus) {
                    $vipResultType = if ($null -eq $vipResult) { 'null' } else { $vipResult.GetType().FullName }
                    $vipResultPreview = if ($null -eq $vipResult) {
                        ''
                    } else {
                        [string]::Join(' | ', @($vipResult | Select-Object -First 5 | ForEach-Object { [string]$_ }))
                    }
                    throw "VIP harness returned unexpected payload type '$vipResultType'. Preview: $vipResultPreview"
                }

                $vipPackageBuildCheck = [ordered]@{
                    status = [string]$vipResult.status
                    message = [string]$vipResult.message
                    runner_cli_path = [string]$vipResult.runner_cli_path
                    repo_path = [string]$vipResult.repo_path
                    required_labview_year = [string]$vipResult.required_labview_year
                    runner_cli_labview_version = [string]$vipResult.runner_cli_labview_version
                    vip_labview_version = [string]$vipResult.vip_labview_version
                    required_bitness = [string]$vipResult.required_bitness
                    vipb_path = [string]$vipResult.vipb_path
                    vipc_path = [string]$vipResult.vipc_path
                    vipc_assert_output_path = [string]$vipResult.vipc_assert_output_path
                    vip_build_status_path = [string]$vipResult.vip_build_status_path
                    release_notes_path = [string]$vipResult.release_notes_path
                    display_information_path = [string]$vipResult.display_information_path
                    output_vip_path = [string]$vipResult.output_vip_path
                    command = [ordered]@{
                        vipc_assert = @($vipResult.command.vipc_assert)
                        vipc_apply = @($vipResult.command.vipc_apply)
                        vip_build = @($vipResult.command.vip_build)
                    }
                    command_output = [ordered]@{
                        vipc_assert = @($vipResult.command_output.vipc_assert)
                        vipc_apply = @($vipResult.command_output.vipc_apply)
                        vip_build = @($vipResult.command_output.vip_build)
                    }
                    command_timeout_seconds = $vipResult.command_timeout_seconds
                    timed_out = [bool]$vipResult.timed_out
                    timeout_process_tree = $vipResult.timeout_process_tree
                    duration_seconds = $vipResult.duration_seconds
                    exit_code = $vipResult.exit_code
                    labview_install_root = [string]$vipResult.labview_install_root
                }
                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status ([string]$vipResult.status) -Message ([string]$vipResult.message)

                if ($vipPackageBuildCheck.status -ne 'pass') {
                    $errors += "Runner CLI VIP harness check failed. $($vipPackageBuildCheck.message)"
                }
            }
        }
    } else {
        $bundleBlockingMessage = "Runner CLI bundle verification failed; capability gates were not run. $([string]$runnerCliBundle.message)"
        foreach ($bitness in $requiredPplBitnesses) {
            $pplCapabilityChecks[$bitness].status = 'blocked'
            $pplCapabilityChecks[$bitness].message = $bundleBlockingMessage
            Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status 'blocked' -Message $bundleBlockingMessage
        }
        $vipPackageBuildCheck.status = 'blocked'
        $vipPackageBuildCheck.message = 'VIP harness was not run because runner-cli bundle verification failed.'
        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
    }

    $assertScriptPath = Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1'
    $workspaceManifestPath = Join-Path $resolvedWorkspaceRoot 'workspace-governance.json'
    $auditOutputPath = [string]$governanceAudit.report_path

    if ((Test-Path -LiteralPath $assertScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $workspaceManifestPath -PathType Leaf)) {
        Write-InstallerFeedback -Message 'Running workspace governance audit.'
        $governanceAudit.invoked = $true
        $auditInvocation = Invoke-PowerShellFileWithTimeout `
            -FilePath $assertScriptPath `
            -Arguments @(
                '-WorkspaceRoot', $resolvedWorkspaceRoot,
                '-ManifestPath', $workspaceManifestPath,
                '-Mode', 'Audit',
                '-OutputPath', $auditOutputPath
            ) `
            -TimeoutSeconds $GovernanceAuditTimeoutSeconds
        $governanceAudit.exit_code = $auditInvocation.exit_code
        $governanceAudit.command_output = @($auditInvocation.output)
        $governanceAudit.timed_out = [bool]$auditInvocation.timed_out
        $governanceAudit.timeout_process_tree = $auditInvocation.timeout_process_tree
        $governanceAudit.duration_seconds = [double]$auditInvocation.duration_seconds

        if ($governanceAudit.timed_out) {
            $governanceAudit.status = 'fail'
            $governanceAudit.message = "Governance audit timed out after $GovernanceAuditTimeoutSeconds seconds."
            $errors += $governanceAudit.message
        } elseif (Test-Path -LiteralPath $auditOutputPath -PathType Leaf) {
            $auditReport = Get-Content -LiteralPath $auditOutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $failingRepos = @($auditReport.repositories | Where-Object { $_.status -eq 'fail' })
            $nonBranchFailures = @()
            $branchFailures = @()

            foreach ($failingRepo in $failingRepos) {
                $issues = @($failingRepo.issues)
                $hasNonBranchIssue = $false
                foreach ($issue in $issues) {
                    $issueValue = [string]$issue
                    if ($issueValue.StartsWith('branch_protection_')) {
                        continue
                    }
                    $hasNonBranchIssue = $true
                }

                if ($hasNonBranchIssue) {
                    $nonBranchFailures += [string]$failingRepo.path
                } else {
                    $branchFailures += [string]$failingRepo.path
                }
            }

            $governanceAudit.branch_failures = $branchFailures
            $governanceAudit.non_branch_failures = $nonBranchFailures

            if ($governanceAudit.exit_code -eq 0) {
                $governanceAudit.status = 'pass'
                $governanceAudit.message = 'Workspace governance audit passed.'
            } elseif ($nonBranchFailures.Count -eq 0 -and $branchFailures.Count -gt 0) {
                $governanceAudit.status = 'branch_only_fail'
                $governanceAudit.branch_only_failure = $true
                $governanceAudit.message = 'Workspace governance audit has branch-protection-only failures.'
                $warnings += 'Branch protection contract is not fully satisfied; install continues in audit-only mode.'
            } else {
                $governanceAudit.status = 'fail'
                $governanceAudit.message = 'Workspace governance audit failed with non-branch-protection issues.'
                $errors += $governanceAudit.message
            }
        } else {
            $governanceAudit.status = 'fail'
            $governanceAudit.message = "Governance audit report missing: $auditOutputPath"
            $errors += $governanceAudit.message
        }
    } else {
        $governanceAudit.status = 'fail'
        $governanceAudit.message = 'Governance audit prerequisites are missing (assert script or manifest).'
        $errors += $governanceAudit.message
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'governance-audit' `
        -Status ([string]$governanceAudit.status) `
        -Message ([string]$governanceAudit.message)
} catch {
    $errors += $_.Exception.Message
    Write-InstallerFeedback -Message ("Unhandled installer exception: {0}" -f $_.Exception.Message)
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
Write-InstallerFeedback -Message ("Completed with status: {0}" -f $status)
$errorTaxonomy = Get-ErrorTaxonomy -Errors $errors -Warnings $warnings
$phaseMetrics = Get-PhaseMetrics -Sequence $postActionSequence
$phaseSummaryPath = Join-Path (Split-Path -Parent $resolvedOutputPath) 'workspace-installer-phase-summary.json'
$phaseSummary = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    mode = $Mode
    execution_context = $InstallExecutionContext
    phase_metrics = $phaseMetrics
    post_action_sequence = $postActionSequence
}
$phaseSummary | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $phaseSummaryPath -Encoding UTF8

$artifactIndex = Get-InstallerArtifactIndex `
    -WorkspaceRootPath $resolvedWorkspaceRoot `
    -OutputReportPath $resolvedOutputPath `
    -GovernanceReportPath ([string]$governanceAudit.report_path) `
    -RunnerTemp ([string]$env:RUNNER_TEMP)

$firstFailingPhaseEntry = @(
    $postActionSequence |
        Where-Object { [string]$_.status -in @('fail', 'failed', 'blocked') } |
        Select-Object -First 1
)
$failureFingerprintInput = [ordered]@{
    status = $status
    mode = $Mode
    install_execution_context = $InstallExecutionContext
    first_error = if (@($errors).Count -gt 0) { [string]$errors[0] } else { '' }
    first_failing_phase = if (@($firstFailingPhaseEntry).Count -gt 0) { [string]$firstFailingPhaseEntry[0].phase } else { '' }
    taxonomy = @($errorTaxonomy)
}
$failureFingerprintCanonical = $failureFingerprintInput | ConvertTo-Json -Depth 8 -Compress
$failureFingerprint = [ordered]@{
    hash = if ($status -eq 'succeeded') { '' } else { Convert-ToStableSha256 -Value $failureFingerprintCanonical }
    canonical_input = $failureFingerprintInput
}

$developerFeedback = Get-DeveloperFeedback `
    -Status $status `
    -Errors $errors `
    -Warnings $warnings `
    -Taxonomy $errorTaxonomy `
    -ArtifactIndex $artifactIndex `
    -PostActionSequence $postActionSequence

$commandDiagnostics = [ordered]@{
    ppl_build = [ordered]@{
        timeout_seconds = $RunnerCliCommandTimeoutSeconds
        x32 = [ordered]@{
            status = [string]$pplCapabilityChecks.'32'.status
            exit_code = $pplCapabilityChecks.'32'.exit_code
            timed_out = [bool]$pplCapabilityChecks.'32'.timed_out
            duration_seconds = $pplCapabilityChecks.'32'.duration_seconds
            output_preview = [string]::Join(' | ', @($pplCapabilityChecks.'32'.command_output | Select-Object -First 10))
        }
        x64 = [ordered]@{
            status = [string]$pplCapabilityChecks.'64'.status
            exit_code = $pplCapabilityChecks.'64'.exit_code
            timed_out = [bool]$pplCapabilityChecks.'64'.timed_out
            duration_seconds = $pplCapabilityChecks.'64'.duration_seconds
            output_preview = [string]::Join(' | ', @($pplCapabilityChecks.'64'.command_output | Select-Object -First 10))
        }
    }
    vip_harness = [ordered]@{
        timeout_seconds = $RunnerCliCommandTimeoutSeconds
        status = [string]$vipPackageBuildCheck.status
        exit_code = $vipPackageBuildCheck.exit_code
        timed_out = [bool]$vipPackageBuildCheck.timed_out
        duration_seconds = $vipPackageBuildCheck.duration_seconds
        output_preview = [ordered]@{
            vipc_assert = [string]::Join(' | ', @($vipPackageBuildCheck.command_output.vipc_assert | Select-Object -First 10))
            vipc_apply = [string]::Join(' | ', @($vipPackageBuildCheck.command_output.vipc_apply | Select-Object -First 10))
            vip_build = [string]::Join(' | ', @($vipPackageBuildCheck.command_output.vip_build | Select-Object -First 10))
        }
    }
    governance_audit = [ordered]@{
        timeout_seconds = $GovernanceAuditTimeoutSeconds
        status = [string]$governanceAudit.status
        exit_code = $governanceAudit.exit_code
        timed_out = [bool]$governanceAudit.timed_out
        duration_seconds = $governanceAudit.duration_seconds
        output_preview = [string]::Join(' | ', @($governanceAudit.command_output | Select-Object -First 10))
    }
}

$diagnostics = [ordered]@{
    schema_version = '1.0'
    platform = [ordered]@{
        name = Get-PlatformName
        os_description = [string][System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        os_architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        process_architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        powershell_edition = [string]$PSVersionTable.PSEdition
        powershell_version = [string]$PSVersionTable.PSVersion
    }
    execution_context = [ordered]@{
        mode = $Mode
        install_execution_context = $InstallExecutionContext
        is_container_execution = [bool]$labviewVersionResolution.is_container_execution
        workspace_root = $resolvedWorkspaceRoot
        output_path = $resolvedOutputPath
        runner_temp = [string]$env:RUNNER_TEMP
    }
    phase_metrics = $phaseMetrics
    command_diagnostics = $commandDiagnostics
    artifact_index = $artifactIndex
    failure_fingerprint = $failureFingerprint
    developer_feedback = $developerFeedback
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    mode = $Mode
    execution_context = $InstallExecutionContext
    workspace_root = $resolvedWorkspaceRoot
    manifest_path = $resolvedManifestPath
    output_path = $resolvedOutputPath
    dependency_checks = $dependencyChecks
    payload_sync = $payloadSync
    repositories = $repositoryResults
    runner_cli_bundle = $runnerCliBundle
    labview_version_resolution = $labviewVersionResolution
    ppl_capability_checks = $pplCapabilityChecks
    vip_package_build_check = $vipPackageBuildCheck
    post_action_sequence = $postActionSequence
    governance_audit = $governanceAudit
    diagnostics = $diagnostics
    warnings = $warnings
    errors = $errors
}

$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace install report: $resolvedOutputPath"

if ($status -ne 'succeeded') {
    exit 1
}

exit 0
