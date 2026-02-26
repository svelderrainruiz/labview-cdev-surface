#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Portable ops runtime contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:dockerfile = Join-Path $script:repoRoot 'tools/ops-runtime/Dockerfile'
        $script:wrapper = Join-Path $script:repoRoot 'scripts/Invoke-PortableOps.ps1'
        if (-not (Test-Path -LiteralPath $script:dockerfile -PathType Leaf)) {
            throw "Dockerfile missing: $script:dockerfile"
        }
        if (-not (Test-Path -LiteralPath $script:wrapper -PathType Leaf)) {
            throw "Wrapper missing: $script:wrapper"
        }
        $script:dockerContent = Get-Content -LiteralPath $script:dockerfile -Raw
        $script:wrapperContent = Get-Content -LiteralPath $script:wrapper -Raw
    }

    It 'pins a PowerShell-based container runtime with git gh jq' {
        $script:dockerContent | Should -Match 'mcr\.microsoft\.com/powershell'
        $script:dockerContent | Should -Match 'git jq gh'
    }

    It 'mounts workspace and forwards GH_TOKEN to containerized ops scripts' {
        $script:wrapperContent | Should -Match "'-v'"
        $script:wrapperContent | Should -Match '/workspace'
        $script:wrapperContent | Should -Match 'GH_TOKEN='
        $script:wrapperContent | Should -Match 'docker_not_ready'
    }
}
