#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Cancel stale workflow runs contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:path = Join-Path $script:repoRoot 'scripts/Cancel-StaleWorkflowRuns.ps1'
        if (-not (Test-Path -LiteralPath $script:path -PathType Leaf)) {
            throw "Script missing: $script:path"
        }
        $script:content = Get-Content -LiteralPath $script:path -Raw
    }

    It 'cancels only active stale runs' {
        $script:content | Should -Match "'queued', 'in_progress', 'requested', 'waiting', 'pending'"
        $script:content | Should -Match "'run', 'cancel'"
    }

    It 'supports keeping the latest runs and target head sha filtering' {
        $script:content | Should -Match 'keep_latest_n'
        $script:content | Should -Match 'target_head_sha'
        $script:content | Should -Match 'target_head_sha'
    }
}
