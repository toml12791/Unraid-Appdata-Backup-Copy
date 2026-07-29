#Requires -Version 5.1

# Copyright (c) 2026 toml12791
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Copies the newest completed Unraid appdata backup to a local Windows drive.

.DESCRIPTION
    Native PowerShell rewrite of Unraid_Appdata_Backup_Copy.cmd.

    Preserved behavior includes:
      - Manual, scheduled, and Discord-test modes
      - Shared Config.ini with automatic first-run configuration
      - Optional Discord webhook integration and structured embeds
      - Exact ab_YYYYMMDD_HHMMSS backup discovery
      - Freshness enforcement
      - Three consecutive one-minute stability checks
      - Destination-space estimation with a safety reserve
      - Restart-friendly Robocopy transfer
      - Robocopy summary parsing and exit-code classification
      - Post-copy relative-path and exact-size verification
      - Local-only retention after verification succeeds
      - Detailed permanent logs and temporary Robocopy logs
      - Success, warning, and failure console screens
      - Centralized failure reporting with preserved exit codes

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Unraid_Appdata_Backup_Copy.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Unraid_Appdata_Backup_Copy.ps1 /scheduled

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Unraid_Appdata_Backup_Copy.ps1 /testdiscord

.NOTES
    The legacy slash arguments are supported so an existing Task Scheduler
    action can be converted with minimal changes. Native -Scheduled and
    -TestDiscord switches are also supported.

    The Robocopy summary parser expects English Robocopy summary labels.
#>

[CmdletBinding()]
param(
    [switch] $Scheduled,
    [switch] $TestDiscord,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $LegacyArguments
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Run-mode compatibility
# -----------------------------------------------------------------------------

$scheduledMode = [bool]$Scheduled
$testDiscordMode = [bool]$TestDiscord
$unknownLegacyArguments = @()

foreach ($argument in @($LegacyArguments)) {
    if ([string]::IsNullOrWhiteSpace($argument)) {
        continue
    }

    if ($argument -ieq '/scheduled') {
        $scheduledMode = $true
    }
    elseif ($argument -ieq '/testdiscord') {
        $testDiscordMode = $true
    }
    else {
        $unknownLegacyArguments += $argument
    }
}

# Reject unknown legacy arguments before run state is initialized.
# This prevents a misspelled /scheduled argument from accidentally
# starting an interactive manual run in Task Scheduler.
if ($unknownLegacyArguments.Count -gt 0) {
    $argumentList = (
        $unknownLegacyArguments |
        ForEach-Object { '"{0}"' -f $_ }
    ) -join ', '

    Write-Host ''
    Write-Host '============================================================'
    Write-Host '               INVALID COMMAND-LINE ARGUMENT'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host ('  Unknown argument(s): {0}' -f $argumentList)
    Write-Host ''
    Write-Host '  Valid legacy arguments:'
    Write-Host '      /scheduled'
    Write-Host '      /testdiscord'
    Write-Host ''
    Write-Host '  Valid native PowerShell switches:'
    Write-Host '      -Scheduled'
    Write-Host '      -TestDiscord'
    Write-Host ''
    Write-Host '  Exit code: 27'
    Write-Host '============================================================'
    Write-Host ''

    exit 27
}

# Scheduled backup mode and Discord-test mode represent different
# operations and should not be requested together.
if ($scheduledMode -and $testDiscordMode) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host '              CONFLICTING COMMAND-LINE MODES'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host '  Scheduled backup mode and Discord-test mode cannot be'
    Write-Host '  used in the same invocation.'
    Write-Host ''
    Write-Host '  Choose only one of:'
    Write-Host '      /scheduled'
    Write-Host '      /testdiscord'
    Write-Host '      -Scheduled'
    Write-Host '      -TestDiscord'
    Write-Host ''
    Write-Host '  Exit code: 27'
    Write-Host '============================================================'
    Write-Host ''

    exit 27
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

# -----------------------------------------------------------------------------
# Central run state
# -----------------------------------------------------------------------------

$script:State = [pscustomobject]([ordered]@{
        AppName                 = 'Unraid Appdata Backup Copy'
        AppVersion              = '1.0.0'

        ManualRun               = -not $scheduledMode
        TestDiscordMode         = $testDiscordMode

        ConfigFile              = Join-Path `
            -Path $PSScriptRoot `
            -ChildPath 'Config.ini'

        PlaceholderSource       = '\\SERVER\SHARE\BACKUP-FOLDER'
        PlaceholderDestination  = 'E:\DESTINATION-FOLDER'
        PlaceholderWebhook      = 'https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN'

        SourceRoot              = $null
        DestinationRoot         = $null
        DestinationDrive        = $null
        LogDirectory            = $null
        LogFile                 = $null
        RobocopyRunLog          = $null

        KeepBackups             = 10
        MaximumBackupAgeHours   = 48.0
        FreeSpaceReserveGB      = 50.0
        TransferAttempted       = $false

        CompletionWarning       = $false
        CompletionWarningReason = $null
        StaleWarning            = $false
        RobocopyWarning         = $false
        RobocopyClass           = 'Not run'
        RobocopyDescription     = 'Robocopy has not run.'

        LatestBackup            = $null
        SourceFolder            = $null
        DestinationFolder       = $null
        BackupAgeDisplay        = 'Unavailable'

        RobocopyCode            = $null
        FilesCopied             = 'Unavailable'
        DataCopied              = 'Unavailable'
        AverageSpeed            = 'Unavailable'
        Failures                = 'Unavailable'

        PostVerifyStatus        = 'Not run'
        VerifySourceFiles       = 'Unavailable'
        VerifyDestinationFiles  = 'Unavailable'
        VerifySourceSize        = 'Unavailable'
        VerifyDestinationSize   = 'Unavailable'
        VerifyMissingFiles      = 'Unavailable'
        VerifyWrongSize         = 'Unavailable'
        VerifyExtraFiles        = 'Unavailable'

        DestinationFreeDisplay  = 'Unavailable'
        TotalTime               = 'Unavailable'
        FinalResult             = $null

        DiscordWebhook          = $null
        DiscordEnabled          = $false
        DiscordConfigWarning    = $null
        LastDiscordError        = $null
        LastDiscordResponse     = $null

        CurrentStage            = 'Startup'
        FailCode                = $null
        FailReason              = $null
        FailDetail              = $null
        FailBackup              = 'Not selected'
        FailLog                 = 'Not created'
        FailDiscord             = 'Disabled'

        OperationStopwatch      = $null
    })

# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------

function Set-BackupWindowTitle {
    param([Parameter(Mandatory = $true)][string] $Title)

    try {
        $Host.UI.RawUI.WindowTitle = $Title
    }
    catch {
        # Window titles are cosmetic and are not supported by every host.
    }
}


function Clear-BackupHost {
    try {
        Clear-Host
    }
    catch {
        # Screen clearing is cosmetic and is not supported by every host.
    }
}

function Write-ConsoleInline {
    param([Parameter(Mandatory = $true)][string] $Text)

    try {
        [Console]::Write($Text)
    }
    catch {
        try {
            Write-Host -NoNewline $Text
        }
        catch {
            # Countdown display is cosmetic; the wait itself must continue.
        }
    }
}

function Get-DisplayTimestamp {
    return (Get-Date).ToString(
        'ddd MM/dd/yyyy  H:mm:ss.ff',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Add-LogLine {
    param([AllowEmptyString()][string] $Text = '')

    if ([string]::IsNullOrWhiteSpace($script:State.LogFile)) {
        return
    }

    [IO.File]::AppendAllText(
        $script:State.LogFile,
        $Text + [Environment]::NewLine,
        $script:Utf8NoBom
    )
}

function Add-LogText {
    param([AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($script:State.LogFile)) {
        return
    }

    if ($null -eq $Text) {
        return
    }

    [IO.File]::AppendAllText(
        $script:State.LogFile,
        $Text,
        $script:Utf8NoBom
    )
}

function Write-Status {
    param([Parameter(Mandatory = $true)][string] $Message)

    $line = '[{0}] {1}' -f (Get-DisplayTimestamp), $Message
    Write-Host $line
    Add-LogLine $line
}

function Write-Screen {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines,

        [switch] $ToHost,
        [switch] $ToLog
    )

    if ($ToHost) {
        foreach ($line in $Lines) {
            Write-Host $line
        }
    }

    if ($ToLog) {
        foreach ($line in $Lines) {
            Add-LogLine $line
        }
    }
}

function Wait-ForKey {
    param([string] $Prompt)

    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        Write-Host $Prompt
    }

    try {
        [void][Console]::ReadKey($true)
    }
    catch {
        [void](Read-Host)
    }
}

function Format-ByteCount {
    param([Parameter(Mandatory = $true)][Int64] $Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ($Bytes.ToString('N0') + ' bytes')
}

function Format-Duration {
    param([Parameter(Mandatory = $true)][TimeSpan] $Elapsed)

    $hours = [math]::Floor($Elapsed.TotalHours)
    return ('{0:00}:{1:00}:{2:00}' -f $hours, $Elapsed.Minutes, $Elapsed.Seconds)
}

function Get-AppIdentity {
    return ('{0} v{1}' -f `
            $script:State.AppName, `
            $script:State.AppVersion)
}

function Format-DiscordCode {
    param([AllowNull()][object] $Value)
    return ('`{0}`' -f [string]$Value)
}

function New-DiscordField {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [AllowEmptyString()][string] $Value = '-',
        [bool] $Inline = $false
    )

    return [pscustomobject][ordered]@{
        name   = $Name
        value  = $(if ([string]::IsNullOrWhiteSpace($Value)) { '-' } else { $Value })
        inline = $Inline
    }
}

function Stop-BackupOperation {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [string] $Detail
    )

    $exception = New-Object System.Exception -ArgumentList $Reason
    $exception.Data['BackupFailureCode'] = $Code
    $exception.Data['BackupFailureReason'] = $Reason
    $exception.Data['BackupFailureDetail'] = $Detail
    throw $exception
}

function Test-PolicyConfiguration {
    if ($script:State.KeepBackups -lt 1) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The backup policy configuration is invalid.' `
            -Detail 'KeepBackups must be at least 1.'
    }

    if ($script:State.MaximumBackupAgeHours -lt 0) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The backup policy configuration is invalid.' `
            -Detail 'MaximumBackupAgeHours cannot be negative.'
    }

    if ($script:State.FreeSpaceReserveGB -lt 0) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The backup policy configuration is invalid.' `
            -Detail 'FreeSpaceReserveGB cannot be negative.'
    }
}

function Import-IniFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration file was not found.' `
            -Detail ('Create the configuration file: {0}' -f $Path)
    }

    try {
        $lines = @(
            Get-Content `
                -LiteralPath $Path `
                -ErrorAction Stop
        )
    }
    catch {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration file could not be read.' `
            -Detail $_.Exception.Message
    }

    $configuration = @{}
    $currentSection = $null

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $line = ([string]$lines[$index]).Trim()

        # Ignore blank lines and comments.
        if (
            [string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith(';') -or
            $line.StartsWith('#')
        ) {
            continue
        }

        # Read section headers such as [Backup].
        if ($line -match '^\[(?<Section>[^\]]+)\]$') {
            $currentSection = $matches['Section'].Trim()

            if ([string]::IsNullOrWhiteSpace($currentSection)) {
                Stop-BackupOperation `
                    -Code 22 `
                    -Reason 'The application configuration is invalid.' `
                    -Detail ('Empty section name on line {0}.' -f $lineNumber)
            }

            if (-not $configuration.ContainsKey($currentSection)) {
                $configuration[$currentSection] = @{}
            }

            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentSection)) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'The application configuration is invalid.' `
                -Detail ('Setting found outside a section on line {0}: {1}' -f `
                    $lineNumber, `
                    $line)
        }

        # Split at only the first equals sign so webhook tokens remain intact.
        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'The application configuration is invalid.' `
                -Detail ('Expected Key=Value on line {0}: {1}' -f `
                    $lineNumber, `
                    $line)
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()

        if ([string]::IsNullOrWhiteSpace($key)) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'The application configuration is invalid.' `
                -Detail ('Empty setting name on line {0}.' -f $lineNumber)
        }

        # Allow optional quotation marks around values.
        if (
            $value.Length -ge 2 -and
            $value.StartsWith('"') -and
            $value.EndsWith('"')
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($configuration[$currentSection].ContainsKey($key)) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'The application configuration is invalid.' `
                -Detail ('Duplicate setting [{0}] {1} on line {2}.' -f `
                    $currentSection, `
                    $key, `
                    $lineNumber)
        }

        $configuration[$currentSection][$key] = $value
    }

    return $configuration
}

