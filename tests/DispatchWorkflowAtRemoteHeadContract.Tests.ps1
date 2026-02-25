#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Dispatch workflow at remote head contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Dispatch-WorkflowAtRemoteHead.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Dispatch helper script not found: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'enforces ordered push then remote SHA verification before dispatch' {
        $script:scriptContent | Should -Match "git push"
        $script:scriptContent | Should -Match "ls-remote"
        $script:scriptContent | Should -Match "remote_head_mismatch"
        $script:scriptContent | Should -Match "workflow run"
        $script:scriptContent | Should -Match "run list"
        $script:scriptContent | Should -Match "headSha"
    }

    It 'supports deterministic run lookup and structured reporting' {
        $script:scriptContent | Should -Match "RunSearchAttempts"
        $script:scriptContent | Should -Match "RunSearchPollSeconds"
        $script:scriptContent | Should -Match "matched_run"
        $script:scriptContent | Should -Match "OutputPath"
        $script:scriptContent | Should -Match "ConvertTo-Json"
    }

    It 'is parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
