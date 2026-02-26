#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw ("gh_command_failed: exit={0} command=gh {1}" -f $exitCode, ($Arguments -join ' '))
    }
}

function Invoke-GhText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw ("gh_command_failed: exit={0} command=gh {1}" -f $exitCode, ($Arguments -join ' '))
    }

    if ($output -is [System.Array]) {
        return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }

    return [string]$output
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $json = Invoke-GhText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Path $fullPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    return $fullPath
}

function Write-WorkflowOpsReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter()][string]$OutputPath = ''
    )

    $json = ($Report | ConvertTo-Json -Depth 10)
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedPath = Ensure-ParentDirectory -Path $OutputPath
        Set-Content -LiteralPath $resolvedPath -Value $json -Encoding utf8
        Write-Host ("Report written: {0}" -f $resolvedPath)
    }

    Write-Output $json
}

function Get-UtcNowIso {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Convert-InputPairsToGhArgs {
    param([Parameter()][string[]]$Input = @())

    $arguments = @()
    foreach ($pair in @($Input)) {
        $text = ([string]$pair).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $splitIndex = $text.IndexOf('=')
        if ($splitIndex -lt 1) {
            throw ("input_pair_invalid: '{0}' must be key=value." -f $text)
        }

        $key = $text.Substring(0, $splitIndex).Trim()
        $value = $text.Substring($splitIndex + 1)
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw ("input_key_invalid: '{0}' has empty key." -f $text)
        }

        $arguments += @('-f', ("{0}={1}" -f $key, $value))
    }

    return ,$arguments
}

function Parse-RunTimestamp {
    param([Parameter(Mandatory = $true)][object]$Run)

    $createdAt = [string]$Run.createdAt
    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        return [DateTimeOffset]::MinValue
    }

    $value = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($createdAt, [ref]$value)) {
        return $value
    }

    return [DateTimeOffset]::MinValue
}