function Test-DiscordWebhookFormat {
    param(
        [AllowEmptyString()]
        [string] $Webhook
    )

    if ([string]::IsNullOrWhiteSpace($Webhook)) {
        return $true
    }

    return (
        $Webhook.Trim() -match
        '^https://discord\.com/api/webhooks/\d+/.+$'
    )
}

function Get-ConfigurationSetupStatus {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Configuration
    )

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $sourceValue = ''
    $destinationValue = ''
    $webhookValue = ''

    if ($Configuration.ContainsKey('Backup')) {
        $backupSection = $Configuration['Backup']

        if ($backupSection.ContainsKey('Source')) {
            $sourceValue = [string]$backupSection['Source']
        }
        elseif ($backupSection.ContainsKey('Target')) {
            $sourceValue = [string]$backupSection['Target']
        }

        if ($backupSection.ContainsKey('Destination')) {
            $destinationValue = [string]$backupSection['Destination']
        }
    }

    if (
        $Configuration.ContainsKey('Discord') -and
        $Configuration['Discord'].ContainsKey('Webhook')
    ) {
        $webhookValue = [string]$Configuration['Discord']['Webhook']
    }

    $sourceValue = $sourceValue.Trim()
    $destinationValue = $destinationValue.Trim()
    $webhookValue = $webhookValue.Trim()

    $isPackagedPlaceholder = (
        $sourceValue -ieq $script:State.PlaceholderSource
    ) -and (
        $destinationValue -ieq $script:State.PlaceholderDestination
    ) -and (
        $webhookValue -ieq $script:State.PlaceholderWebhook
    )

    try {
        [void](Get-BackupConfiguration -Configuration $Configuration)
    }
    catch {
        $detail = $_.Exception.Message

        if ($_.Exception.Data.Contains('BackupFailureDetail')) {
            $detail = [string]$_.Exception.Data['BackupFailureDetail']
        }

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = 'The [Backup] configuration is incomplete or invalid.'
        }

        $reasons.Add($detail)
    }

    if ($sourceValue -ieq $script:State.PlaceholderSource) {
        $reasons.Add(
            'The packaged Source placeholder has not been replaced.'
        )
    }

    if (
        $destinationValue -ieq
        $script:State.PlaceholderDestination
    ) {
        $reasons.Add(
            'The packaged Destination placeholder has not been replaced.'
        )
    }

    if ($webhookValue -ieq $script:State.PlaceholderWebhook) {
        $reasons.Add(
            'The packaged Discord webhook placeholder has not been replaced.'
        )
    }
    elseif (
        -not [string]::IsNullOrWhiteSpace($webhookValue) -and
        -not (Test-DiscordWebhookFormat -Webhook $webhookValue)
    ) {
        $reasons.Add(
            'The nonblank Discord webhook is not a supported Discord webhook URL.'
        )
    }

    return [pscustomobject]@{
        RequiresSetup         = ($reasons.Count -gt 0)
        Reasons               = $reasons.ToArray()
        IsPackagedPlaceholder = $isPackagedPlaceholder
    }
}

function Read-SetupYesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Prompt,

        [bool] $DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }

    while ($true) {
        $answer = [string](
            Read-Host ('{0} {1}' -f $Prompt, $suffix)
        )

        $answer = $answer.Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        if ($answer -ieq 'y' -or $answer -ieq 'yes') {
            return $true
        }

        if ($answer -ieq 'n' -or $answer -ieq 'no') {
            return $false
        }

        Write-Host 'Please enter Y or N.'
    }
}

function ConvertFrom-SetupSecureString {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString] $SecureValue
    )

    $pointer = [IntPtr]::Zero

    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $SecureValue
        )

        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $pointer
        )
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Read-SetupPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Source', 'Destination')]
        [string] $Kind
    )

    $isSource = ($Kind -eq 'Source')
    $example = if ($isSource) {
        '\\tower\share\APPDATA Backup'
    }
    else {
        'E:\Destination Folder'
    }

    while ($true) {
        Write-Host ''
        Write-Host (
            'Enter the {0} backup path.' -f
            $Kind.ToLowerInvariant()
        )
        Write-Host '(The parent folder containing the Unraid Appdata Backup folders.)'
        Write-Host ('Example: {0}' -f $example)
        Write-Host ''

        $value = [string](Read-Host $Kind)
        $value = $value.Trim()

        if (
            $value.Length -ge 2 -and
            $value.StartsWith('"') -and
            $value.EndsWith('"')
        ) {
            $value = $value.Substring(1, $value.Length - 2).Trim()
        }

        if ($value.Length -gt 3) {
            $value = $value.TrimEnd([char]'\')
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host ''
            Write-Host ('{0} cannot be blank.' -f $Kind)
            continue
        }

        $knownPlaceholder = if ($isSource) {
            $script:State.PlaceholderSource
        }
        else {
            $script:State.PlaceholderDestination
        }

        if ($value -ieq $knownPlaceholder) {
            Write-Host ''
            Write-Host (
                'Enter a real path instead of the packaged placeholder.'
            )
            continue
        }

        if (
            $isSource -and
            -not (
                $value.StartsWith('\\') -or
                $value -match '^[A-Za-z]:\\'
            )
        ) {
            Write-Host ''
            Write-Host (
                'Source must be a UNC path or an absolute drive path.'
            )
            continue
        }

        if (
            -not $isSource -and
            $value -notmatch '^[A-Za-z]:\\'
        ) {
            Write-Host ''
            Write-Host (
                'Destination must begin with a drive letter and backslash.'
            )
            continue
        }

        $availabilityPath = if ($isSource) {
            $value
        }
        else {
            [IO.Path]::GetPathRoot($value)
        }

        try {
            $isAvailable = Test-Path `
                -LiteralPath $availabilityPath `
                -PathType Container
        }
        catch {
            $isAvailable = $false
        }

        if (-not $isAvailable) {
            Write-Host ''
            Write-Host (
                'WARNING: The {0} is unavailable right now.' -f
                $Kind.ToLowerInvariant()
            )
            Write-Host ('Configured value: {0}' -f $value)
            Write-Host ''

            if (
                -not (
                    Read-SetupYesNo `
                        -Prompt 'Save this value anyway?' `
                        -DefaultYes $false
                )
            ) {
                continue
            }
        }

        Write-Host ''

        if ($isAvailable) {
            if ($isSource) {
                Write-Host '  [OK] Source path confirmed and reachable.'
            }
            else {
                Write-Host (
                    '  [OK] Destination path accepted; drive {0} is available.' -f
                    $availabilityPath
                )
            }
        }
        else {
            Write-Host (
                '  [OK] {0} path accepted without availability confirmation.' -f
                $Kind
            )
        }

        return $value
    }
}

function Read-SetupWebhook {
    while ($true) {
        Write-Host ''
        Write-Host 'Discord notifications are optional.'
        Write-Host (
            'Paste a webhook, or press Enter to disable Discord.'
        )
        Write-Host (
            'The input is hidden and is not repeated on the summary screen.'
        )
        Write-Host ''

        $secureWebhook = Read-Host `
            -Prompt 'Discord webhook' `
            -AsSecureString

        $webhook = ConvertFrom-SetupSecureString `
            -SecureValue $secureWebhook

        $webhook = $webhook.Trim()

        if ([string]::IsNullOrWhiteSpace($webhook)) {
            return ''
        }

        if (-not (Test-DiscordWebhookFormat -Webhook $webhook)) {
            Write-Host ''
            Write-Host (
                'That does not look like a supported Discord webhook URL.'
            )
            Write-Host (
                'Expected: https://discord.com/api/webhooks/ID/TOKEN'
            )
            continue
        }

        return $webhook
    }
}

function Save-SetupConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [AllowEmptyString()]
        [string] $Webhook,

        [bool] $SkipExistingBackup = $false
    )

    $backupPath = $null
    $temporaryPath = '{0}.tmp-{1}' -f `
        $script:State.ConfigFile, `
        $PID

    try {
        if (
            -not $SkipExistingBackup -and
            (Test-Path `
                -LiteralPath $script:State.ConfigFile `
                -PathType Leaf)
        ) {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupPath = '{0}.bak-{1}' -f `
                $script:State.ConfigFile, `
                $timestamp

            Copy-Item `
                -LiteralPath $script:State.ConfigFile `
                -Destination $backupPath `
                -ErrorAction Stop
        }

        $lines = @(
            '[Backup]'
            ('Source={0}' -f $Source)
            ('Destination={0}' -f $Destination)
            ''
            '[Discord]'
            ('Webhook={0}' -f $Webhook)
            ''
        )

        [IO.File]::WriteAllText(
            $temporaryPath,
            ($lines -join [Environment]::NewLine),
            $script:Utf8NoBom
        )

        if (
            Test-Path `
                -LiteralPath $script:State.ConfigFile `
                -PathType Leaf
        ) {
            Remove-Item `
                -LiteralPath $script:State.ConfigFile `
                -Force `
                -ErrorAction Stop
        }

        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $script:State.ConfigFile `
            -Force `
            -ErrorAction Stop

        return $backupPath
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (
            -not (
                Test-Path `
                    -LiteralPath $script:State.ConfigFile `
                    -PathType Leaf
            ) -and
            -not [string]::IsNullOrWhiteSpace($backupPath) -and
            (Test-Path -LiteralPath $backupPath -PathType Leaf)
        ) {
            Copy-Item `
                -LiteralPath $backupPath `
                -Destination $script:State.ConfigFile `
                -ErrorAction SilentlyContinue
        }

        throw
    }
}

