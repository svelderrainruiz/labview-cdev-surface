#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer hang recovery contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:exerciseScriptPath = Join-Path $script:repoRoot 'scripts/Exercise-WorkspaceInstallerLocal.ps1'
        $script:installScriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'

        foreach ($path in @($script:exerciseScriptPath, $script:installScriptPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required hang recovery script missing: $path"
            }
        }

        $script:exerciseContent = Get-Content -LiteralPath $script:exerciseScriptPath -Raw
        $script:installContent = Get-Content -LiteralPath $script:installScriptPath -Raw
    }

    It 'captures smoke timeout diagnostics with process-tree context' {
        $script:exerciseContent | Should -Match 'SmokeInstallerTimeoutSeconds'
        $script:exerciseContent | Should -Match 'Write-SmokeTimeoutDiagnostics'
        $script:exerciseContent | Should -Match 'child_processes'
        $script:exerciseContent | Should -Match 'Smoke installer timed out'
    }

    It 'enforces deterministic runner-cli and governance timeout controls' {
        $script:installContent | Should -Match '\[int\]\$RunnerCliCommandTimeoutSeconds = 1800'
        $script:installContent | Should -Match '\[int\]\$GovernanceAuditTimeoutSeconds = 300'
        $script:installContent | Should -Match 'Invoke-ExecutableWithTimeout'
        $script:installContent | Should -Match 'command_timeout_seconds'
        $script:installContent | Should -Match 'timeout_process_tree'
        $script:installContent | Should -Match 'Governance audit timed out after'
    }

    It 'has parse-safe PowerShell syntax' {
        foreach ($content in @($script:exerciseContent, $script:installContent)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
}
