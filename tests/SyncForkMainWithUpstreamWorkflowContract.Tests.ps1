#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Sync fork main with upstream workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/sync-fork-main-with-upstream.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is schedule and dispatch driven with write permissions for PR sync automation' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'contents:\s*write'
        $script:workflowContent | Should -Match 'pull-requests:\s*write'
    }

    It 'runs only in fork repo and computes topology via compare API' {
        $script:workflowContent | Should -Match "github\.repository == 'svelderrainruiz/labview-cdev-surface'"
        $script:workflowContent | Should -Match 'compare/main\.\.\.svelderrainruiz:main'
        $script:workflowContent | Should -Match 'behind_by'
        $script:workflowContent | Should -Match 'sync/fork-main-with-upstream-'
    }

    It 'uses no-force merge and PR flow to sync fork main' {
        $script:workflowContent | Should -Match 'git merge --no-ff --no-edit upstream/main'
        $script:workflowContent | Should -Match 'git push --set-upstream origin'
        $script:workflowContent | Should -Match 'gh pr create'
        $script:workflowContent | Should -Match '--base main'
    }
}
