#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Upload artifact retry composite contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:path = Join-Path $script:repoRoot '.github/actions/upload-artifact-retry/action.yml'
        if (-not (Test-Path -LiteralPath $script:path -PathType Leaf)) {
            throw "Composite missing: $script:path"
        }
        $script:content = Get-Content -LiteralPath $script:path -Raw
    }

    It 'attempts upload twice and fails after both attempts fail' {
        $script:content | Should -Match 'upload_attempt_1'
        $script:content | Should -Match 'upload_attempt_2'
        $script:content | Should -Match "if: steps\.upload_attempt_1\.outcome == 'failure'"
        $script:content | Should -Match 'artifact_upload_failed_after_two_attempts'
    }
}