function Invoke-FirstRunSetup {
    param(
        [string[]] $Reasons = @(),

        [bool] $IsPackagedPlaceholder = $false
    )

    $script:State.CurrentStage = 'First-run configuration'

    Set-BackupWindowTitle ('{0} v{1} - First-Run Setup' -f `
            $script:State.AppName, `
            $script:State.AppVersion)

    while ($true) {
        Clear-BackupHost

        Write-Host ''
        Write-Host '    /------------------------\              |~~\_____/~~\__  |'
        Write-Host '    |    Let''s Get Ready     |______________ \______====== )-+'
        Write-Host '    |     For Takeoff!       |                      ~~~|/~~  |'
        Write-Host '    \------------------------/                         ()'
        Write-Host ''

        Write-Host '================================================================'
        Write-Host '          UNRAID APPDATA BACKUP COPY - FIRST-RUN SETUP'
        Write-Host '================================================================'
        Write-Host ''
        Write-Host (
            '  Config.ini is either missing, incomplete, invalid, or'
        )
        Write-Host '  still contains packaged placeholder values.'
        Write-Host ''
        Write-Host (
            '  This setup will write to Config.ini and then'
        )
        Write-Host '  continue the command you originally launched.'
        Write-Host ''

        if (@($Reasons).Count -gt 0) {
            Write-Host '  Configuration issues:'

            foreach ($reason in @($Reasons)) {
                if (-not [string]::IsNullOrWhiteSpace($reason)) {
                    Write-Host ('    - {0}' -f $reason)
                }
            }

            Write-Host ''
        }

        $source = Read-SetupPath -Kind Source
        $destination = Read-SetupPath -Kind Destination

        if (
            $source.Equals(
                $destination,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Write-Host ''
            Write-Host 'Source and Destination cannot be the same path.'
            Write-Host ''
            Wait-ForKey -Prompt 'Press any key to enter the values again...'
            continue
        }

        $webhook = Read-SetupWebhook
        $discordStatus = if (
            [string]::IsNullOrWhiteSpace($webhook)
        ) {
            'Disabled'
        }
        else {
            'Enabled'
        }

        Write-Host ''
        Write-Host '------------------------------------------------------------'
        Write-Host 'CONFIGURATION SUMMARY'
        Write-Host '------------------------------------------------------------'
        Write-Host ('Source:       {0}' -f $source)
        Write-Host ('Destination:  {0}' -f $destination)
        Write-Host ('Discord:      {0}' -f $discordStatus)
        Write-Host ''
        Write-Host (
            'The Discord credential is intentionally not displayed.'
        )
        Write-Host '------------------------------------------------------------'
        Write-Host ''

        if (
            Read-SetupYesNo `
                -Prompt 'Write this configuration?' `
                -DefaultYes $true
        ) {
            try {
                $backupPath = Save-SetupConfiguration `
                    -Source $source `
                    -Destination $destination `
                    -Webhook $webhook `
                    -SkipExistingBackup $IsPackagedPlaceholder
            }
            catch {
                Stop-BackupOperation `
                    -Code 22 `
                    -Reason 'The first-run configuration could not be saved.' `
                    -Detail $_.Exception.Message
            }

            Write-Host ''
            Write-Host '============================================================'
            Write-Host '              CONFIGURATION SAVED SUCCESSFULLY'
            Write-Host '============================================================'
            Write-Host ''
            Write-Host ('  Config.ini: {0}' -f $script:State.ConfigFile)

            if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
                Write-Host ('  Previous file: {0}' -f $backupPath)
            }

            Write-Host ('  Discord:   {0}' -f $discordStatus)
            Write-Host ''
            Write-Host '  Continuing with the original operation...'
            Write-Host '============================================================'
            Write-Host ''

            Start-Sleep -Seconds 1
            return
        }

        Write-Host ''

        if (
            Read-SetupYesNo `
                -Prompt 'Exit without completing setup?' `
                -DefaultYes $false
        ) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'Initial configuration was not completed.' `
                -Detail 'Run RUN.cmd manually to complete first-run setup.'
        }
    }
}

# -----------------------------------------------------------------------------
# Console screens
# -----------------------------------------------------------------------------

function Get-StartScreenLines {
    return @(
        ''
        '              __________________________'
        '             /_________________________/|'
        '            |  _____________________  | |'
        '            | |                     | | |'
        '            | |   UNRAID APPDATA    | | |'
        '            | |    BACKUP COPY      | | |'
        '            | |_____________________| | |'
        '            |    O               O    | /'
        '            |_________________________|/'
        ''
        '             Copyright (C) 2026 toml12791
        '
        '============================================================'
        ('        Welcome to {0}' -f (Get-AppIdentity))
        '============================================================'
        ''
        ('  Source:      {0}' -f $script:State.SourceRoot)
        ('  Destination: {0}' -f $script:State.DestinationRoot)
        ''
        ''
        '  This utility will perform the following:'
        ''
        ''
        '     [1] Validate paths and connections'
        '     [2] Find newest valid backup and check its age'
        '     [3] Wait until the newest backup is stable'
        '     [4] Estimate required copy space and verify free space'
        '     [5] Transfer backup data with ROBOCOPY'
        '     [6] Verify copied files by relative path and size'
        ('     [7] Retain only the {0} most recent local backups' -f $script:State.KeepBackups)
        ''
        '     Log the results and notify via Discord when enabled'
        ''
        ''
        '============================================================'
        '         The original backups are never modified.'
        '============================================================'
        ''
    )
}

function Get-ReadyScreenLines {
    return @(
        ''
        '============================================================'
        '                       READY TO RUN'
        '============================================================'
        ''
        '  \ o /  _ o         __|    \ /     |__        o _  \ o /'
        '    |     /\   ___\o   \o    |    o/    o/__   /\     |'
        '   / \   | \  /)  |    ( \  /o\  / )    |  (\  / |   / \'
        ''
        '============================================================'
        '  Preliminary Checks - [PASSED]'
        '  Press any key to begin backup verification...'
        '============================================================'
        ''
    )
}

function Get-WaitScreenLines {
    return @(
        ''
        '                          .-.-.'
        '                         (__I__)'
        "                       .'_....._'."
        '                      / / .12 . \ \'
        "                     | | '  |  ' | |"
        '                     | | 9  /  3 | |'
        "                      \ \ '.6.' / /"
        "                       '.``-...-'.'"
        '                        /''-- --''\'
        '                       `"""""""""`'
        ''
        '============================================================'
        '             VERIFYING BACKUP SOURCE STABILITY'
        '============================================================'
        ''
        ('  Backup:      {0}' -f $script:State.LatestBackup)
        ('  Source:      {0}' -f $script:State.SourceFolder)
        ''
        '  The newest backup must remain unchanged before copying.'
        '  Each one-minute check compares:'
        ''
        '      - File count'
        '      - Total folder size'
        '      - Most recent file modification time'
        ''
        '  Three consecutive unchanged checks are required.'
        '  Any detected change resets the stability counter.'
        ''
        '  Maximum wait: 6 hours'
        ''
        '============================================================'
        '    The source folder is only inspected, never modified.'
        '============================================================'
        ''
    )
}

function Get-CopyScreenLines {
    return @(
        ''
        '    .-_                 _-_                 _-_      .'
        '    .   \             /     \             /     \    .'
        '    .    \           /       \           /       \   .'
        '    ._ _ _\ _ _ _ _ / _ _ _ _ \ _ _ _ _ / _ _ _ _ \ _.'
        '    .      \       /           \       /           \ .'
        '    .       \     /             \     /             \.'
        '    .         -_-                 -_-                .'
        ''
        '============================================================'
        '                      COPYING BACKUP'
        '============================================================'
        ''
        ('  Backup:      {0}' -f $script:State.LatestBackup)
        ('  From:        {0}' -f $script:State.SourceFolder)
        ('  To:          {0}' -f $script:State.DestinationFolder)
        ''
        '  Robocopy activity:'
        '============================================================'
        ''
    )
}

function Get-FinalResultPauseLines {
    return @(
        ''
        '                        _______'
        '                      /\       \'
        '                     /()\   ()  \'
        '                    /    \_______\'
        '                    \    /()     /'
        '                     \()/   ()  /'
        '                      \/_____()/'
        ''
        '============================================================'
        '                  PROCESSING HAS FINISHED'
        '============================================================'
        ''
        ''
        '     The active backup operation has stopped processing.'
        '     Review the final result for its completion status.'
        ''
        ''
        '============================================================'
        '         Press any key to view the final result...'
        '============================================================'
        ''
    )
}

function Get-CompleteScreenLines {
    return @(
        ''
        '                                      ##'
        '                                    ####'
        '                                  ####'
        '                                ####'
        '                     ##       ####'
        '                      ##    ####'
        '                       ## ####'
        '                        ####'
        '                         ##'
        ''
        '============================================================'
        '                 BACKUP COMPLETED SUCCESSFULLY'
        '============================================================'
        ''
        ('  Backup:        {0}' -f $script:State.LatestBackup)
        ('  Result:        {0}' -f $script:State.FinalResult)
        ('  Robocopy:      {0}' -f $script:State.RobocopyClass)
        ('  Exit code:     {0}' -f $script:State.RobocopyCode)
        ('  Files copied:  {0}' -f $script:State.FilesCopied)
        ('  Data copied:   {0}' -f $script:State.DataCopied)
        ('  Verification:  {0}' -f $script:State.PostVerifyStatus)
        ('  Verified:      {0} files / {1}' -f $script:State.VerifySourceFiles, $script:State.VerifySourceSize)
        ('  Total time:    {0}' -f $script:State.TotalTime)
        ('  Average speed: {0}' -f $script:State.AverageSpeed)
        ('  Drive free:    {0}' -f $script:State.DestinationFreeDisplay)
        ('  Failures:      {0}' -f $script:State.Failures)
        ''
        '============================================================'
        ('  Log: {0}' -f $script:State.LogFile)
        '============================================================'
    )
}

function Get-WarningCompleteScreenLines {
    $lines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in @(
            ''
            '                        ######'
            '                      ##      ##'
            '                              ##'
            '                           ####'
            '                         ###'
            '                        ##'
            ''
            '                        ##'
            ''
            '============================================================'
            '                 BACKUP COMPLETED WITH WARNING'
            '============================================================'
            ''
            ('  Backup:        {0}' -f $script:State.LatestBackup)
            '  Transfer:      Completed'
            ('  Robocopy:      {0}' -f $script:State.RobocopyClass)
            ('  Exit code:     {0}' -f $script:State.RobocopyCode)
            ''
        )) {
        [void]$lines.Add($line)
    }

    if ($script:State.StaleWarning) {
        foreach ($line in @(
                '  WARNING - SOURCE BACKUP FRESHNESS'
                '  Source backup: STALE'
                ('  Backup age:    {0} hours' -f $script:State.BackupAgeDisplay)
                ('  Maximum age:   {0} hours' -f $script:State.MaximumBackupAgeHours)
                ''
            )) {
            [void]$lines.Add($line)
        }
    }

    if ($script:State.RobocopyWarning) {
        foreach ($line in @(
                '  WARNING - ROBOCOPY DIFFERENCES'
                ('  Details: {0}' -f $script:State.RobocopyDescription)
                ''
            )) {
            [void]$lines.Add($line)
        }
    }

    foreach ($line in @(
            ('  Result:        {0}' -f $script:State.FinalResult)
            ('  Files copied:  {0}' -f $script:State.FilesCopied)
            ('  Data copied:   {0}' -f $script:State.DataCopied)
            ('  Verification:  {0}' -f $script:State.PostVerifyStatus)
            ('  Verified:      {0} files / {1}' -f $script:State.VerifySourceFiles, $script:State.VerifySourceSize)
            ('  Total time:    {0}' -f $script:State.TotalTime)
            ('  Average speed: {0}' -f $script:State.AverageSpeed)
            ('  Drive free:    {0}' -f $script:State.DestinationFreeDisplay)
            ('  Failures:      {0}' -f $script:State.Failures)
            ''
            '============================================================'
            '  The operation completed, but one or more warnings require'
            '  review. See the full log for additional details.'
            '============================================================'
            ('  Log: {0}' -f $script:State.LogFile)
            '============================================================'
        )) {
        [void]$lines.Add($line)
    }

    return $lines.ToArray()
}

function Get-FailScreenLines {
    $lines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in @(
            ''
            '                    ####             ####'
            '                      ####         ####'
            '                        ####     ####'
            '                          #### ####'
            '                            ####'
            '                          #### ####'
            '                        ####     ####'
            '                      ####         ####'
            '                    ####             ####'
            ''
            '============================================================'
            '                        BACKUP FAILED'
            '============================================================'
            ''
            ('  Version:       {0}' -f $script:State.AppVersion)
            ('  Stage:         {0}' -f $script:State.CurrentStage)
            ('  Reason:        {0}' -f $script:State.FailReason)
        )) {
        [void]$lines.Add($line)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:State.FailDetail)) {
        [void]$lines.Add(('  Details:       {0}' -f $script:State.FailDetail))
    }

    [void]$lines.Add(('  Backup:        {0}' -f $script:State.FailBackup))
    [void]$lines.Add(('  Exit code:     {0}' -f $script:State.FailCode))

    if ($null -ne $script:State.RobocopyCode) {
        [void]$lines.Add(('  Robocopy code: {0}' -f $script:State.RobocopyCode))
    }

    if ($script:State.PostVerifyStatus -ne 'Not run') {
        [void]$lines.Add('')
        [void]$lines.Add(('  Verification:  {0}' -f $script:State.PostVerifyStatus))

        if ($script:State.VerifySourceFiles -ne 'Unavailable') {
            [void]$lines.Add(('  Source:        {0} files / {1}' -f $script:State.VerifySourceFiles, $script:State.VerifySourceSize))
            [void]$lines.Add(('  Destination:   {0} files / {1}' -f $script:State.VerifyDestinationFiles, $script:State.VerifyDestinationSize))
            [void]$lines.Add(('  Missing:       {0}' -f $script:State.VerifyMissingFiles))
            [void]$lines.Add(('  Wrong size:    {0}' -f $script:State.VerifyWrongSize))
            [void]$lines.Add(('  Extras:        {0}' -f $script:State.VerifyExtraFiles))
        }
    }

    foreach ($line in @(
            ('  Discord:       {0}' -f $script:State.FailDiscord)
            ''
            '============================================================'
            ('  Log: {0}' -f $script:State.FailLog)
            '============================================================'
        )) {
        [void]$lines.Add($line)
    }

    return $lines.ToArray()
}

