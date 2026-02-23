#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer developer experience diagnostics contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:exerciseScriptPath = Join-Path $script:repoRoot 'scripts/Exercise-WorkspaceInstallerLocal.ps1'
        $script:installScriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        $script:iterationScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-WorkspaceInstallerIteration.ps1'

        foreach ($path in @($script:exerciseScriptPath, $script:installScriptPath, $script:iterationScriptPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required diagnostics contract script missing: $path"
            }
        }

        $script:exerciseContent = Get-Content -LiteralPath $script:exerciseScriptPath -Raw
        $script:installContent = Get-Content -LiteralPath $script:installScriptPath -Raw
        $script:iterationContent = Get-Content -LiteralPath $script:iterationScriptPath -Raw
    }

    It 'defines explicit smoke timeout KPI controls' {
        $script:exerciseContent | Should -Match '\[ValidateRange\(60, 7200\)\]'
        $script:exerciseContent | Should -Match '\[int\]\$SmokeInstallerTimeoutSeconds = 1800'
    }

    It 'emits first-class smoke launch diagnostics artifact with lifecycle feedback' {
        $script:exerciseContent | Should -Match 'workspace-installer-launch\.log'
        $script:exerciseContent | Should -Match 'workspace-installer-exec\.log'
        $script:exerciseContent | Should -Match 'Write-SmokeLaunchLog'
        $script:exerciseContent | Should -Match 'Smoke installer process started'
        $script:exerciseContent | Should -Match 'Smoke installer process exited'
    }

    It 'captures timeout diagnostics with process-tree context for triage' {
        $script:exerciseContent | Should -Match 'Write-SmokeTimeoutDiagnostics'
        $script:exerciseContent | Should -Match 'smoke-installer-timeout-diagnostics\.json'
        $script:exerciseContent | Should -Match 'child_processes'
        $script:exerciseContent | Should -Match 'smoke_report_summary'
    }

    It 'surfaces actionable failure feedback pointers in smoke errors' {
        $script:exerciseContent | Should -Match 'Launch log:'
        $script:exerciseContent | Should -Match 'Diagnostics:'
        $script:exerciseContent | Should -Match 'Get-SmokeFailureSummary'
    }

    It 'promotes smoke failure KPIs into iteration-level failure summaries' {
        $script:iterationContent | Should -Match 'Get-SmokeReportFailureSummary'
        $script:iterationContent | Should -Match 'smoke_report='
        $script:iterationContent | Should -Match 'top_error='
    }

    It 'records structured VIP command outputs for developer diagnostics' {
        $script:installContent | Should -Match 'command_output = \[ordered\]@\{'
        $script:installContent | Should -Match 'vipc_assert = @\(\)'
        $script:installContent | Should -Match 'vipc_apply = @\(\)'
        $script:installContent | Should -Match 'vip_build = @\(\)'
        $script:installContent | Should -Match 'Output: \$buildSummary'
    }

    It 'enforces VIP result shape validation for deterministic feedback' {
        $script:installContent | Should -Match 'VIP harness returned unexpected payload type'
        $script:installContent | Should -Match 'Preview: \$vipResultPreview'
    }

    It 'emits top-level unhandled installer feedback for faster diagnosis' {
        $script:installContent | Should -Match 'Unhandled installer exception:'
    }

    It 'emits diagnostics and feedback schema sections for one-pass triage' {
        $script:installContent | Should -Match 'diagnostics = \[ordered\]@\{'
        $script:installContent | Should -Match 'schema_version = ''1\.0'''
        $script:installContent | Should -Match 'phase_metrics = \$phaseMetrics'
        $script:installContent | Should -Match 'command_diagnostics = \$commandDiagnostics'
        $script:installContent | Should -Match 'failure_fingerprint = \$failureFingerprint'
        $script:installContent | Should -Match 'developer_feedback = \$developerFeedback'
    }

    It 'uses round-trip safe timestamp parsing for phase metrics' {
        $script:installContent | Should -Match 'function Convert-ToUtcTimestamp'
        $script:installContent | Should -Match 'DateTimeOffset\]::Parse'
        $script:installContent | Should -Match 'Convert-ToUtcTimestamp -Value'
        $script:installContent | Should -Not -Match '\[DateTime\]::TryParse'
    }

    It 'captures command timeout diagnostics for runner-cli and governance phases' {
        $script:installContent | Should -Match 'Invoke-ExecutableWithTimeout'
        $script:installContent | Should -Match 'Invoke-PowerShellFileWithTimeout'
        $script:installContent | Should -Match 'command_timeout_seconds'
        $script:installContent | Should -Match 'timed_out'
        $script:installContent | Should -Match 'timeout_process_tree'
    }

    It 'has parse-safe PowerShell syntax in diagnostics scripts' {
        foreach ($content in @($script:exerciseContent, $script:installContent, $script:iterationContent)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
}
