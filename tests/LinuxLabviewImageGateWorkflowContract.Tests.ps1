#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Linux LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/linux-labview-image-gate.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Linux image gate workflow missing: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is manual-dispatch only' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'labview_linux_image:'
        $script:workflowContent | Should -Match 'default:\s*nationalinstruments/labview:[0-9]{4}q[0-9]+-linux'
        $script:workflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*pull_request:'
    }

    It 'uses a single LabVIEW linux image and desktop-linux docker context' {
        $script:workflowContent | Should -Match 'LABVIEW_LINUX_IMAGE:\s*\$\{\{\s*inputs\.labview_linux_image\s*\}\}'
        $script:workflowContent | Should -Match 'Invoke-DockerDesktopLinuxIteration\.ps1'
        $script:workflowContent | Should -Match '-Image \$env:LABVIEW_LINUX_IMAGE'
        $script:workflowContent | Should -Match "-DockerContext 'desktop-linux'"
        $script:workflowContent | Should -Match '-SkipPester'
    }

    It 'uploads linux image gate artifacts for diagnostics' {
        $script:workflowContent | Should -Match 'upload-artifact'
        $script:workflowContent | Should -Match 'docker-linux-iteration-report\.json'
        $script:workflowContent | Should -Match 'linux-labview-image-gate-\$\{\{\s*github\.run_id\s*\}\}'
    }
}