function Show-ReadyScreen {
    Write-Screen -Lines (Get-ReadyScreenLines) -ToHost
    Wait-ForKey
}

function Show-FinalResultPause {
    if (-not $script:State.ManualRun) { return }
    if (-not $script:State.TransferAttempted) { return }

    Write-Screen -Lines (Get-FinalResultPauseLines) -ToHost
    Wait-ForKey
}

# -----------------------------------------------------------------------------
# Discord
# -----------------------------------------------------------------------------

function Initialize-DiscordConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Configuration
    )

    $script:State.DiscordWebhook = $null
    $script:State.DiscordEnabled = $false
    $script:State.DiscordConfigWarning = $null

    if (-not $Configuration.ContainsKey('Discord')) {
        $script:State.DiscordConfigWarning =
        'Config.ini does not contain a [Discord] section. Notifications are disabled.'

        return
    }

    $discordSection = $Configuration['Discord']

    if (-not $discordSection.ContainsKey('Webhook')) {
        $script:State.DiscordConfigWarning =
        'Config.ini does not contain [Discord] Webhook. Notifications are disabled.'

        return
    }

    $webhook = [string]$discordSection['Webhook']
    $webhook = $webhook.Trim()

    if ([string]::IsNullOrWhiteSpace($webhook)) {
        $script:State.DiscordConfigWarning =
        'The [Discord] Webhook setting is empty. Notifications are disabled.'

        return
    }

    if (-not (Test-DiscordWebhookFormat -Webhook $webhook)) {
        $script:State.DiscordConfigWarning =
        'The [Discord] Webhook setting does not contain a valid-looking webhook. Notifications are disabled.'

        return
    }

    $script:State.DiscordWebhook = $webhook
    $script:State.DiscordEnabled = $true
}

function Send-DiscordEmbed {
    param(
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][int] $Color,
        [string] $Description,
        [object[]] $Fields = @(),
        [string] $Footer
    )

    if (-not $script:State.DiscordEnabled) {
        return $true
    }

    $script:State.LastDiscordError = $null
    $script:State.LastDiscordResponse = $null

    try {
        # Build ordinary PowerShell arrays and ordered dictionaries so the
        # resulting JSON has exactly the shape Discord expects.
        $fieldObjects = @(
            foreach ($field in @($Fields)) {
                if ($null -eq $field) { continue }

                $name = [string]$field.name
                if ([string]::IsNullOrWhiteSpace($name)) { continue }

                $value = [string]$field.value
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $value = '-'
                }

                [ordered]@{
                    name   = $name
                    value  = $value
                    inline = [bool]$field.inline
                }
            }
        )

        $embed = [ordered]@{
            title     = $Title
            color     = $Color
            timestamp = [DateTime]::UtcNow.ToString('o')
        }

        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $embed['description'] = $Description
        }

        if ($fieldObjects.Count -gt 0) {
            $embed['fields'] = $fieldObjects
        }

        if (-not [string]::IsNullOrWhiteSpace($Footer)) {
            $embed['footer'] = [ordered]@{
                text = $Footer
            }
        }

        $payloadObject = [ordered]@{
            embeds           = @($embed)
            allowed_mentions = [ordered]@{
                parse = @()
            }
        }

        $payload = $payloadObject | ConvertTo-Json -Depth 10 -Compress

        $uri = if ($script:State.DiscordWebhook.Contains('?')) {
            $script:State.DiscordWebhook + '&wait=true'
        }
        else {
            $script:State.DiscordWebhook + '?wait=true'
        }

        # Explicit UTF-8 encoding avoids differences between Windows
        # PowerShell 5.1 and newer PowerShell releases.
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

        Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body $bodyBytes `
            -ErrorAction Stop | Out-Null

        return $true
    }
    catch {
        $messages = New-Object 'System.Collections.Generic.List[string]'

        if (-not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
            [void]$messages.Add($_.Exception.Message)
        }

        if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $script:State.LastDiscordResponse = $_.ErrorDetails.Message
            [void]$messages.Add(('Discord response: {0}' -f $_.ErrorDetails.Message))
        }

        $response = $_.Exception.Response

        if ($null -ne $response) {
            try {
                if ($response.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$response.StatusCode
                    [void]$messages.Add(('HTTP status: {0}' -f $statusCode))
                }
            }
            catch {
                # Status extraction is diagnostic only.
            }

            # PowerShell 7 commonly exposes HttpResponseMessage.Content.
            if ([string]::IsNullOrWhiteSpace($script:State.LastDiscordResponse)) {
                try {
                    if (
                        $response.PSObject.Properties['Content'] -and
                        $null -ne $response.Content -and
                        $response.Content.PSObject.Methods['ReadAsStringAsync']
                    ) {
                        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

                        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                            $script:State.LastDiscordResponse = $responseText
                            [void]$messages.Add(('Discord response: {0}' -f $responseText))
                        }
                    }
                }
                catch {
                    # Response-body extraction is diagnostic only.
                }
            }

            # Windows PowerShell 5.1 commonly exposes GetResponseStream().
            if ([string]::IsNullOrWhiteSpace($script:State.LastDiscordResponse)) {
                try {
                    if ($response.PSObject.Methods['GetResponseStream']) {
                        $stream = $response.GetResponseStream()

                        if ($null -ne $stream) {
                            $reader = New-Object System.IO.StreamReader -ArgumentList $stream
                            try {
                                $responseText = $reader.ReadToEnd()
                            }
                            finally {
                                $reader.Dispose()
                            }

                            if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                                $script:State.LastDiscordResponse = $responseText
                                [void]$messages.Add(('Discord response: {0}' -f $responseText))
                            }
                        }
                    }
                }
                catch {
                    # Response-body extraction is diagnostic only.
                }
            }
        }

        if ($messages.Count -eq 0) {
            [void]$messages.Add('Unknown Discord delivery error.')
        }

        $script:State.LastDiscordError = ($messages -join ' | ')
        return $false
    }
}

function Get-SafeDiscordError {
    $message = [string]$script:State.LastDiscordError

    if ([string]::IsNullOrWhiteSpace($message)) {
        return $null
    }

    # Prevent the webhook credential from appearing in a log if
    # PowerShell includes the request URI in an exception message.
    if (-not [string]::IsNullOrWhiteSpace($script:State.DiscordWebhook)) {
        $message = $message.Replace(
            $script:State.DiscordWebhook,
            '[REDACTED DISCORD WEBHOOK]'
        )
    }

    return $message
}


function Write-DiscordDeliveryFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WarningMessage
    )

    # The general warning is visible in the console and permanent log.
    try {
        Write-Status $WarningMessage
    }
    catch {
        # Discord diagnostics must never interrupt the backup or
        # conceal an existing failure.
        Write-Host $WarningMessage
    }

    # The technical reason is written only to the permanent log.
    $safeError = Get-SafeDiscordError

    if (-not [string]::IsNullOrWhiteSpace($safeError)) {
        try {
            Add-LogLine ('Discord delivery error: {0}' -f $safeError)
        }
        catch {
            # Diagnostic logging is secondary and must remain nonfatal.
        }
    }
}

function Invoke-DiscordTest {
    if (-not $script:State.DiscordEnabled) {
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '                   DISCORD TEST FAILED'
        Write-Host '============================================================'
        Write-Host ''
        Write-Host '  Discord notifications are disabled.'
        Write-Host ''

        if (-not [string]::IsNullOrWhiteSpace(
                $script:State.DiscordConfigWarning
            )) {
            Write-Host '  Reason:'
            Write-Host ('  {0}' -f $script:State.DiscordConfigWarning)
            Write-Host ''
        }

        Write-Host '  Configuration file:'
        Write-Host ('  {0}' -f $script:State.ConfigFile)
        Write-Host ''
        Write-Host '  Required setting:'
        Write-Host '      [Discord]'
        Write-Host '      Webhook=https://discord.com/api/webhooks/...'
        Write-Host ''
        Write-Host '  Exit code: 19'
        Write-Host '============================================================'
        Write-Host ''

        Wait-ForKey `
            -Prompt 'Press any key to close this window...'

        exit 19
    }

    $fields = @(
        (New-DiscordField -Name 'Status' -Value 'Working normally' -Inline $true)
        (New-DiscordField -Name 'Notifications' -Value 'Enabled' -Inline $true)
    )

    $delivered = Send-DiscordEmbed `
        -Title 'Discord Test Successful' `
        -Color 5793266 `
        -Description 'The Appdata Backup webhook is configured and responding.' `
        -Fields $fields `
        -Footer (Get-AppIdentity)

    if (-not $delivered) {
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '                   DISCORD TEST FAILED'
        Write-Host '============================================================'
        Write-Host ''
        Write-Host '  The webhook was loaded, but Discord did not accept the'
        Write-Host '  notification. The webhook may have been deleted, revoked,'
        Write-Host '  or temporarily unavailable.'
        Write-Host ''
        Write-Host '  Exit code: 1'

        $safeError = Get-SafeDiscordError

        if (-not [string]::IsNullOrWhiteSpace($safeError)) {
            Write-Host ''
            Write-Host '  Technical error:'
            Write-Host ('  {0}' -f $safeError)
        }

        Write-Host '============================================================'
        Write-Host ''
        Wait-ForKey -Prompt 'Press any key to close this window...'
        exit 1
    }

    Write-Host ''
    Write-Host '  Discord test embed sent successfully.'
    Write-Host ''
    Wait-ForKey -Prompt 'Press any key to close this window...'
    exit 0
}

# -----------------------------------------------------------------------------
# Configuration and discovery
# -----------------------------------------------------------------------------

function Get-BackupConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Configuration
    )

    if (-not $Configuration.ContainsKey('Backup')) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Config.ini must contain a [Backup] section.'
    }

    $backupSection = $Configuration['Backup']

    $hasSource = $backupSection.ContainsKey('Source')
    $hasTarget = $backupSection.ContainsKey('Target')

    if ($hasSource -and $hasTarget) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Use either [Backup] Source or Target, not both.'
    }

    if (-not $hasSource -and -not $hasTarget) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'The [Backup] section must contain Source or Target.'
    }

    if (-not $backupSection.ContainsKey('Destination')) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'The [Backup] section must contain Destination.'
    }

    $source = if ($hasSource) {
        [string]$backupSection['Source']
    }
    else {
        [string]$backupSection['Target']
    }

    $destination = [string]$backupSection['Destination']

    $source = $source.Trim()
    $destination = $destination.Trim()

    if ([string]::IsNullOrWhiteSpace($source)) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'The [Backup] Source or Target setting is empty.'
    }

    if ([string]::IsNullOrWhiteSpace($destination)) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'The [Backup] Destination setting is empty.'
    }

    if (
        -not (
            $source.StartsWith('\\') -or
            $source -match '^[A-Za-z]:\\'
        )
    ) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Source must be a UNC path or an absolute drive path.'
    }

    if ($destination -notmatch '^[A-Za-z]:\\') {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Destination must begin with a drive letter and backslash, such as E:\APPDATA Backup.'
    }

    if ($source.Length -gt 3) {
        $source = $source.TrimEnd([char]'\')
    }

    if ($destination.Length -gt 3) {
        $destination = $destination.TrimEnd([char]'\')
    }

    if (
        $source.Equals(
            $destination,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Source and Destination cannot be the same path.'
    }

    $driveRoot = [IO.Path]::GetPathRoot($destination)

    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The application configuration is invalid.' `
            -Detail 'Could not determine the destination drive.'
    }

    return [pscustomobject]@{
        SourceRoot       = $source
        DestinationRoot  = $destination
        DestinationDrive = $driveRoot
        LogDirectory     = $destination + ' LOGS'
    }
}

