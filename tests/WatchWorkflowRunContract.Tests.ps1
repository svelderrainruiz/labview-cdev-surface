#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Watch workflow run contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:path = Join-Path $script:repoRoot 'scripts/Watch-WorkflowRun.ps1'
        if (-not (Test-Path -LiteralPath $script:path -PathType Leaf)) {
            throw "Script missing: $script:path"
        }
        $script:content = Get-Content -LiteralPath $script:path -Raw
    }

    It 'classifies timeout and non-success conclusions deterministically' {
        $script:content | Should -Match 'workflow_watch_timeout'
        $script:content | Should -Match 'workflow_run_failed'
        $script:content | Should -Match 'classified_reason'
    }
}
