#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$SourceBaseUrl = $env:SITECORE_TRANSFER_SOURCE_URL,
    [string]$DestinationBaseUrl = $env:SITECORE_TRANSFER_DESTINATION_URL,
    [ValidateSet('KeepExistingItem', 'OverrideExistingItem', 'OverrideExistingTree')]
    [string]$MergeStrategyOverride,
    [ValidateRange(1, 3600)][int]$PollIntervalSeconds = 5,
    [ValidateRange(1, 86400)][int]$PollTimeoutSeconds = 1800,
    [ValidateRange(0, 100)][int]$RetryCount = 0,
    [bool]$AutoCleanup = $true,
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SitecoreTransfer.psm1') -Force
$runtime = $null
try {
    $configuration = Read-TransferConfiguration -ConfigPath $ConfigPath -MergeStrategyOverride $MergeStrategyOverride
    $runtime = New-TransferRuntime -SourceBaseUrl $SourceBaseUrl -DestinationBaseUrl $DestinationBaseUrl
    $arguments = @{
        Configuration = $configuration
        ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        Runtime = $runtime
        PollIntervalSeconds = $PollIntervalSeconds
        PollTimeoutSeconds = $PollTimeoutSeconds
        RetryCount = $RetryCount
        AutoCleanup = $AutoCleanup
        Verbose = $VerbosePreference -eq 'Continue'
    }
    if ($StatePath) { $arguments.StatePath = $StatePath }
    Invoke-SitecoreContentTransfer @arguments | Out-Null
}
catch {
    Write-Error -Message (Protect-TransferText -Text $_.Exception.Message -Runtime $runtime) -ErrorAction Continue
    exit 1
}
finally {
    if ($runtime) { $runtime.Client.Dispose() }
}

# Also reset LASTEXITCODE for callers invoking this script in an existing PowerShell session.
exit 0
