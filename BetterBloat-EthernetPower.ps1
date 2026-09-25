#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
BetterBloat - Ethernet Power Saving Fix
Version: 1.0.0

Safely disables common Ethernet power-saving features when supported by
the installed driver. Unsupported settings are skipped rather than guessed.

Default behavior:
  - Targets physical Ethernet adapters only.
  - Does NOT touch Wi-Fi or virtual adapters.
  - Does NOT alter Wake-on-LAN settings.
  - Disables PCIe Link State Power Management on AC power only.
  - Creates a backup before changing anything.
  - Restarts only adapters that were actually changed.

Optional:
  -AlsoDisableOnBattery  Also turns PCIe Link State Power Management off on battery.
  -NoRestart             Does not restart changed Ethernet adapters.
#>

[CmdletBinding()]
param(
    [switch]$AlsoDisableOnBattery,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "This script only supports Windows."
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script as Administrator."
}

try {
    Import-Module NetAdapter -ErrorAction Stop
}
catch {
    throw "The Windows NetAdapter module is not available: $($_.Exception.Message)"
}

if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) {
    throw "powercfg.exe could not be found."
}

# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------

$script:Changed = 0
$script:AlreadySet = 0
$script:Skipped = 0
$script:Failed = 0
$script:AdapterNeedsRestart = @{}

function Write-OK {
    param([string]$Message)
    $script:AlreadySet++
    Write-Host "  [OK]      $Message" -ForegroundColor Green
}

function Write-Changed {
    param(
        [string]$Message,
        [string]$AdapterName
    )
    $script:Changed++
    if ($AdapterName) {
        $script:AdapterNeedsRestart[$AdapterName] = $true
    }
    Write-Host "  [CHANGED] $Message" -ForegroundColor Green
}

function Write-Skipped {
    param([string]$Message)
    $script:Skipped++
    Write-Host "  [SKIPPED] $Message" -ForegroundColor DarkGray
}

function Write-Failed {
    param([string]$Message)
    $script:Failed++
    Write-Host "  [FAILED]  $Message" -ForegroundColor Red
}

function Normalize-PropertyName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return ([regex]::Replace($Name, "[^A-Za-z0-9]", "")).ToLowerInvariant()
}

# Exact normalized vendor property names that are safe to consider.
# A property is changed only if its driver explicitly exposes
# Disabled / Disable / Off as a valid display value.
$TargetNames = @{
    "energyefficientethernet"       = $true
    "eee"                           = $true
    "advancedeee"                   = $true
    "greenethernet"                 = $true
    "gigabitlite"                   = $true
    "powersavingmode"               = $true
    "powersavemode"                 = $true
    "autodisablegigabit"            = $true
    "autodisablegigabitpowersaving" = $true
    "reducespeedonpowerdown"        = $true
    "dmacoalescing"                 = $true
}

