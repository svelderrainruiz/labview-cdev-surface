#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Windows image gate workflow missing: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is manual-dispatch only for phase-1 rollout' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*pull_request:'
    }

    It 'targets windows containers with installer-post-action report checks' {
        $script:workflowContent | Should -Match 'LABVIEW_WINDOWS_IMAGE:\s*nationalinstruments/labview@sha256:[0-9a-f]{64}'
        $script:workflowContent | Should -Match 'docker pull \$env:LABVIEW_WINDOWS_IMAGE'
        $script:workflowContent | Should -Match '--dns 8\.8\.8\.8'
        $script:workflowContent | Should -Match '--dns 1\.1\.1\.1'
        $script:workflowContent | Should -Match 'git config --global --add safe\.directory ''\*'''
        $script:workflowContent | Should -Match 'DockerCli\.exe.*-SwitchWindowsEngine'
        $script:workflowContent | Should -Match 'Install-WorkspaceFromManifest\.ps1'
        $script:workflowContent | Should -Match "required_year = '2026'"
        $script:workflowContent | Should -Match "required_ppl_bitnesses = @\('64'\)"
        $script:workflowContent | Should -Match 'workspace-install-latest\.json'
        $script:workflowContent | Should -Match 'No PPL capability checks executed'
        $script:workflowContent | Should -Match 'ppl_statuses = \$pplStatuses'
        $script:workflowContent | Should -Match 'vip_package_build_check\.status'
    }

    It 'publishes gate artifacts for troubleshooting' {
        $script:workflowContent | Should -Match 'upload-artifact'
        $script:workflowContent | Should -Match 'if-no-files-found:'
    }
}
