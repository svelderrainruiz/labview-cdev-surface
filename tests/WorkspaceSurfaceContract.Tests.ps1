#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace surface contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:manifestPath = Join-Path $script:repoRoot 'workspace-governance.json'
        $script:agentsPath = Join-Path $script:repoRoot 'AGENTS.md'
        $script:readmePath = Join-Path $script:repoRoot 'README.md'
        $script:assertScriptPath = Join-Path $script:repoRoot 'scripts/Assert-WorkspaceGovernance.ps1'
        $script:policyScriptPath = Join-Path $script:repoRoot 'scripts/Test-PolicyContracts.ps1'
        $script:driftScriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceManifestBranchDrift.ps1'
        $script:pinRefreshScriptPath = Join-Path $script:repoRoot 'scripts/Update-WorkspaceManifestPins.ps1'
        $script:installScriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        $script:buildInstallerScriptPath = Join-Path $script:repoRoot 'scripts/Build-WorkspaceBootstrapInstaller.ps1'
        $script:bundleRunnerCliScriptPath = Join-Path $script:repoRoot 'scripts/Build-RunnerCliBundleFromManifest.ps1'
        $script:runnerCliDeterminismScriptPath = Join-Path $script:repoRoot 'scripts/Test-RunnerCliBundleDeterminism.ps1'
        $script:installerDeterminismScriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceInstallerDeterminism.ps1'
        $script:writeProvenanceScriptPath = Join-Path $script:repoRoot 'scripts/Write-ReleaseProvenance.ps1'
        $script:testProvenanceScriptPath = Join-Path $script:repoRoot 'scripts/Test-ProvenanceContracts.ps1'
        $script:dockerLinuxIterationScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-DockerDesktopLinuxIteration.ps1'
        $script:collectDiagnosticsScriptPath = Join-Path $script:repoRoot 'scripts/Collect-WorkspaceInstallerDiagnostics.ps1'
        $script:measureKpisScriptPath = Join-Path $script:repoRoot 'scripts/Measure-WorkspaceInstallerKpis.ps1'
        $script:assertKpisScriptPath = Join-Path $script:repoRoot 'scripts/Assert-WorkspaceInstallerKpis.ps1'
        $script:publishKpiSummaryScriptPath = Join-Path $script:repoRoot 'scripts/Publish-WorkspaceInstallerKpiSummary.ps1'
        $script:diagnosticsSchemaPath = Join-Path $script:repoRoot 'schemas/workspace-installer-diagnostics.schema.json'
        $script:kpiConfigPath = Join-Path $script:repoRoot 'diagnostics-kpi.json'
        $script:nsisInstallerPath = Join-Path $script:repoRoot 'nsis/workspace-bootstrap-installer.nsi'
        $script:ciWorkflowPath = Join-Path $script:repoRoot '.github/workflows/ci.yml'
        $script:driftWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-drift-signal.yml'
        $script:shaRefreshWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-refresh-pr.yml'
        $script:releaseWorkflowPath = Join-Path $script:repoRoot '.github/workflows/release-workspace-installer.yml'
        $script:canaryWorkflowPath = Join-Path $script:repoRoot '.github/workflows/nightly-supplychain-canary.yml'
        $script:windowsImageGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        $script:linuxImageGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/linux-labview-image-gate.yml'
        $script:installerHarnessWorkflowPath = Join-Path $script:repoRoot '.github/workflows/installer-harness-self-hosted.yml'
        $script:kpiSignalWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-installer-kpi-signal.yml'
        $script:governanceDebtWorkflowPath = Join-Path $script:repoRoot '.github/workflows/governance-debt-signal.yml'
        $script:globalJsonPath = Join-Path $script:repoRoot 'global.json'
        $script:payloadAgentsPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/AGENTS.md'
        $script:payloadManifestPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/workspace-governance.json'
        $script:payloadAssertScriptPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/scripts/Assert-WorkspaceGovernance.ps1'
        $script:payloadPolicyScriptPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/scripts/Test-PolicyContracts.ps1'
        $script:payloadKpiConfigPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/diagnostics-kpi.json'

        $requiredPaths = @(
            $script:manifestPath,
            $script:agentsPath,
            $script:readmePath,
            $script:assertScriptPath,
            $script:policyScriptPath,
            $script:driftScriptPath,
            $script:pinRefreshScriptPath,
            $script:installScriptPath,
            $script:buildInstallerScriptPath,
            $script:bundleRunnerCliScriptPath,
            $script:runnerCliDeterminismScriptPath,
            $script:installerDeterminismScriptPath,
            $script:writeProvenanceScriptPath,
            $script:testProvenanceScriptPath,
            $script:dockerLinuxIterationScriptPath,
            $script:collectDiagnosticsScriptPath,
            $script:measureKpisScriptPath,
            $script:assertKpisScriptPath,
            $script:publishKpiSummaryScriptPath,
            $script:diagnosticsSchemaPath,
            $script:kpiConfigPath,
            $script:nsisInstallerPath,
            $script:ciWorkflowPath,
            $script:driftWorkflowPath,
            $script:shaRefreshWorkflowPath,
            $script:releaseWorkflowPath,
            $script:canaryWorkflowPath,
            $script:windowsImageGateWorkflowPath,
            $script:linuxImageGateWorkflowPath,
            $script:installerHarnessWorkflowPath,
            $script:kpiSignalWorkflowPath,
            $script:governanceDebtWorkflowPath,
            $script:globalJsonPath,
            $script:payloadAgentsPath,
            $script:payloadManifestPath,
            $script:payloadAssertScriptPath,
            $script:payloadPolicyScriptPath,
            $script:payloadKpiConfigPath
        )

        foreach ($path in $requiredPaths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required workspace-surface contract file missing: $path"
            }
        }

        $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:payloadManifest = Get-Content -LiteralPath $script:payloadManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:agentsContent = Get-Content -LiteralPath $script:agentsPath -Raw
        $script:readmeContent = Get-Content -LiteralPath $script:readmePath -Raw
        $script:ciWorkflowContent = Get-Content -LiteralPath $script:ciWorkflowPath -Raw
        $script:releaseWorkflowContent = Get-Content -LiteralPath $script:releaseWorkflowPath -Raw
        $script:installerHarnessWorkflowContent = Get-Content -LiteralPath $script:installerHarnessWorkflowPath -Raw
        $script:kpiWorkflowContent = Get-Content -LiteralPath $script:kpiSignalWorkflowPath -Raw
    }

    It 'tracks a deterministic managed repo set with pinned SHA lock' {
        @($script:manifest.managed_repos).Count | Should -BeGreaterOrEqual 9
        $script:manifest.PSObject.Properties.Name | Should -Contain 'installer_contract'
        $script:manifest.installer_contract.runner_cli_bundle.executable | Should -Be 'runner-cli.exe'
        $script:manifest.installer_contract.labview_gate.required_year | Should -Be '2020'
        ((@($script:manifest.installer_contract.labview_gate.required_ppl_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.labview_gate.required_vip_bitness | Should -Be '64'
        $script:manifest.installer_contract.ppl_capability_proof.command | Should -Be 'runner-cli ppl build'
        ((@($script:manifest.installer_contract.ppl_capability_proof.supported_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.vip_capability_proof.command | Should -Be 'runner-cli vip build'
        $script:manifest.installer_contract.vip_capability_proof.labview_version | Should -Be '2020'
        $script:manifest.installer_contract.vip_capability_proof.supported_bitness | Should -Be '64'
        $script:manifest.installer_contract.reproducibility.required | Should -BeTrue
        $script:manifest.installer_contract.reproducibility.strict_hash_match | Should -BeTrue
        $script:manifest.installer_contract.provenance.schema_version | Should -Be '1.0'
        $script:manifest.installer_contract.canary.docker_context | Should -Be 'desktop-linux'
        foreach ($repo in @($script:manifest.managed_repos)) {
            $repo.PSObject.Properties.Name | Should -Contain 'required_gh_repo'
            $repo.PSObject.Properties.Name | Should -Contain 'default_branch'
            $repo.PSObject.Properties.Name | Should -Contain 'pinned_sha'
            ([string]$repo.pinned_sha) | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'contains codex skills fork and org entries in the manifest' {
        $repoSlugs = @($script:manifest.managed_repos | ForEach-Object { [string]$_.required_gh_repo })
        $repoSlugs | Should -Contain 'svelderrainruiz/labview-icon-editor-codex-skills'
        $repoSlugs | Should -Contain 'LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills'
    }

    It 'keeps canonical payload manifest aligned with repository manifest' {
        @($script:payloadManifest.managed_repos).Count | Should -Be @($script:manifest.managed_repos).Count
        ($script:payloadManifest | ConvertTo-Json -Depth 50) | Should -Be ($script:manifest | ConvertTo-Json -Depth 50)
    }

    It 'keeps diagnostics KPI config aligned with payload copy' {
        $kpiConfig = Get-Content -LiteralPath $script:kpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $payloadKpiConfig = Get-Content -LiteralPath $script:payloadKpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        ($payloadKpiConfig | ConvertTo-Json -Depth 30) | Should -Be ($kpiConfig | ConvertTo-Json -Depth 30)
    }

    It 'documents drift failure as the PR release signal' {
        $script:agentsContent | Should -Match 'Workspace SHA Refresh PR'
        $script:agentsContent | Should -Match 'auto-merge'
        $script:agentsContent | Should -Match 'fallback'
        $script:readmeContent | Should -Match 'Workspace SHA Refresh PR'
        $script:readmeContent | Should -Match 'automation/sha-refresh'
    }

    It 'defines CI pipeline workflow' {
        $script:ciWorkflowContent | Should -Match 'name:\s*CI Pipeline'
        $script:ciWorkflowContent | Should -Match 'pull_request:'
        $script:ciWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:ciWorkflowContent | Should -Match 'Invoke-Pester'
        $script:ciWorkflowContent | Should -Match 'Workspace Installer Contract'
        $script:ciWorkflowContent | Should -Match 'Reproducibility Contract'
        $script:ciWorkflowContent | Should -Match 'Provenance Contract'
        $script:ciWorkflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:ciWorkflowContent | Should -Match 'DockerDesktopLinuxIterationContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'RunnerCliBundleDeterminismContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'ProvenanceContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'LinuxLabviewImageGateWorkflowContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'CiWorkflowReliabilityContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceInstallerDeveloperExperienceContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceShaRefreshPrContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceManifestPinRefreshScript\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceInstallerDiagnosticsSchema\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceInstallerKpiContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceInstallerHangRecoveryContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceInstallerKpiWorkflowContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'ENABLE_SELF_HOSTED_CONTRACTS'
    }

    It 'defines manual installer release workflow contract' {
        $script:releaseWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:releaseWorkflowContent | Should -Match 'release_tag:'
        $script:releaseWorkflowContent | Should -Match 'lvie-cdev-workspace-installer\.exe'
        $script:releaseWorkflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:releaseWorkflowContent | Should -Match 'gh release upload'
        $script:releaseWorkflowContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:releaseWorkflowContent | Should -Match 'workspace-installer\.slsa\.json'
    }

    It 'defines workspace installer KPI signal workflow contract' {
        $script:kpiWorkflowContent | Should -Match 'name:\s*Workspace Installer KPI Signal'
        $script:kpiWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:kpiWorkflowContent | Should -Match 'schedule:'
        $script:kpiWorkflowContent | Should -Match 'Collect-WorkspaceInstallerDiagnostics\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Measure-WorkspaceInstallerKpis\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Assert-WorkspaceInstallerKpis\.ps1'
        $script:kpiWorkflowContent | Should -Match 'Publish-WorkspaceInstallerKpiSummary\.ps1'
    }

    It 'defines installer harness artifact contract with exec diagnostics log' {
        $script:installerHarnessWorkflowContent | Should -Match 'name:\s*Installer Harness'
        $script:installerHarnessWorkflowContent | Should -Match 'Upload installer harness artifacts'
        $script:installerHarnessWorkflowContent | Should -Match 'workspace-installer-launch\.log'
        $script:installerHarnessWorkflowContent | Should -Match 'workspace-installer-exec\.log'
        $script:installerHarnessWorkflowContent | Should -Match 'workspace-installer-kpi-summary\.md'
    }
}
