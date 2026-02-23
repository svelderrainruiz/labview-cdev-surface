#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer KPI contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:kpiConfigPath = Join-Path $script:repoRoot 'diagnostics-kpi.json'
        $script:payloadKpiConfigPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/diagnostics-kpi.json'
        $script:measureScriptPath = Join-Path $script:repoRoot 'scripts/Measure-WorkspaceInstallerKpis.ps1'
        $script:assertScriptPath = Join-Path $script:repoRoot 'scripts/Assert-WorkspaceInstallerKpis.ps1'
        $script:collectScriptPath = Join-Path $script:repoRoot 'scripts/Collect-WorkspaceInstallerDiagnostics.ps1'
        $script:publishScriptPath = Join-Path $script:repoRoot 'scripts/Publish-WorkspaceInstallerKpiSummary.ps1'

        foreach ($path in @(
                $script:kpiConfigPath,
                $script:payloadKpiConfigPath,
                $script:measureScriptPath,
                $script:assertScriptPath,
                $script:collectScriptPath,
                $script:publishScriptPath
            )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required KPI contract file missing: $path"
            }
        }

        $script:kpiConfig = Get-Content -LiteralPath $script:kpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:payloadKpiConfig = Get-Content -LiteralPath $script:payloadKpiConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'defines threshold and burn-in contracts in machine-readable config' {
        [string]$script:kpiConfig.kpi_version | Should -Be '1.0'
        [string]$script:kpiConfig.burn_in_mode | Should -Match '^(advisory|blocking)$'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'artifact_coverage_rate_min'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'failure_summary_completeness_min'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'mean_time_to_diagnose_minutes_max'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'hang_recovery_time_minutes_max'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'terminal_run_rate_60m_min'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'schema_conformance_rate_min'
        $script:kpiConfig.thresholds.PSObject.Properties.Name | Should -Contain 'actionable_error_rate_min'
        @($script:kpiConfig.required_artifacts).Count | Should -BeGreaterThan 0
    }

    It 'keeps payload diagnostics KPI config aligned with repository copy' {
        ($script:payloadKpiConfig | ConvertTo-Json -Depth 20) | Should -Be ($script:kpiConfig | ConvertTo-Json -Depth 20)
    }

    It 'enforces advisory then blocking behavior for KPI breaches' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("workspace-kpi-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        try {
            $sampleDiagnosticsPath = Join-Path $tempRoot 'diagnostics-input.json'
            $sampleKpiReportPath = Join-Path $tempRoot 'kpi-report.json'
            $advisoryAssertionPath = Join-Path $tempRoot 'assert-advisory.json'
            $blockingAssertionPath = Join-Path $tempRoot 'assert-blocking.json'

            [ordered]@{
                status = 'failed'
                kpi_inputs = [ordered]@{
                    schema_version = '1.0'
                    required_artifact_status = @(
                        [ordered]@{ id = 'workspace-install-latest.json'; exists = $true },
                        [ordered]@{ id = 'workspace-installer-launch.log'; exists = $false },
                        [ordered]@{ id = 'harness-validation-report.json'; exists = $false },
                        [ordered]@{ id = 'runner-baseline-report.json'; exists = $false },
                        [ordered]@{ id = 'machine-preflight-report.json'; exists = $false }
                    )
                    missing_required_artifacts = @(
                        'workspace-installer-launch.log',
                        'harness-validation-report.json',
                        'runner-baseline-report.json',
                        'machine-preflight-report.json'
                    )
                    timeout_artifacts_present = @('smoke-installer-timeout-diagnostics.json')
                    failure_summary_completeness = 0.5
                    estimated_time_to_diagnose_minutes = 30
                    actionable_error_count = 0
                    warning_count = 2
                    phase_duration_seconds = 5000
                    terminal_within_60m = $false
                    stuck_process_count = 3
                }
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sampleDiagnosticsPath -Encoding UTF8

            & pwsh -NoProfile -File $script:measureScriptPath `
                -DiagnosticsPath $sampleDiagnosticsPath `
                -KpiConfigPath $script:kpiConfigPath `
                -ScopeProfile Harness `
                -OutputPath $sampleKpiReportPath
            $LASTEXITCODE | Should -Be 0

            & pwsh -NoProfile -File $script:assertScriptPath `
                -KpiReportPath $sampleKpiReportPath `
                -KpiConfigPath $script:kpiConfigPath `
                -BurnInModeOverride advisory `
                -OutputPath $advisoryAssertionPath
            $LASTEXITCODE | Should -Be 0
            $advisory = Get-Content -LiteralPath $advisoryAssertionPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [int]$advisory.summary.advisory_failures | Should -BeGreaterThan 0
            [int]$advisory.summary.blocking_failures | Should -Be 0

            & pwsh -NoProfile -File $script:assertScriptPath `
                -KpiReportPath $sampleKpiReportPath `
                -KpiConfigPath $script:kpiConfigPath `
                -BurnInModeOverride blocking `
                -OutputPath $blockingAssertionPath
            $LASTEXITCODE | Should -Be 1
            $blocking = Get-Content -LiteralPath $blockingAssertionPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [int]$blocking.summary.blocking_failures | Should -BeGreaterThan 0
        } finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
