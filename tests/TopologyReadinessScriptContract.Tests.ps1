#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Topology readiness script contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Assert-TopologyReadiness.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Topology script missing: $script:scriptPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'compares upstream and fork branch topology using GitHub compare API' {
        $script:scriptContent | Should -Match 'repos/\{0\}/compare/\{1\}'
        $script:scriptContent | Should -Match '\{0\}\.\.\.\{1\}:\{0\}'
        $script:scriptContent | Should -Match 'ahead_by'
        $script:scriptContent | Should -Match 'behind_by'
    }

    It 'fails closed when required not-behind contract is violated' {
        $script:scriptContent | Should -Match 'RequireNotBehind'
        $script:scriptContent | Should -Match 'classification = if \(\$RequireNotBehind\) \{ ''require_not_behind'' \} else \{ ''audit_only'' \}'
        $script:scriptContent | Should -Match 'topology_not_ready'
    }

    It 'emits deterministic report fields for gating evidence' {
        $script:scriptContent | Should -Match 'timestamp_utc'
        $script:scriptContent | Should -Match 'fork_repository'
        $script:scriptContent | Should -Match 'upstream_repository'
        $script:scriptContent | Should -Match 'require_not_behind'
        $script:scriptContent | Should -Match 'pass = \$pass'
    }
}
