#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'CI workflow reliability contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ci.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "CI workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'defines workflow-level concurrency dedupe by workflow and ref identity' {
        $script:workflowContent | Should -Match 'concurrency:'
        $script:workflowContent | Should -Match 'group:\s*ci-pipeline-\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.event\.pull_request\.head\.repo\.full_name\s*\|\|\s*github\.repository\s*\}\}-\$\{\{\s*github\.event\.pull_request\.head\.ref\s*\|\|\s*github\.ref_name\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*true'
    }

    It 'fails closed on pin-change PRs when fork topology is behind upstream' {
        $script:workflowContent | Should -Match 'id:\s*topology_scope'
        $script:workflowContent | Should -Match 'id:\s*topology_readiness'
        $script:workflowContent | Should -Match 'Assert-TopologyReadiness\.ps1'
        $script:workflowContent | Should -Match 'steps\.topology_scope\.outputs\.require_not_behind'
        $script:workflowContent | Should -Match 'topology_readiness_failed'
        $script:workflowContent | Should -Match 'topology-readiness-\$\{\{\s*github\.run_id\s*\}\}'
    }

    It 'uses reusable upload-artifact retry composite for workspace installer artifacts' {
        $script:workflowContent | Should -Match 'id:\s*upload-workspace-installer-artifact'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/actions/upload-artifact-retry'
        $script:workflowContent | Should -Match 'artifact_name:\s*workspace-bootstrap-installer-\$\{\{\s*github\.run_id\s*\}\}'
    }

    It 'uses reusable upload-artifact retry composite for reproducibility artifacts' {
        $script:workflowContent | Should -Match 'id:\s*upload-reproducibility-artifacts'
        $script:workflowContent | Should -Match 'artifact_name:\s*reproducibility-contract-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'artifact_path:\s*\$\{\{\s*runner\.temp\s*\}\}/reproducibility'
    }

    It 'uses reusable upload-artifact retry composite for provenance artifacts' {
        $script:workflowContent | Should -Match 'id:\s*upload-provenance-artifacts'
        $script:workflowContent | Should -Match 'artifact_name:\s*provenance-contract-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'artifact_path:\s*\$\{\{\s*runner\.temp\s*\}\}/provenance'
    }
}
