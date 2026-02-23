#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer diagnostics schema contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:schemaPath = Join-Path $script:repoRoot 'schemas/workspace-installer-diagnostics.schema.json'
        $script:installScriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        if (-not (Test-Path -LiteralPath $script:schemaPath -PathType Leaf)) {
            throw "Diagnostics schema missing: $script:schemaPath"
        }
        if (-not (Test-Path -LiteralPath $script:installScriptPath -PathType Leaf)) {
            throw "Installer script missing: $script:installScriptPath"
        }

        $script:schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:installContent = Get-Content -LiteralPath $script:installScriptPath -Raw
    }

    It 'requires diagnostics envelope and schema version 1.0' {
        @($script:schema.required) | Should -Contain 'diagnostics'
        @($script:schema.properties.diagnostics.required) | Should -Contain 'schema_version'
        [string]$script:schema.properties.diagnostics.properties.schema_version.const | Should -Be '1.0'
    }

    It 'declares first-class diagnostics fields for DX and KPI gates' {
        $required = @($script:schema.properties.diagnostics.required)
        $required | Should -Contain 'platform'
        $required | Should -Contain 'execution_context'
        $required | Should -Contain 'phase_metrics'
        $required | Should -Contain 'command_diagnostics'
        $required | Should -Contain 'artifact_index'
        $required | Should -Contain 'failure_fingerprint'
        $required | Should -Contain 'developer_feedback'
    }

    It 'emits diagnostics object from installer runtime report' {
        $script:installContent | Should -Match 'diagnostics = \[ordered\]@{'
        $script:installContent | Should -Match 'schema_version = ''1\.0'''
        $script:installContent | Should -Match 'phase_metrics = \$phaseMetrics'
        $script:installContent | Should -Match 'command_diagnostics = \$commandDiagnostics'
        $script:installContent | Should -Match 'failure_fingerprint = \$failureFingerprint'
        $script:installContent | Should -Match 'developer_feedback = \$developerFeedback'
    }
}