function Get-NewestBackupFolder {
    param([Parameter(Mandatory = $true)][string] $SourceRoot)

    try {
        return Get-ChildItem -LiteralPath $SourceRoot -Directory -ErrorAction Stop |
        Where-Object { $_.Name -match '^ab_\d{8}_\d{6}$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    }
    catch {
        Stop-BackupOperation `
            -Code 12 `
            -Reason 'No successful backup folder was found.' `
            -Detail ('Could not enumerate valid ab_YYYYMMDD_HHMMSS folders in {0}. {1}' -f $SourceRoot, $_.Exception.Message)
    }
}

function Get-BackupFreshness {
    param(
        [Parameter(Mandatory = $true)][string] $BackupName,
        [Parameter(Mandatory = $true)][double] $MaximumAgeHours
    )

    try {
        $stamp = $BackupName.Substring(3)
        $backupTime = [datetime]::ParseExact(
            $stamp,
            'yyyyMMdd_HHmmss',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal
        )

        $ageHours = ((Get-Date) - $backupTime).TotalHours
        if ($ageHours -lt -1) {
            throw 'The backup timestamp is unexpectedly in the future.'
        }

        return [pscustomobject]@{
            AgeDisplay = $ageHours.ToString(
                'F1',
                [Globalization.CultureInfo]::InvariantCulture
            )
            IsStale    = ($ageHours -gt $MaximumAgeHours)
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 21 `
            -Reason 'Could not validate the backup timestamp.' `
            -Detail ('Backup: {0}. {1}' -f `
                $BackupName, `
                $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# Stability, space, transfer, verification, and retention
# -----------------------------------------------------------------------------

function Wait-ForStableBackup {
    param(
        [Parameter(Mandatory = $true)][string] $Folder,
        [int] $StableRequired = 3,
        [int] $IntervalSeconds = 60,
        [int] $MaximumWaitHours = 6
    )

    $stableCount = 0
    $lastSignature = $null
    $deadline = (Get-Date).AddHours($MaximumWaitHours)

    try {
        while ((Get-Date) -lt $deadline) {
            $files = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction Stop)

            [Int64]$totalBytes = 0
            [Int64]$latestWriteTicks = 0

            foreach ($file in $files) {
                $totalBytes += [Int64]$file.Length
                if ($file.LastWriteTimeUtc.Ticks -gt $latestWriteTicks) {
                    $latestWriteTicks = $file.LastWriteTimeUtc.Ticks
                }
            }

            $signature = '{0}|{1}|{2}' -f $files.Count, $totalBytes, $latestWriteTicks

            if (($files.Count -gt 0) -and ($signature -eq $lastSignature)) {
                $stableCount++
            }
            else {
                $stableCount = 0
                $lastSignature = $signature
            }

            $status = 'Backup check: files={0}, size={1:N2} GB, stable={2}/{3}' -f `
                $files.Count,
            ($totalBytes / 1GB),
            $stableCount,
            $StableRequired

            Write-Host $status
            Add-LogLine $status

            if ($stableCount -ge $StableRequired) {
                Add-LogLine 'Backup folder remained unchanged for three minutes. Beginning copy.'
                return
            }

            for ($seconds = $IntervalSeconds; $seconds -gt 0; $seconds--) {
                Write-ConsoleInline ([char]13 + ('Next stability check in {0,2} seconds... ' -f $seconds))
                Start-Sleep -Seconds 1
            }

            Write-ConsoleInline ([char]13 + (' ' * 60) + [char]13)
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 1 `
            -Reason 'Backup completion verification failed.' `
            -Detail ('The stability-check process failed: {0}' -f $_.Exception.Message)
    }

    Add-LogLine 'ERROR: Timed out waiting for the Unraid backup folder to become stable.'
    Stop-BackupOperation `
        -Code 16 `
        -Reason 'Backup completion verification failed.' `
        -Detail 'Timed out waiting for the Unraid backup folder to become stable.'
}

function Get-CopySpaceEstimate {
    param(
        [Parameter(Mandatory = $true)][string] $SourceFolder,
        [Parameter(Mandatory = $true)][string] $DestinationFolder,
        [Parameter(Mandatory = $true)][string] $DestinationDrive,
        [Parameter(Mandatory = $true)][double] $ReserveGB
    )

    try {
        [Int64]$copyBytes = 0
        $sourceFiles = @(Get-ChildItem -LiteralPath $SourceFolder -File -Recurse -Force -ErrorAction Stop)

        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($SourceFolder.Length).TrimStart([char]'\')
            $targetFile = Join-Path -Path $DestinationFolder -ChildPath $relative
            $needsCopy = $true

            if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
                $existing = Get-Item -LiteralPath $targetFile -Force -ErrorAction Stop
                $timeDifference = [math]::Abs(($existing.LastWriteTimeUtc - $file.LastWriteTimeUtc).TotalSeconds)

                if (($existing.Length -eq $file.Length) -and ($timeDifference -le 2)) {
                    $needsCopy = $false
                }
            }

            if ($needsCopy) {
                $copyBytes += [Int64]$file.Length
            }
        }

        $driveName = $DestinationDrive.Substring(0, 1)
        $drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
        [Int64]$availableBytes = $drive.Free
        [Int64]$reserveBytes = $ReserveGB * 1GB
        [Int64]$requiredBytes = if ($copyBytes -gt 0) { $copyBytes + $reserveBytes } else { 0 }

        return [pscustomobject]@{
            CopyBytes        = $copyBytes
            ReserveBytes     = $reserveBytes
            RequiredBytes    = $requiredBytes
            AvailableBytes   = $availableBytes
            EnoughSpace      = ($availableBytes -ge $requiredBytes)
            CopyDisplay      = (Format-ByteCount $copyBytes)
            ReserveDisplay   = (Format-ByteCount $reserveBytes)
            RequiredDisplay  = (Format-ByteCount $requiredBytes)
            AvailableDisplay = (Format-ByteCount $availableBytes)
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 23 `
            -Reason 'Could not determine the required or available destination space.' `
            -Detail $_.Exception.Message
    }
}

function ConvertFrom-RobocopySummary {
    param([Parameter(Mandatory = $true)][string] $RunLog)

    try {
        $lines = @(Get-Content -LiteralPath $RunLog -Encoding Default -ErrorAction Stop)

        $filesLine = $lines | Where-Object { $_ -match '^\s*Files\s*:' } | Select-Object -Last 1
        $bytesLine = $lines | Where-Object { $_ -match '^\s*Bytes\s*:' } | Select-Object -Last 1
        $dirsLine = $lines | Where-Object { $_ -match '^\s*Dirs\s*:' } | Select-Object -Last 1
        $speedLine = $lines | Where-Object { $_ -match '^\s*Speed\s*:\s*[\d,]+\s+Bytes/sec\.' } | Select-Object -Last 1

        $files = if ($filesLine) { @(($filesLine -split ':', 2)[1].Trim() -split '\s{2,}') } else { @() }
        $bytes = if ($bytesLine) { @(($bytesLine -split ':', 2)[1].Trim() -split '\s{2,}') } else { @() }
        $dirs = if ($dirsLine) { @(($dirsLine -split ':', 2)[1].Trim() -split '\s{2,}') } else { @() }

        $filesCopied = if ($files.Count -ge 2) { $files[1] } else { 'Unavailable' }
        $dataCopied = if ($bytes.Count -ge 2) { $bytes[1].ToUpperInvariant() } else { 'Unavailable' }

        $fileFailures = 0
        if ($files.Count -ge 5) {
            $fileFailures = [int](($files[4] -replace ',', ''))
        }

        $directoryFailures = 0
        if ($dirs.Count -ge 5) {
            $directoryFailures = [int](($dirs[4] -replace ',', ''))
        }

        $failures = $fileFailures + $directoryFailures
        $speed = 'Unavailable'

        if ($filesCopied -eq '0') {
            $speed = 'N/A - nothing copied'
        }
        elseif ($speedLine -match '^\s*Speed\s*:\s*([\d,]+)\s+Bytes/sec\.') {
            $bytesPerSecond = [double](($matches[1] -replace ',', ''))
            $speed = '{0:N2} MB/s' -f ($bytesPerSecond / 1MB)
        }

        if ($filesCopied -eq 'Unavailable') {
            Stop-BackupOperation -Code 18 -Reason 'Could not parse the current Robocopy file summary.' -Detail ('Temporary log retained: {0}' -f $RunLog)
        }

        if ($dataCopied -eq 'Unavailable') {
            Stop-BackupOperation -Code 18 -Reason 'Could not parse the copied-data total.' -Detail ('Temporary log retained: {0}' -f $RunLog)
        }

        if ($speed -eq 'Unavailable') {
            Stop-BackupOperation -Code 18 -Reason 'Could not parse the current Robocopy speed.' -Detail ('Temporary log retained: {0}' -f $RunLog)
        }

        return [pscustomobject]@{
            FilesCopied  = $filesCopied
            DataCopied   = $dataCopied
            AverageSpeed = $speed
            Failures     = $failures
        }
    }
    catch {
        if ($_.Exception.Data.Contains('BackupFailureCode')) {
            throw
        }

        Stop-BackupOperation `
            -Code 18 `
            -Reason 'Could not parse the current Robocopy summary.' `
            -Detail ('Temporary log retained: {0}. {1}' -f $RunLog, $_.Exception.Message)
    }
}

function Get-RobocopyClassification {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Code
    )

    $class = 'Success'
    $description = 'Robocopy completed without failures.'
    $warning = $false

    switch ($Code) {
        0 {
            $description =
            'No files needed copying; destination files already matched.'
        }

        1 {
            $description =
            'Files were copied successfully.'
        }

        2 {
            $class = 'Success with extras'
            $description =
            'Extra items exist in the destination; no files were copied.'
        }

        3 {
            $class = 'Success with extras'
            $description =
            'Files were copied and extra destination items were detected.'
        }

        4 {
            $class = 'Warning'
            $description =
            'Mismatched files or directories were detected.'
            $warning = $true
        }

        5 {
            $class = 'Warning'
            $description =
            'Files were copied, but mismatched items were detected.'
            $warning = $true
        }

        6 {
            $class = 'Warning'
            $description =
            'Extra destination items and mismatched items were detected.'
            $warning = $true
        }

        7 {
            $class = 'Warning'
            $description =
            'Files were copied, with extra destination items and mismatches detected.'
            $warning = $true
        }

        default {
            $class = 'Failure'
            $description =
            'Robocopy reported one or more copy failures.'
        }
    }

    return [pscustomobject]@{
        Class       = $class
        Description = $description
        Warning     = $warning
    }
}