function Get-AspmState {
    try {
        $SchemeOutput = (& powercfg.exe /getactivescheme 2>&1 | Out-String)

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $GuidMatch = [regex]::Match(
            $SchemeOutput,
            "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )

        if (-not $GuidMatch.Success) {
            return $null
        }

        $QueryOutput = (& powercfg.exe /query SCHEME_CURRENT SUB_PCIEXPRESS ASPM 2>&1 | Out-String)

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $Indexes = [regex]::Matches($QueryOutput, "0x([0-9A-Fa-f]{8})")

        if ($Indexes.Count -lt 2) {
            return $null
        }

        $AC = [Convert]::ToUInt32(
            $Indexes[$Indexes.Count - 2].Groups[1].Value,
            16
        )

        $DC = [Convert]::ToUInt32(
            $Indexes[$Indexes.Count - 1].Groups[1].Value,
            16
        )

        return [PSCustomObject]@{
            SchemeGuid = $GuidMatch.Value
            AC         = $AC
            DC         = $DC
        }
    }
    catch {
        return $null
    }
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " BetterBloat - Ethernet Power Saving Fix v1.0.0" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------
# Physical Ethernet only
# InterfaceType 6 = Ethernet
# ---------------------------------------------------------------------

try {
    $Adapters = @(
        Get-NetAdapter -Name "*" -Physical -ErrorAction Stop |
        Where-Object { $_.InterfaceType -eq 6 }
    )
}
catch {
    throw "Unable to enumerate network adapters: $($_.Exception.Message)"
}

if ($Adapters.Count -eq 0) {
    Write-Host "No physical Ethernet adapters were found." -ForegroundColor Yellow
    exit 0
}

Write-Host "Physical Ethernet adapter(s):" -ForegroundColor Cyan
foreach ($Adapter in $Adapters) {
    Write-Host "  $($Adapter.Name) - $($Adapter.InterfaceDescription)"
}

# ---------------------------------------------------------------------
# Read current settings before changing anything
# ---------------------------------------------------------------------

$AdapterStates = @()

foreach ($Adapter in $Adapters) {
    $AdvancedProperties = @()
    $PowerManagement = $null

    try {
        $AdvancedProperties = @(
            Get-NetAdapterAdvancedProperty `
                -Name $Adapter.Name `
                -AllProperties `
                -ErrorAction Stop
        )
    }
    catch {
        Write-Host ""
        Write-Host "Warning: Could not read advanced properties for $($Adapter.Name)." `
            -ForegroundColor Yellow
    }

    try {
        $PowerManagement = Get-NetAdapterPowerManagement `
            -Name $Adapter.Name `
            -ErrorAction Stop
    }
    catch {
        Write-Host ""
        Write-Host "Warning: Could not read power-management properties for $($Adapter.Name)." `
            -ForegroundColor Yellow
    }

    $AdapterStates += [PSCustomObject]@{
        Adapter            = $Adapter
        AdvancedProperties = $AdvancedProperties
        PowerManagement    = $PowerManagement
    }
}

$AspmBefore = Get-AspmState

# ---------------------------------------------------------------------
# Backup BEFORE changes
# ---------------------------------------------------------------------

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDirectory = Join-Path `
    $env:ProgramData `
    "BetterBloat\EthernetPowerBackups\$Timestamp"

try {
    New-Item -ItemType Directory -Path $BackupDirectory -Force -ErrorAction Stop |
        Out-Null
}
catch {
    throw "Could not create the backup directory. No changes were made: $($_.Exception.Message)"
}

$BackupAdapters = @()

foreach ($State in $AdapterStates) {
    $Adapter = $State.Adapter
    $RelevantProperties = @()

    foreach ($Property in $State.AdvancedProperties) {
        $Normalized = Normalize-PropertyName $Property.DisplayName

        $IsTarget =
            ($Property.RegistryKeyword -ceq "*EEE") -or
            $TargetNames.ContainsKey($Normalized)

        if (-not $IsTarget) {
            continue
        }

        $RelevantProperties += [PSCustomObject]@{
            DisplayName     = $Property.DisplayName
            DisplayValue    = $Property.DisplayValue
            RegistryKeyword = $Property.RegistryKeyword
            RegistryValue   = @($Property.RegistryValue)
        }
    }

    $PMBackup = $null

    if ($null -ne $State.PowerManagement) {
        $PMBackup = [ordered]@{}

        foreach ($Setting in @(
            "SelectiveSuspend",
            "DeviceSleepOnDisconnect",
            "D0PacketCoalescing",
            "AllowComputerToTurnOffDevice"
        )) {
            if ($State.PowerManagement.PSObject.Properties.Name -contains $Setting) {
                $PMBackup[$Setting] = "$($State.PowerManagement.$Setting)"
            }
        }
    }

    $BackupAdapters += [PSCustomObject]@{
        Name                 = $Adapter.Name
        InterfaceDescription = $Adapter.InterfaceDescription
        OriginalStatus       = "$($Adapter.Status)"
        AdvancedProperties   = $RelevantProperties
        PowerManagement      = $PMBackup
    }
}

$BackupObject = [ordered]@{
    Version  = 1
    Created  = (Get-Date).ToString("o")
    Computer = $env:COMPUTERNAME

    PCIeASPM = if ($null -ne $AspmBefore) {
        [ordered]@{
            SchemeGuid = $AspmBefore.SchemeGuid
            AC         = $AspmBefore.AC
            DC         = $AspmBefore.DC
        }
    }
    else {
        $null
    }

    Adapters = $BackupAdapters
}

$BackupFile = Join-Path $BackupDirectory "original-settings.json"

try {
    $BackupObject |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $BackupFile -Encoding UTF8 -ErrorAction Stop
}
catch {
    Remove-Item -Path $BackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    throw "Backup could not be written. No changes were made."
}

Write-Host ""
Write-Host "Backup created:" -ForegroundColor Cyan
Write-Host "  $BackupFile"
Write-Host ""

# ---------------------------------------------------------------------
# Advanced NIC properties
# ---------------------------------------------------------------------

foreach ($State in $AdapterStates) {
    $Adapter = $State.Adapter

    Write-Host "------------------------------------------------------"
    Write-Host "$($Adapter.Name)" -ForegroundColor Cyan
    Write-Host "$($Adapter.InterfaceDescription)" -ForegroundColor DarkGray
    Write-Host ""

    foreach ($Property in $State.AdvancedProperties) {
        $Normalized = Normalize-PropertyName $Property.DisplayName

        $IsStandardEEE = ($Property.RegistryKeyword -ceq "*EEE")
        $IsNamedTarget = $TargetNames.ContainsKey($Normalized)

        if (-not ($IsStandardEEE -or $IsNamedTarget)) {
            continue
        }

        # Microsoft standardized *EEE:
        # Registry value 0 = disabled, 1 = enabled.
        if ($IsStandardEEE) {
            $CurrentRegistryValue = @($Property.RegistryValue) | Select-Object -First 1

            if ("$CurrentRegistryValue" -eq "0") {
                Write-OK "Energy Efficient Ethernet already disabled"
                continue
            }

            try {
                Set-NetAdapterAdvancedProperty `
                    -InputObject $Property `
                    -RegistryValue "0" `
                    -NoRestart `
                    -ErrorAction Stop

                $Verify = @(
                    Get-NetAdapterAdvancedProperty `
                        -Name $Adapter.Name `
                        -AllProperties `
                        -ErrorAction Stop |
                    Where-Object { $_.RegistryKeyword -ceq "*EEE" }
                ) | Select-Object -First 1

                $VerifiedValue = @($Verify.RegistryValue) | Select-Object -First 1

                if ("$VerifiedValue" -eq "0") {
                    Write-Changed `
                        "Energy Efficient Ethernet -> Disabled" `
                        $Adapter.Name
                }
                else {
                    Write-Failed "Energy Efficient Ethernet verification failed"
                }
            }
            catch {
                Write-Failed "Energy Efficient Ethernet: $($_.Exception.Message)"
            }

            continue
        }

        # Vendor-specific property:
        # Never assume a numeric registry value means Disabled.
        # Only use an explicit Disabled / Disable / Off value exposed by the driver.
        $ValidValues = @($Property.ValidDisplayValues)

        $DisableValue = $ValidValues |
            Where-Object { "$_" -match "^(Disabled|Disable|Off)$" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace("$DisableValue")) {
            Write-Skipped `
                "$($Property.DisplayName) - driver exposes no explicit Disabled/Off value"
            continue
        }

        if ("$($Property.DisplayValue)" -ieq "$DisableValue") {
            Write-OK "$($Property.DisplayName) already disabled"
            continue
        }

        try {
            Set-NetAdapterAdvancedProperty `
                -InputObject $Property `
                -DisplayValue "$DisableValue" `
                -NoRestart `
                -ErrorAction Stop

            $Verify = @(
                Get-NetAdapterAdvancedProperty `
                    -Name $Adapter.Name `
                    -AllProperties `
                    -ErrorAction Stop |
                Where-Object {
                    $_.RegistryKeyword -ceq $Property.RegistryKeyword
                }
            ) | Select-Object -First 1

            if (
                $null -ne $Verify -and
                "$($Verify.DisplayValue)" -ieq "$DisableValue"
            ) {
                Write-Changed `
                    "$($Property.DisplayName) -> $DisableValue" `
                    $Adapter.Name
            }
            else {
                Write-Failed "$($Property.DisplayName) verification failed"
            }
        }
        catch {
            Write-Failed "$($Property.DisplayName): $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------
    # NDIS power-saving features
    # -----------------------------------------------------------------

    foreach ($Setting in @(
        "SelectiveSuspend",
        "DeviceSleepOnDisconnect",
        "D0PacketCoalescing"
    )) {
        try {
            $PM = Get-NetAdapterPowerManagement `
                -Name $Adapter.Name `
                -ErrorAction Stop

            if ($PM.PSObject.Properties.Name -notcontains $Setting) {
                Write-Skipped "$Setting - unavailable"
                continue
            }

            $Current = "$($PM.$Setting)"

            if ($Current -eq "Unsupported") {
                Write-Skipped "$Setting - unsupported"
                continue
            }

            if ($Current -eq "Disabled") {
                Write-OK "$Setting already disabled"
                continue
            }

            $Parameters = @{
                Name        = $Adapter.Name
                NoRestart   = $true
                ErrorAction = "Stop"
            }

            $Parameters[$Setting] = "Disabled"
            Set-NetAdapterPowerManagement @Parameters

            $Verify = Get-NetAdapterPowerManagement `
                -Name $Adapter.Name `
                -ErrorAction Stop

            if ("$($Verify.$Setting)" -eq "Disabled") {
                Write-Changed "$Setting -> Disabled" $Adapter.Name
            }
            else {
                Write-Failed "$Setting verification failed"
            }
        }
        catch {
            Write-Failed "$Setting: $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------
    # Device Manager:
    # "Allow the computer to turn off this device to save power"
    # -----------------------------------------------------------------

    try {
        $PM = Get-NetAdapterPowerManagement `
            -Name $Adapter.Name `
            -ErrorAction Stop

        if ($PM.PSObject.Properties.Name -notcontains "AllowComputerToTurnOffDevice") {
            Write-Skipped "Allow computer to turn off device - unavailable"
        }
        else {
            $Current = "$($PM.AllowComputerToTurnOffDevice)"

            if ($Current -eq "Unsupported") {
                Write-Skipped "Allow computer to turn off device - unsupported"
            }
            elseif ($Current -eq "Disabled") {
                Write-OK "Allow computer to turn off device already disabled"
            }
            else {
                $PM.AllowComputerToTurnOffDevice = "Disabled"

                $PM |
                    Set-NetAdapterPowerManagement `
                        -NoRestart `
                        -ErrorAction Stop

                $Verify = Get-NetAdapterPowerManagement `
                    -Name $Adapter.Name `
                    -ErrorAction Stop

                if ("$($Verify.AllowComputerToTurnOffDevice)" -eq "Disabled") {
                    Write-Changed `
                        "Allow computer to turn off device -> Disabled" `
                        $Adapter.Name
                }
                else {
                    Write-Failed "Allow computer to turn off device verification failed"
                }
            }
        }
    }
    catch {
        Write-Failed "Allow computer to turn off device: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# PCI Express Link State Power Management
#
# This is SYSTEM-WIDE PCIe ASPM, not Ethernet-only.
# AC is disabled by default.
# Battery is unchanged unless -AlsoDisableOnBattery is explicitly used.
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "------------------------------------------------------"
Write-Host "PCI Express Link State Power Management" -ForegroundColor Cyan
Write-Host ""

if ($null -eq $AspmBefore) {
    Write-Skipped `
        "PCIe ASPM - current state could not be backed up, so it was not changed"
}
else {
    try {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 |
            Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "powercfg returned exit code $LASTEXITCODE while changing AC."
        }

        if ($AlsoDisableOnBattery) {
            & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 |
                Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "powercfg returned exit code $LASTEXITCODE while changing battery."
            }
        }

        & powercfg.exe /setactive SCHEME_CURRENT | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to reactivate the current power scheme."
        }

        $AspmAfter = Get-AspmState

        if ($null -eq $AspmAfter) {
            Write-Failed "PCIe ASPM could not be verified"
        }
        else {
            if ($AspmAfter.AC -eq 0) {
                if ($AspmBefore.AC -eq 0) {
                    Write-OK "PCIe Link State Power Management (AC) already Off"
                }
                else {
                    $script:Changed++
                    Write-Host `
                        "  [CHANGED] PCIe Link State Power Management (AC) -> Off" `
                        -ForegroundColor Green
                }
            }
            else {
                Write-Failed "PCIe Link State Power Management (AC) verification failed"
            }

            if ($AlsoDisableOnBattery) {
                if ($AspmAfter.DC -eq 0) {
                    if ($AspmBefore.DC -eq 0) {
                        Write-OK "PCIe Link State Power Management (Battery) already Off"
                    }
                    else {
                        $script:Changed++
                        Write-Host `
                            "  [CHANGED] PCIe Link State Power Management (Battery) -> Off" `
                            -ForegroundColor Green
                    }
                }
                else {
                    Write-Failed "PCIe Link State Power Management (Battery) verification failed"
                }
            }
            else {
                Write-Host `
                    "  [UNCHANGED] Battery PCIe setting (safer default for laptops)" `
                    -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Failed "PCIe ASPM: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# Restart only adapters that were actually changed
# ---------------------------------------------------------------------

if ($NoRestart) {
    if ($script:AdapterNeedsRestart.Count -gt 0) {
        Write-Host ""
        Write-Host "Adapter restart skipped." -ForegroundColor Yellow
        Write-Host "A reboot may be required for every setting to take effect." `
            -ForegroundColor Yellow
    }
}
elseif ($script:AdapterNeedsRestart.Count -gt 0) {
    Write-Host ""
    Write-Host "Restarting changed Ethernet adapter(s)..." -ForegroundColor Cyan

    foreach ($State in $AdapterStates) {
        $Adapter = $State.Adapter

        if (-not $script:AdapterNeedsRestart.ContainsKey($Adapter.Name)) {
            continue
        }

        # Never accidentally enable an adapter that was already disabled.
        if ("$($Adapter.Status)" -notin @("Up", "Disconnected")) {
            Write-Host `
                "  [NOT RESTARTED] $($Adapter.Name) - original state: $($Adapter.Status)" `
                -ForegroundColor DarkGray
            continue
        }

        try {
            Restart-NetAdapter `
                -Name $Adapter.Name `
                -Confirm:$false `
                -ErrorAction Stop

            Write-Host "  [RESTARTED] $($Adapter.Name)" -ForegroundColor Green
        }
        catch {
            Write-Host `
                "  [REBOOT MAY BE REQUIRED] $($Adapter.Name)" `
                -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Complete" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Changed:      $script:Changed" -ForegroundColor Green
Write-Host "Already set:  $script:AlreadySet"
Write-Host "Skipped:      $script:Skipped" -ForegroundColor DarkGray

if ($script:Failed -eq 0) {
    Write-Host "Failed:       0" -ForegroundColor Green
}
else {
    Write-Host "Failed:       $script:Failed" -ForegroundColor Red
}

Write-Host ""
Write-Host "Backup:" -ForegroundColor Cyan
Write-Host "  $BackupFile"
Write-Host ""
Write-Host "Ethernet may take a few seconds to reconnect."
Write-Host ""

if ($script:Failed -gt 0) {
    exit 1
}

exit 0
