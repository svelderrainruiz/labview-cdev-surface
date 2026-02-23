#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace install runtime contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Workspace installer runtime script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines required parameters and install verify modes' {
        $script:scriptContent | Should -Match '\[string\]\$WorkspaceRoot = ''C:\\dev'''
        $script:scriptContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s*\[string\]\$ManifestPath'
        $script:scriptContent | Should -Match '\[ValidateSet\(''Install'', ''Verify''\)\]'
        $script:scriptContent | Should -Match '\[Alias\(''ExecutionContext''\)\]\s*\[string\]\$InstallExecutionContext = '''''
        $script:scriptContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s*\[string\]\$OutputPath'
    }

    It 'fails fast on missing dependencies and enforces deterministic pinned_sha checks' {
        $script:scriptContent | Should -Match 'foreach \(\$commandName in @\(''pwsh'', ''git'', ''gh'', ''g-cli''\)\)'
        $script:scriptContent | Should -Match 'invalid pinned_sha'
        $script:scriptContent | Should -Match 'head_sha_mismatch'
        $script:scriptContent | Should -Match 'remote_mismatch_'
        $script:scriptContent | Should -Match 'branch_identity_mismatch'
    }

    It 'copies governance payload to workspace root, validates runner-cli bundle, and runs governance audit' {
        $script:scriptContent | Should -Match 'workspace-governance\.json'
        $script:scriptContent | Should -Match 'AGENTS\.md'
        $script:scriptContent | Should -Match 'Assert-WorkspaceGovernance\.ps1'
        $script:scriptContent | Should -Match 'function Convert-ToProcessArgumentString'
        $script:scriptContent | Should -Match 'ArgumentList = \$argumentString'
        $script:scriptContent | Should -Match 'Get-LabviewProcesses'
        $script:scriptContent | Should -Match 'Stop-NewLabviewProcesses'
        $script:scriptContent | Should -Match 'Get-VipmProcesses'
        $script:scriptContent | Should -Match 'Stop-NewVipmProcesses'
        $script:scriptContent | Should -Match 'runner-cli\.exe'
        $script:scriptContent | Should -Match 'runner-cli\.metadata\.json'
        $script:scriptContent | Should -Match 'required_ppl_bitnesses'
        $script:scriptContent | Should -Match 'required_vip_bitness'
        $script:scriptContent | Should -Match 'Get-LabVIEWContainerExecutionContract'
        $script:scriptContent | Should -Match '\.lvcontainer'
        $script:scriptContent | Should -Match 'Get-LabVIEWSourceVersionFromRepo'
        $script:scriptContent | Should -Match 'Set-LabVIEWSourceVersionInRepo'
        $script:scriptContent | Should -Match 'runner_cli_labview_version'
        $script:scriptContent | Should -Match '\.lvversion is ignored in container execution'
        $script:scriptContent | Should -Match '\.lvversion is not used in container execution'
        $script:scriptContent | Should -Not -Match "fell back to '\.lvversion' source contract"
        $script:scriptContent | Should -Match 'lvversion_container_shim'
        $script:scriptContent | Should -Match 'Container source version shim status='
        $script:scriptContent | Should -Match 'source_contract=.lvcontainer'
        $script:scriptContent | Should -Match 'LVIE_INSTALLER_CONTAINER_MODE'
        $script:scriptContent | Should -Match 'LVIE_SKIP_VIP_HARNESS'
        $script:scriptContent | Should -Match 'Unblock-ExecutableForAutomation'
        $script:scriptContent | Should -Match 'NsisInstall'
        $script:scriptContent | Should -Match 'Invoke-RunnerCliPplCapabilityCheck'
        $script:scriptContent | Should -Match 'Invoke-RunnerCliVipPackageHarnessCheck'
        $script:scriptContent | Should -Match 'vipc assert'
        $script:scriptContent | Should -Match 'vip build'
        $script:scriptContent | Should -Match 'Write-InstallerFeedback'
        $script:scriptContent | Should -Match 'ppl_capability_checks'
        $script:scriptContent | Should -Match 'post_action_sequence'
        $script:scriptContent | Should -Match 'governance-audit'
        $script:scriptContent | Should -Match 'labview-cleanup'
        $script:scriptContent | Should -Match 'vipm-cleanup'
        $script:scriptContent | Should -Match 'labview_process_cleanup'
        $script:scriptContent | Should -Match 'vipm_process_cleanup'
        $script:scriptContent | Should -Match 'process_cleanup = \[ordered\]@\{'
        $script:scriptContent | Should -Match 'branch_protection_'
        $script:scriptContent | Should -Match 'branch_only_failure'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