function Invoke-PostCopyVerification {
    param(
        [Parameter(Mandatory = $true)][string] $SourceFolder,
        [Parameter(Mandatory = $true)][string] $DestinationFolder
    )

    try {
        $sourceFiles = @(Get-ChildItem -LiteralPath $SourceFolder -File -Recurse -Force -ErrorAction Stop)
        $destinationFiles = @(Get-ChildItem -LiteralPath $DestinationFolder -File -Recurse -Force -ErrorAction Stop)

        $destinationMap = @{}
        [Int64]$destinationBytes = 0

        foreach ($file in $destinationFiles) {
            $relative = $file.FullName.Substring($DestinationFolder.Length).TrimStart([char]'\')
            $destinationMap[$relative] = [Int64]$file.Length
            $destinationBytes += [Int64]$file.Length
        }

        $sourceRelativePaths = @{}
        $missing = New-Object 'System.Collections.Generic.List[string]'
        $wrongSize = New-Object 'System.Collections.Generic.List[string]'
        [Int64]$sourceBytes = 0
        [Int64]$matchedBytes = 0

        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($SourceFolder.Length).TrimStart([char]'\')
            $sourceRelativePaths[$relative] = $true
            $sourceBytes += [Int64]$file.Length

            if (-not $destinationMap.ContainsKey($relative)) {
                [void]$missing.Add($relative)
                continue
            }

            if ([Int64]$destinationMap[$relative] -ne [Int64]$file.Length) {
                [void]$wrongSize.Add($relative)
                continue
            }

            $matchedBytes += [Int64]$file.Length
        }

        $extra = @($destinationMap.Keys | Where-Object { -not $sourceRelativePaths.ContainsKey($_) })
        $match = (
            ($missing.Count -eq 0) -and
            ($wrongSize.Count -eq 0) -and
            ($matchedBytes -eq $sourceBytes)
        )

        $sourceDisplay = Format-ByteCount $sourceBytes
        $destinationDisplay = Format-ByteCount $destinationBytes

        $summary = 'Source: {0} files, {1}; destination: {2} files, {3}; missing: {4}; wrong size: {5}; extras: {6}' -f `
            $sourceFiles.Count,
        $sourceDisplay,
        $destinationFiles.Count,
        $destinationDisplay,
        $missing.Count,
        $wrongSize.Count,
        $extra.Count

        Add-LogLine ('Post-copy verification: ' + $summary)

        if ($missing.Count -gt 0) {
            Add-LogLine 'Missing destination files:'
            foreach ($path in @($missing | Select-Object -First 20)) {
                Add-LogLine ('  ' + $path)
            }
        }

        if ($wrongSize.Count -gt 0) {
            Add-LogLine 'Files with incorrect destination size:'
            foreach ($path in @($wrongSize | Select-Object -First 20)) {
                Add-LogLine ('  ' + $path)
            }
        }

        if ($extra.Count -gt 0) {
            Add-LogLine 'Extra destination files:'
            foreach ($path in @($extra | Select-Object -First 20)) {
                Add-LogLine ('  ' + $path)
            }
        }

        return [pscustomobject]@{
            Match                  = $match
            SourceFiles            = $sourceFiles.Count
            DestinationFiles       = $destinationFiles.Count
            SourceSizeDisplay      = $sourceDisplay
            DestinationSizeDisplay = $destinationDisplay
            MissingFiles           = $missing.Count
            WrongSizeFiles         = $wrongSize.Count
            ExtraFiles             = $extra.Count
            Summary                = $summary
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 25 `
            -Reason 'Post-copy verification could not be completed.' `
            -Detail $_.Exception.Message
    }
}

function Invoke-LocalRetention {
    param(
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [Parameter(Mandatory = $true)][int] $KeepBackups
    )

    try {
        $folders = @(
            Get-ChildItem -LiteralPath $DestinationRoot -Directory -ErrorAction Stop |
            Where-Object { $_.Name -match '^ab_\d{8}_\d{6}$' } |
            Sort-Object Name -Descending
        )

        $oldFolders = @($folders | Select-Object -Skip $KeepBackups)

        foreach ($folder in $oldFolders) {
            Add-LogLine ('Deleting old local backup: ' + $folder.FullName)
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 15 `
            -Reason 'Local retention cleanup failed.' `
            -Detail $_.Exception.Message
    }
}

function Get-DestinationFreeSpaceDisplay {
    try {
        $driveName = $script:State.DestinationDrive.Substring(0, 1)
        $drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
        return (Format-ByteCount ([Int64]$drive.Free))
    }
    catch {
        return 'Unavailable'
    }
}

# -----------------------------------------------------------------------------
# Final Discord messages and centralized failure handling
# -----------------------------------------------------------------------------

function Send-FreshnessWarningEmbed {
    $fields = @(
        (New-DiscordField -Name 'Backup' -Value (Format-DiscordCode $script:State.LatestBackup) -Inline $false)
        (New-DiscordField -Name 'Backup age' -Value (Format-DiscordCode ($script:State.BackupAgeDisplay + ' hours')) -Inline $true)
        (New-DiscordField -Name 'Maximum age' -Value (Format-DiscordCode ($script:State.MaximumBackupAgeHours.ToString([Globalization.CultureInfo]::InvariantCulture) + ' hours')) -Inline $true)
        (New-DiscordField -Name 'Action' -Value (Format-DiscordCode 'Manual run will continue') -Inline $true)
    )

    return Send-DiscordEmbed `
        -Title 'Backup Freshness Warning' `
        -Color 16705372 `
        -Description 'The newest source backup exceeds the configured freshness limit. Because this is a manual run, processing will continue.' `
        -Fields $fields `
        -Footer (Get-AppIdentity)
}

function Send-FinalResultEmbed {
    if ($script:State.CompletionWarning) {
        $fields = New-Object 'System.Collections.Generic.List[object]'

        [void]$fields.Add((New-DiscordField -Name 'Backup' -Value (Format-DiscordCode $script:State.LatestBackup) -Inline $false))
        [void]$fields.Add((New-DiscordField -Name 'Result' -Value (Format-DiscordCode $script:State.FinalResult) -Inline $false))
        [void]$fields.Add((New-DiscordField -Name 'Verification' -Value (Format-DiscordCode ('{0} - {1} files / {2}' -f $script:State.PostVerifyStatus, $script:State.VerifySourceFiles, $script:State.VerifySourceSize)) -Inline $false))
        [void]$fields.Add((New-DiscordField -Name 'Warning summary' -Value $script:State.CompletionWarningReason -Inline $false))

        if ($script:State.StaleWarning) {
            [void]$fields.Add((New-DiscordField -Name 'Source freshness' -Value (Format-DiscordCode 'STALE') -Inline $true))
            [void]$fields.Add((New-DiscordField -Name 'Backup age' -Value (Format-DiscordCode ($script:State.BackupAgeDisplay + ' hours')) -Inline $true))
            [void]$fields.Add((New-DiscordField -Name 'Maximum age' -Value (Format-DiscordCode ($script:State.MaximumBackupAgeHours.ToString([Globalization.CultureInfo]::InvariantCulture) + ' hours')) -Inline $true))
        }

        if ($script:State.RobocopyWarning) {
            [void]$fields.Add((New-DiscordField -Name 'Robocopy' -Value (Format-DiscordCode ('WARNING - exit code {0}' -f $script:State.RobocopyCode)) -Inline $false))
            [void]$fields.Add((New-DiscordField -Name 'Robocopy details' -Value $script:State.RobocopyDescription -Inline $false))
        }

        [void]$fields.Add((New-DiscordField -Name 'Files copied' -Value (Format-DiscordCode $script:State.FilesCopied) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Data copied' -Value (Format-DiscordCode $script:State.DataCopied) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Failures' -Value (Format-DiscordCode $script:State.Failures) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Total time' -Value (Format-DiscordCode $script:State.TotalTime) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Average speed' -Value (Format-DiscordCode $script:State.AverageSpeed) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Drive free' -Value (Format-DiscordCode $script:State.DestinationFreeDisplay) -Inline $true))

        return Send-DiscordEmbed `
            -Title 'Backup Completed with Warning' `
            -Color 16705372 `
            -Description 'The transfer and post-copy verification completed, but one or more warnings require review.' `
            -Fields $fields.ToArray() `
            -Footer ('Robocopy exit code {0} | {1}' -f `
                $script:State.RobocopyCode, `
            (Get-AppIdentity))
    }

    $successFields = @(
        (New-DiscordField -Name 'Backup' -Value (Format-DiscordCode $script:State.LatestBackup) -Inline $false)
        (New-DiscordField -Name 'Result' -Value (Format-DiscordCode $script:State.FinalResult) -Inline $false)
        (New-DiscordField -Name 'Verification' -Value (Format-DiscordCode ('{0} - {1} files / {2}' -f $script:State.PostVerifyStatus, $script:State.VerifySourceFiles, $script:State.VerifySourceSize)) -Inline $false)
        (New-DiscordField -Name 'Files copied' -Value (Format-DiscordCode $script:State.FilesCopied) -Inline $true)
        (New-DiscordField -Name 'Data copied' -Value (Format-DiscordCode $script:State.DataCopied) -Inline $true)
        (New-DiscordField -Name 'Failures' -Value (Format-DiscordCode $script:State.Failures) -Inline $true)
        (New-DiscordField -Name 'Total time' -Value (Format-DiscordCode $script:State.TotalTime) -Inline $true)
        (New-DiscordField -Name 'Average speed' -Value (Format-DiscordCode $script:State.AverageSpeed) -Inline $true)
        (New-DiscordField -Name 'Drive free' -Value (Format-DiscordCode $script:State.DestinationFreeDisplay) -Inline $true)
    )

    return Send-DiscordEmbed `
        -Title 'Backup Completed Successfully' `
        -Color 5763719 `
        -Description 'The backup copy, post-copy verification, and retention process completed successfully.' `
        -Fields $successFields `
        -Footer ('Robocopy exit code {0} | {1}' -f `
            $script:State.RobocopyCode, `
        (Get-AppIdentity))
}

function Invoke-FailurePresentation {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [string] $Detail
    )

    $script:State.FailCode = $Code
    $script:State.FailReason = $(if ([string]::IsNullOrWhiteSpace($Reason)) { 'An unspecified error occurred.' } else { $Reason })
    $script:State.FailDetail = $Detail
    $script:State.FailBackup = $(if ([string]::IsNullOrWhiteSpace($script:State.LatestBackup)) { 'Not selected' } else { $script:State.LatestBackup })
    $script:State.FailLog = $(if ([string]::IsNullOrWhiteSpace($script:State.LogFile)) { 'Not created' } else { $script:State.LogFile })
    $script:State.FailDiscord = 'Disabled'

    if ($script:State.DiscordEnabled) {
        $fields = New-Object 'System.Collections.Generic.List[object]'
        [void]$fields.Add((New-DiscordField -Name 'Stage' -Value (Format-DiscordCode $script:State.CurrentStage) -Inline $false))
        [void]$fields.Add((New-DiscordField -Name 'Reason' -Value $script:State.FailReason -Inline $false))
        [void]$fields.Add((New-DiscordField -Name 'Backup' -Value (Format-DiscordCode $script:State.FailBackup) -Inline $true))
        [void]$fields.Add((New-DiscordField -Name 'Exit code' -Value (Format-DiscordCode $Code) -Inline $true))

        if ($null -ne $script:State.RobocopyCode) {
            [void]$fields.Add((New-DiscordField -Name 'Robocopy exit code' -Value (Format-DiscordCode $script:State.RobocopyCode) -Inline $true))
        }

        if (-not [string]::IsNullOrWhiteSpace($script:State.FailDetail)) {
            [void]$fields.Add((New-DiscordField -Name 'Details' -Value $script:State.FailDetail -Inline $false))
        }

        [void]$fields.Add((New-DiscordField -Name 'Log' -Value (Format-DiscordCode $script:State.FailLog) -Inline $false))

        $delivered = Send-DiscordEmbed `
            -Title 'Backup Failed' `
            -Color 15548997 `
            -Description 'The backup workflow stopped before successful completion.' `
            -Fields $fields.ToArray() `
            -Footer ('{0} | Review the log before running the backup again.' -f `
            (Get-AppIdentity))

        if ($delivered) {
            $script:State.FailDiscord = 'Delivered'
        }
        else {
            $script:State.FailDiscord = 'Failed'

            Write-DiscordDeliveryFailure `
                -WarningMessage 'WARNING: Could not deliver the Discord failure notification.'
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($script:State.LogFile)) {
            Add-LogLine ''
            Add-LogLine ('Backup failed: {0}' -f (Get-DisplayTimestamp))
            Write-Screen -Lines (Get-FailScreenLines) -ToLog
            Add-LogLine ''
        }
    }
    catch {
        # Preserve the original failure even if final log writing also fails.
    }

    Show-FinalResultPause

    Set-BackupWindowTitle 'Unraid Appdata Backup - Failed'
    Clear-BackupHost
    Write-Screen -Lines (Get-FailScreenLines) -ToHost

    if ($script:State.ManualRun) {
        Write-Host ''
        Write-Host '  Full failure details are shown above.'
        Wait-ForKey -Prompt '  Press any key to close this window...'
    }
}

# -----------------------------------------------------------------------------
# Initialization and main workflow
# -----------------------------------------------------------------------------

try {
    # -------------------------------------------------------------------------
    # Initialize the application
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Initialization'

    Test-PolicyConfiguration

    Set-BackupWindowTitle ('{0} v{1} - Starting' -f `
            $script:State.AppName,
        $script:State.AppVersion)

    # Read and parse Config.ini. Interactive launches automatically
    # enter first-run setup when the file is missing, malformed, incomplete,
    # or still contains the packaged placeholder values.
    $iniConfiguration = $null
    $configurationReadReason = $null

    try {
        $iniConfiguration = Import-IniFile `
            -Path $script:State.ConfigFile
    }
    catch {
        if (
            $_.Exception.Data.Contains('BackupFailureCode') -and
            [int]$_.Exception.Data['BackupFailureCode'] -eq 22
        ) {
            $configurationReadReason =
            'Config.ini could not be loaded or parsed.'
        }
        else {
            throw
        }
    }

    if ($null -eq $iniConfiguration) {
        if (-not $script:State.ManualRun) {
            Stop-BackupOperation `
                -Code 22 `
                -Reason 'Initial configuration has not been completed.' `
                -Detail 'Run RUN.cmd manually once to complete first-run setup.'
        }

        Invoke-FirstRunSetup `
            -Reasons @($configurationReadReason)

        $iniConfiguration = Import-IniFile `
            -Path $script:State.ConfigFile
    }
    else {
        $setupStatus = Get-ConfigurationSetupStatus `
            -Configuration $iniConfiguration

        if ($setupStatus.RequiresSetup) {
            if (-not $script:State.ManualRun) {
                Stop-BackupOperation `
                    -Code 22 `
                    -Reason 'Initial configuration has not been completed.' `
                    -Detail 'Run RUN.cmd manually once to replace the packaged or invalid Config.ini values.'
            }

            Invoke-FirstRunSetup `
                -Reasons $setupStatus.Reasons `
                -IsPackagedPlaceholder $setupStatus.IsPackagedPlaceholder

            $iniConfiguration = Import-IniFile `
                -Path $script:State.ConfigFile
        }
    }

    # Recheck the saved file before continuing. This uses the same validators
    # as every later run and prevents setup logic from drifting out of sync.
    $finalSetupStatus = Get-ConfigurationSetupStatus `
        -Configuration $iniConfiguration

    if ($finalSetupStatus.RequiresSetup) {
        Stop-BackupOperation `
            -Code 22 `
            -Reason 'The saved application configuration is invalid.' `
            -Detail ($finalSetupStatus.Reasons -join ' ')
    }

    # Load the optional Discord settings from the parsed INI data.
    Initialize-DiscordConfiguration `
        -Configuration $iniConfiguration

    if (-not [string]::IsNullOrWhiteSpace(
            $script:State.DiscordConfigWarning
        )) {
        Write-Host ''
        Write-Host ('WARNING: {0}' -f `
                $script:State.DiscordConfigWarning)
        Write-Host ''
    }

    # Discord test mode exits from Invoke-DiscordTest and does not
    # continue into the normal backup workflow.
    if ($script:State.TestDiscordMode) {
        Invoke-DiscordTest
    }

    # -------------------------------------------------------------------------
    # Load backup configuration
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Configuration loading'

    $backupConfiguration = Get-BackupConfiguration `
        -Configuration $iniConfiguration

    $script:State.SourceRoot = $backupConfiguration.SourceRoot
    $script:State.DestinationRoot = $backupConfiguration.DestinationRoot
    $script:State.DestinationDrive = $backupConfiguration.DestinationDrive
    $script:State.LogDirectory = $backupConfiguration.LogDirectory

    Clear-BackupHost
    Write-Screen -Lines (Get-StartScreenLines) -ToHost

    # -------------------------------------------------------------------------
    # Validate destination drive and initialize permanent log
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Destination drive validation'

    if (-not (Test-Path -LiteralPath $script:State.DestinationDrive -PathType Container)) {
        Stop-BackupOperation `
            -Code 10 `
            -Reason 'The configured destination drive is unavailable.' `
            -Detail ('Configured destination: {0}' -f $script:State.DestinationRoot)
    }

    $script:State.CurrentStage = 'Log setup'

    try {
        if (-not (Test-Path -LiteralPath $script:State.LogDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:State.LogDirectory -Force -ErrorAction Stop | Out-Null
        }

        $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $script:State.LogFile = Join-Path `
            -Path $script:State.LogDirectory `
            -ChildPath ('Unraid-Appdata-Copy-{0}.log' -f $runStamp)

        [IO.File]::WriteAllText($script:State.LogFile, '', $script:Utf8NoBom)
    }
    catch {
        $script:State.LogFile = $null
        Stop-BackupOperation `
            -Code 13 `
            -Reason 'Could not create the backup log directory or log file.' `
            -Detail $script:State.LogDirectory
    }

    Write-Screen -Lines (Get-StartScreenLines) -ToLog

    if (-not [string]::IsNullOrWhiteSpace($script:State.DiscordConfigWarning)) {
        Add-LogLine ('WARNING: {0}' -f $script:State.DiscordConfigWarning)
    }

    Add-LogLine '============================================================'
    Add-LogLine ('Application: {0}' -f (Get-AppIdentity))
    Add-LogLine ('Latest-backup copy started: {0}' -f (Get-DisplayTimestamp))
    Add-LogLine '============================================================'

    # -------------------------------------------------------------------------
    # Stage 1 - Unraid connection and local destination setup
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Unraid connection'
    Write-Status '[1/7] Destination drive available; checking Unraid connection...'

    if (-not (Test-Path -LiteralPath $script:State.SourceRoot -PathType Container)) {
        Stop-BackupOperation `
            -Code 11 `
            -Reason 'The Unraid backup source is unavailable.' `
            -Detail $script:State.SourceRoot
    }

    $script:State.CurrentStage = 'Destination setup'

    try {
        if (-not (Test-Path -LiteralPath $script:State.DestinationRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $script:State.DestinationRoot -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 14 `
            -Reason 'Could not create the local backup destination.' `
            -Detail $script:State.DestinationRoot
    }

    # -------------------------------------------------------------------------
    # Stage 2 - Discover newest exact backup folder and check freshness
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Backup discovery'
    Write-Status '[2/7] Locating newest successful Unraid backup...'

    $newestBackup = Get-NewestBackupFolder -SourceRoot $script:State.SourceRoot

    if ($null -eq $newestBackup) {
        Stop-BackupOperation `
            -Code 12 `
            -Reason 'No successful backup folder was found.' `
            -Detail ('Expected a folder named ab_YYYYMMDD_HHMMSS in {0}.' -f $script:State.SourceRoot)
    }

    $script:State.LatestBackup = $newestBackup.Name
    $script:State.SourceFolder = Join-Path -Path $script:State.SourceRoot -ChildPath $script:State.LatestBackup
    $script:State.DestinationFolder = Join-Path -Path $script:State.DestinationRoot -ChildPath $script:State.LatestBackup

    Write-Status ('Selected backup: {0}' -f $script:State.LatestBackup)
    Write-Status ('Source: {0}' -f $script:State.SourceFolder)
    Write-Status ('Destination: {0}' -f $script:State.DestinationFolder)

    $script:State.CurrentStage = 'Backup freshness check'
    $freshness = Get-BackupFreshness `
        -BackupName $script:State.LatestBackup `
        -MaximumAgeHours $script:State.MaximumBackupAgeHours

    $script:State.BackupAgeDisplay = $freshness.AgeDisplay

    Write-Status ('Backup age: {0} hours; maximum allowed: {1} hours.' -f `
            $script:State.BackupAgeDisplay,
        $script:State.MaximumBackupAgeHours)

    if ($freshness.IsStale) {
        if (-not $script:State.ManualRun) {
            Stop-BackupOperation `
                -Code 20 `
                -Reason 'The newest successful backup is stale.' `
                -Detail ('Age: {0} hours; maximum allowed: {1} hours.' -f $script:State.BackupAgeDisplay, $script:State.MaximumBackupAgeHours)
        }

        $script:State.CompletionWarning = $true
        $script:State.StaleWarning = $true
        $script:State.CompletionWarningReason = 'The source backup is older than the configured age limit.'

        Write-Status 'WARNING: Newest successful backup is stale, but this manual run will continue.'

        if (-not (Send-FreshnessWarningEmbed)) {
            Write-DiscordDeliveryFailure `
                -WarningMessage 'WARNING: Could not deliver the stale-backup Discord warning.'
        }
    }
    else {
        Write-Status 'Backup freshness check passed.'
    }

    if ($script:State.ManualRun) {
        Show-ReadyScreen
    }

    $script:State.OperationStopwatch = [Diagnostics.Stopwatch]::StartNew()

    # -------------------------------------------------------------------------
    # Stage 3 - Wait for three unchanged one-minute checks
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Backup completion verification'
    Set-BackupWindowTitle ('Unraid Appdata Backup - Verifying Completion Status of {0}' -f $script:State.LatestBackup)
    Clear-BackupHost
    Write-Screen -Lines (Get-WaitScreenLines) -ToHost
    Write-Status '[3/7] Waiting for backup to remain unchanged for 3 minutes...'

    Wait-ForStableBackup -Folder $script:State.SourceFolder
    Add-LogLine ('Backup folder appears complete: {0}' -f (Get-DisplayTimestamp))

    # -------------------------------------------------------------------------
    # Stage 4 - Estimate remaining copy bytes and validate capacity
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Free-space validation'
    Write-Status '[4/7] Checking available destination space...'

    $space = Get-CopySpaceEstimate `
        -SourceFolder $script:State.SourceFolder `
        -DestinationFolder $script:State.DestinationFolder `
        -DestinationDrive $script:State.DestinationDrive `
        -ReserveGB $script:State.FreeSpaceReserveGB

    Write-Status ('Estimated data still requiring copy: {0}.' -f $space.CopyDisplay)
    Write-Status ('Destination free space: {0}; safety reserve: {1}.' -f $space.AvailableDisplay, $space.ReserveDisplay)

    if (-not $space.EnoughSpace) {
        Stop-BackupOperation `
            -Code 24 `
            -Reason 'The configured destination drive does not have enough free space.' `
            -Detail ('Required including reserve: {0}; available: {1}.' -f $space.RequiredDisplay, $space.AvailableDisplay)
    }

    if ($space.CopyBytes -eq 0) {
        Write-Status 'Free-space check passed; no additional file data appears necessary.'
    }
    else {
        Write-Status ('Free-space check passed; required including reserve: {0}.' -f $space.RequiredDisplay)
    }

    # -------------------------------------------------------------------------
    # Stage 5 - Robocopy transfer
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Backup transfer'
    Set-BackupWindowTitle ('Unraid Appdata Backup - Copying {0}' -f $script:State.LatestBackup)
    Write-Status '[5/7] Backup appears stable. Starting transfer...'
    Clear-BackupHost
    Write-Screen -Lines (Get-CopyScreenLines) -ToHost

    $robocopyCommand = Get-Command -Name 'robocopy.exe' -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) {
        Stop-BackupOperation -Code 1 -Reason 'Robocopy is unavailable.' -Detail 'robocopy.exe could not be found on this Windows installation.'
    }

    $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $script:State.RobocopyRunLog = Join-Path `
        -Path $script:State.LogDirectory `
        -ChildPath ('Robocopy-{0}.tmp.log' -f $runStamp)

    $robocopyArguments = @(
        $script:State.SourceFolder
        $script:State.DestinationFolder
        '/E'
        '/COPY:DAT'
        '/DCOPY:DAT'
        '/J'
        '/FFT'
        '/R:2'
        '/W:5'
        '/ETA'
        '/TEE'
        ('/LOG:{0}' -f $script:State.RobocopyRunLog)
    )

    $robocopyPath = $robocopyCommand.Source
    & $robocopyPath @robocopyArguments
    $script:State.RobocopyCode = [int]$LASTEXITCODE
    $script:State.TransferAttempted = $true

    if (-not (Test-Path -LiteralPath $script:State.RobocopyRunLog -PathType Leaf)) {
        Stop-BackupOperation `
            -Code 17 `
            -Reason 'Robocopy did not create its temporary log.' `
            -Detail $script:State.RobocopyRunLog
    }

    try {
        $robocopyText = Get-Content -LiteralPath $script:State.RobocopyRunLog -Raw -Encoding Default -ErrorAction Stop
        Add-LogText $robocopyText
        if (-not $robocopyText.EndsWith([Environment]::NewLine)) {
            Add-LogLine ''
        }
    }
    catch {
        Stop-BackupOperation `
            -Code 17 `
            -Reason 'Robocopy temporary log could not be appended to the permanent log.' `
            -Detail $script:State.RobocopyRunLog
    }

    Add-LogLine ('Robocopy finished: {0}' -f (Get-DisplayTimestamp))
    Add-LogLine ('Robocopy exit code: {0}' -f $script:State.RobocopyCode)

    # Classify the Robocopy result before attempting to parse its
    # summary. A fatal Robocopy code must remain the primary failure
    # even if the incomplete log cannot be parsed.
    $classification = Get-RobocopyClassification `
        -Code $script:State.RobocopyCode

    $script:State.RobocopyClass = $classification.Class
    $script:State.RobocopyDescription = $classification.Description

    # Codes 8 and above represent a fatal Robocopy failure.
    # Stop here and retain the temporary Robocopy log for diagnosis.
    if ($script:State.RobocopyCode -ge 8) {
        $script:State.CurrentStage = 'Backup transfer'
        $script:State.RobocopyClass = 'Failure'
        $script:State.RobocopyDescription =
        'Robocopy reported one or more copy failures.'

        Stop-BackupOperation `
            -Code $script:State.RobocopyCode `
            -Reason 'Robocopy reported a transfer failure.' `
            -Detail ('Robocopy exit code {0}; one or more items could not be copied. Temporary log retained: {1}' -f `
                $script:State.RobocopyCode, `
                $script:State.RobocopyRunLog)
    }

    # Robocopy returned a nonfatal code, so its current-run summary
    # must now be parsed successfully.
    $script:State.CurrentStage = 'Transfer result parsing'

    $summary = ConvertFrom-RobocopySummary `
        -RunLog $script:State.RobocopyRunLog

    $script:State.FilesCopied = $summary.FilesCopied
    $script:State.DataCopied = $summary.DataCopied
    $script:State.AverageSpeed = $summary.AverageSpeed
    $script:State.Failures = $summary.Failures

    # Parsing succeeded, so the temporary Robocopy log is no longer
    # required. Its contents have already been added to the main log.
    Remove-Item `
        -LiteralPath $script:State.RobocopyRunLog `
        -Force `
        -ErrorAction SilentlyContinue

    $script:State.CurrentStage = 'Backup transfer'

    if ($classification.Warning) {
        $script:State.RobocopyWarning = $true
        $script:State.CompletionWarning = $true

        if ($script:State.StaleWarning) {
            $script:State.CompletionWarningReason = 'The backup completed with multiple warnings.'
        }
        else {
            $script:State.CompletionWarningReason = 'Robocopy reported a mismatch warning.'
        }

        Write-Status ('WARNING: Robocopy exit code {0}: {1}' -f $script:State.RobocopyCode, $script:State.RobocopyDescription)
    }
    else {
        Write-Status ('Robocopy result: {0} - exit code {1}.' -f $script:State.RobocopyClass, $script:State.RobocopyCode)
    }

    if ($script:State.FilesCopied -eq '0') {
        Write-Status ('Latest backup was already present; no files needed copying: {0}' -f $script:State.LatestBackup)
    }
    else {
        Write-Status ('Latest backup folder copied successfully: {0}' -f $script:State.LatestBackup)
    }

    # -------------------------------------------------------------------------
    # Stage 6 - Independent path-and-size verification
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Post-copy verification'
    Write-Status '[6/7] Transfer finished; verifying copied backup...'

    $script:State.PostVerifyStatus = 'FAILED'
    $verification = Invoke-PostCopyVerification `
        -SourceFolder $script:State.SourceFolder `
        -DestinationFolder $script:State.DestinationFolder

    $script:State.VerifySourceFiles = $verification.SourceFiles
    $script:State.VerifyDestinationFiles = $verification.DestinationFiles
    $script:State.VerifySourceSize = $verification.SourceSizeDisplay
    $script:State.VerifyDestinationSize = $verification.DestinationSizeDisplay
    $script:State.VerifyMissingFiles = $verification.MissingFiles
    $script:State.VerifyWrongSize = $verification.WrongSizeFiles
    $script:State.VerifyExtraFiles = $verification.ExtraFiles

    if (-not $verification.Match) {
        Stop-BackupOperation `
            -Code 26 `
            -Reason 'The copied backup did not match the source.' `
            -Detail ('Missing files: {0}; wrong-size files: {1}. Source: {2} files, {3}; destination: {4} files, {5}.' -f `
                $verification.MissingFiles,
            $verification.WrongSizeFiles,
            $verification.SourceFiles,
            $verification.SourceSizeDisplay,
            $verification.DestinationFiles,
            $verification.DestinationSizeDisplay)
    }

    $script:State.PostVerifyStatus = 'PASSED'
    Write-Status ('Post-copy verification passed: {0} files totaling {1}.' -f $script:State.VerifySourceFiles, $script:State.VerifySourceSize)

    if ($script:State.VerifyExtraFiles -ne 0) {
        Write-Status ('Verification note: {0} extra destination file(s) were detected and recorded in the log.' -f $script:State.VerifyExtraFiles)
    }

    # -------------------------------------------------------------------------
    # Stage 7 - Local-only retention after verification
    # -------------------------------------------------------------------------

    $script:State.CurrentStage = 'Retention cleanup'
    Set-BackupWindowTitle 'Unraid Appdata Backup - Applying Retention'
    Write-Status ('[7/7] Verification passed; keeping most recent {0} backups...' -f $script:State.KeepBackups)

    Invoke-LocalRetention `
        -DestinationRoot $script:State.DestinationRoot `
        -KeepBackups $script:State.KeepBackups

    Add-LogLine ('Local retention completed successfully: {0}' -f (Get-DisplayTimestamp))

    # -------------------------------------------------------------------------
    # Final free-space and runtime calculations
    # -------------------------------------------------------------------------

    $script:State.DestinationFreeDisplay = Get-DestinationFreeSpaceDisplay

    if ($script:State.DestinationFreeDisplay -eq 'Unavailable') {
        Write-Status 'WARNING: Backup succeeded, but remaining destination space could not be determined.'
    }
    else {
        Write-Status ('Destination free space after completion: {0}.' -f $script:State.DestinationFreeDisplay)
    }

    if ($null -ne $script:State.OperationStopwatch) {
        $script:State.OperationStopwatch.Stop()
        $script:State.TotalTime = Format-Duration $script:State.OperationStopwatch.Elapsed
    }

    $script:State.FinalResult = 'New backup copied successfully'

    if ($script:State.FilesCopied -eq '0') {
        $script:State.FinalResult = 'Already present; no files needed copying'
    }

    if ($script:State.RobocopyWarning) {
        $script:State.FinalResult = 'Transfer completed with differences requiring review'
    }

    if (-not (Send-FinalResultEmbed)) {
        Write-DiscordDeliveryFailure `
            -WarningMessage 'WARNING: Backup succeeded, but the Discord notification failed.'
    }

    # -------------------------------------------------------------------------
    # Log and display final result
    # -------------------------------------------------------------------------

    if ($script:State.CompletionWarning) {
        Set-BackupWindowTitle 'Unraid Appdata Backup - Completed with Warning'
        Write-Status ('Backup copy completed with warning: {0}' -f $script:State.CompletionWarningReason)
        Add-LogLine ('Latest-backup copy finished with warning: {0}' -f (Get-DisplayTimestamp))
        Write-Screen -Lines (Get-WarningCompleteScreenLines) -ToLog
        Add-LogLine ''
    }
    else {
        Set-BackupWindowTitle 'Unraid Appdata Backup - Complete'
        Write-Status 'Backup completed successfully.'
        Add-LogLine ('Latest-backup copy finished successfully: {0}' -f (Get-DisplayTimestamp))
        Write-Screen -Lines (Get-CompleteScreenLines) -ToLog
        Add-LogLine ''
    }

    Show-FinalResultPause

    Clear-BackupHost
    if ($script:State.CompletionWarning) {
        Write-Screen -Lines (Get-WarningCompleteScreenLines) -ToHost
    }
    else {
        Write-Screen -Lines (Get-CompleteScreenLines) -ToHost
    }

    if ($script:State.ManualRun) {
        Write-Host ''
        Write-Host '  Full run details saved to the log above.'
        Wait-ForKey -Prompt '  Press any key to close this window...'
    }

    exit 0
}
catch {
    $failureCode = 1
    $failureReason = 'An unexpected error occurred.'
    $failureDetail = $_.Exception.Message

    if ($_.Exception.Data.Contains('BackupFailureCode')) {
        $failureCode = [int]$_.Exception.Data['BackupFailureCode']
        $failureReason = [string]$_.Exception.Data['BackupFailureReason']
        $failureDetail = [string]$_.Exception.Data['BackupFailureDetail']
    }

    try {
        Invoke-FailurePresentation `
            -Code $failureCode `
            -Reason $failureReason `
            -Detail $failureDetail
    }
    catch {
        # Never allow an error in the presentation layer to hide the original
        # backup failure. This fallback intentionally avoids the screen helper.
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '                FAILURE HANDLER ERROR'
        Write-Host '============================================================'
        Write-Host ''
        Write-Host ('  Original stage:  {0}' -f $script:State.CurrentStage)
        Write-Host ('  Original reason: {0}' -f $failureReason)

        if (-not [string]::IsNullOrWhiteSpace($failureDetail)) {
            Write-Host ('  Original detail: {0}' -f $failureDetail)
        }

        Write-Host ''
        Write-Host ('  Handler error:   {0}' -f $_.Exception.Message)
        Write-Host ('  Exit code:       {0}' -f $failureCode)
        Write-Host '============================================================'
    }

    exit $failureCode
}
