#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer KPI workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:kpiWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-installer-kpi-signal.yml'
        $script:debtWorkflowPath = Join-Path $script:repoRoot '.github/workflows/governance-debt-signal.yml'

        foreach ($path in @($script:kpiWorkflowPath, $script:debtWorkflowPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required workflow missing: $path"
            }
        }

        $script:kpiWorkflowContent = Get-Content -LiteralPath $script:kpiWorkflowPath -Raw
        $script:debtWorkflowContent = Get-Content -LiteralPath $script:debtWorkflowPath -Raw
    }

    It 'defines scheduled and dispatch KPI signal workflow with self-hosted runner labels' {
        $script:kpiWorkflowContent | Should -Match 'schedule:'
        $script:kpiWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:kpiWorkflowContent | Should -Match 'self-hosted'
        $script:kpiWorkflowContent | Should -Match 'installer-harness'
        $script:kpiWorkflowContent | Should -Match 'issues:\s*write'
    }

    It 'runs collect, measure, assert, and publish KPI scripts in signal workflow' {
        $script:kpiWorkflowContent | Should -Match 'Collect-WorkspaceInstallerDiagnostics\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Measure-WorkspaceInstallerKpis\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Assert-WorkspaceInstallerKpis\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Publish-WorkspaceInstallerKpiSummary\.ps1'
        $script:kpiWorkflowContent | Should -Match 'workspace-installer-kpi-latest\.json'
        $script:kpiWorkflowContent | Should -Match 'workspace-installer-kpi-assertion-latest\.json'
    }

    It 'uses WORKFLOW_BOT_TOKEN fallback token strategy in KPI publish path' {
        $script:kpiWorkflowContent | Should -Match 'GH_TOKEN:\s*\${{\s*secrets\.WORKFLOW_BOT_TOKEN != '''' && secrets\.WORKFLOW_BOT_TOKEN \|\| github\.token\s*}}'
    }

    It 'defines governance debt signal workflow with workspace audit and issue upsert' {
        $script:debtWorkflowContent | Should -Match 'name:\s*Governance Debt Signal'
        $script:debtWorkflowContent | Should -Match 'workspace-preflight-audit\.json'
        $script:debtWorkflowContent | Should -Match 'Invoke-WorkspacePreflight\.ps1'
        $script:debtWorkflowContent | Should -Match 'Workspace Governance Debt'
        $script:debtWorkflowContent | Should -Match 'gh issue'
    }
}
