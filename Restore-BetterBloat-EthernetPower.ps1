#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
BetterBloat - Restore Ethernet Power Settings
Version: 1.0.0

Restores settings saved by BetterBloat-EthernetPower.ps1.

By default, restores the newest backup from:
  C:\ProgramData\BetterBloat\EthernetPowerBackups\

Optional:
  -BackupPath "C:\...\original-settings.json"
  -NoRestart
#>

[CmdletBinding()]
param(
    [string]$BackupPath,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

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

$script:Restored = 0
$script:Skipped = 0
$script:Failed = 0
$script:AdapterNeedsRestart = @{}

function Write-Restored {
    param(
        [string]$Message,
        [string]$AdapterName
    )

    $script:Restored++

    if ($AdapterName) {
        $script:AdapterNeedsRestart[$AdapterName] = $true
    }

    Write-Host "  [RESTORED] $Message" -ForegroundColor Green
}

function Write-Skipped {
    param([string]$Message)
    $script:Skipped++
    Write-Host "  [SKIPPED]  $Message" -ForegroundColor DarkGray
}

function Write-Failed {
    param([string]$Message)
    $script:Failed++
    Write-Host "  [FAILED]   $Message" -ForegroundColor Red
}

function Get-ActiveSchemeGuid {
    try {
        $Output = (& powercfg.exe /getactivescheme 2>&1 | Out-String)

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $Match = [regex]::Match(
            $Output,
            "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )

        if ($Match.Success) {
            return $Match.Value
        }

        return $null
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------
# Find backup
# ---------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupRoot = Join-Path $env:ProgramData "BetterBloat\EthernetPowerBackups"

    if (-not (Test-Path $BackupRoot)) {
        throw "No BetterBloat Ethernet backup directory was found."
    }

    $LatestBackup = Get-ChildItem `
        -Path $BackupRoot `
        -Directory `
        -ErrorAction Stop |
        Sort-Object Name -Descending |
        ForEach-Object {
            $Candidate = Join-Path $_.FullName "original-settings.json"

            if (Test-Path $Candidate) {
                Get-Item $Candidate
            }
        } |
        Select-Object -First 1

    if ($null -eq $LatestBackup) {
        throw "No BetterBloat Ethernet backup file was found."
    }

    $BackupPath = $LatestBackup.FullName
}

if (-not (Test-Path $BackupPath -PathType Leaf)) {
    throw "Backup file not found: $BackupPath"
}

try {
    $Backup = Get-Content `
        -Path $BackupPath `
        -Raw `
        -Encoding UTF8 `
        -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Could not read the backup file: $($_.Exception.Message)"
}

if ($Backup.Version -ne 1) {
    throw "Unsupported backup format version: $($Backup.Version)"
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " BetterBloat - Restore Ethernet Power Settings" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Backup:" -ForegroundColor Cyan
Write-Host "  $BackupPath"
Write-Host ""

# ---------------------------------------------------------------------
# Restore adapter settings
# ---------------------------------------------------------------------

foreach ($SavedAdapter in @($Backup.Adapters)) {
    $Adapter = $null

    # Prefer the saved interface name.
    try {
        $Adapter = Get-NetAdapter `
            -Name "$($SavedAdapter.Name)" `
            -Physical `
            -ErrorAction Stop
    }
    catch {
        $Adapter = $null
    }

    # Fall back to exact interface description if the user renamed it.
    if ($null -eq $Adapter) {
        $Adapter = @(
            Get-NetAdapter -Name "*" -Physical -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceType -eq 6 -and
                $_.InterfaceDescription -eq "$($SavedAdapter.InterfaceDescription)"
            }
        ) | Select-Object -First 1
    }

    if ($null -eq $Adapter -or $Adapter.InterfaceType -ne 6) {
        Write-Skipped `
            "$($SavedAdapter.Name) - matching physical Ethernet adapter not found"
        continue
    }

    Write-Host "------------------------------------------------------"
    Write-Host "$($Adapter.Name)" -ForegroundColor Cyan
    Write-Host "$($Adapter.InterfaceDescription)" -ForegroundColor DarkGray
    Write-Host ""

    # -----------------------------------------------------------------
    # Advanced properties
    # -----------------------------------------------------------------

    foreach ($SavedProperty in @($SavedAdapter.AdvancedProperties)) {
        try {
            $CurrentProperty = @(
                Get-NetAdapterAdvancedProperty `
                    -Name $Adapter.Name `
                    -AllProperties `
                    -ErrorAction Stop |
                Where-Object {
                    $_.RegistryKeyword -ceq "$($SavedProperty.RegistryKeyword)"
                }
            ) | Select-Object -First 1

            if ($null -eq $CurrentProperty) {
                Write-Skipped `
                    "$($SavedProperty.DisplayName) - property no longer exists"
                continue
            }

            $SavedRegistryValues = @(
                $SavedProperty.RegistryValue |
                ForEach-Object { "$_" }
            )

            if ($SavedRegistryValues.Count -gt 0) {
                Set-NetAdapterAdvancedProperty `
                    -InputObject $CurrentProperty `
                    -RegistryValue $SavedRegistryValues `
                    -NoRestart `
                    -ErrorAction Stop

                $Verify = @(
                    Get-NetAdapterAdvancedProperty `
                        -Name $Adapter.Name `
                        -AllProperties `
                        -ErrorAction Stop |
                    Where-Object {
                        $_.RegistryKeyword -ceq "$($SavedProperty.RegistryKeyword)"
                    }
                ) | Select-Object -First 1

                $Expected = ($SavedRegistryValues -join "`0")
                $Actual = (@($Verify.RegistryValue | ForEach-Object { "$_" }) -join "`0")

                if ($Expected -ceq $Actual) {
                    Write-Restored "$($SavedProperty.DisplayName)" $Adapter.Name
                }
                else {
                    Write-Failed "$($SavedProperty.DisplayName) verification failed"
                }

                continue
            }

            # Fallback only if the driver still explicitly exposes the old display value.
            $SavedDisplayValue = "$($SavedProperty.DisplayValue)"
            $ValidDisplayValues = @($CurrentProperty.ValidDisplayValues)

            if (
                -not [string]::IsNullOrWhiteSpace($SavedDisplayValue) -and
                ($ValidDisplayValues -icontains $SavedDisplayValue)
            ) {
                Set-NetAdapterAdvancedProperty `
                    -InputObject $CurrentProperty `
                    -DisplayValue $SavedDisplayValue `
                    -NoRestart `
                    -ErrorAction Stop

                Write-Restored "$($SavedProperty.DisplayName)" $Adapter.Name
            }
            else {
                Write-Skipped `
                    "$($SavedProperty.DisplayName) - original value is no longer exposed by the driver"
            }
        }
        catch {
            Write-Failed "$($SavedProperty.DisplayName): $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------
    # NDIS power-management settings
    # -----------------------------------------------------------------

    if ($null -ne $SavedAdapter.PowerManagement) {
        foreach ($Setting in @(
            "SelectiveSuspend",
            "DeviceSleepOnDisconnect",
            "D0PacketCoalescing"
        )) {
            if ($SavedAdapter.PowerManagement.PSObject.Properties.Name -notcontains $Setting) {
                continue
            }

            $OriginalValue = "$($SavedAdapter.PowerManagement.$Setting)"

            if ($OriginalValue -notin @("Enabled", "Disabled")) {
                Write-Skipped "$Setting - saved state was $OriginalValue"
                continue
            }

            try {
                $PM = Get-NetAdapterPowerManagement `
                    -Name $Adapter.Name `
                    -ErrorAction Stop

                if (
                    $PM.PSObject.Properties.Name -notcontains $Setting -or
                    "$($PM.$Setting)" -eq "Unsupported"
                ) {
                    Write-Skipped "$Setting - unsupported"
                    continue
                }

                if ("$($PM.$Setting)" -eq $OriginalValue) {
                    Write-Skipped "$Setting - already at original value"
                    continue
                }

                $Parameters = @{
                    Name        = $Adapter.Name
                    NoRestart   = $true
                    ErrorAction = "Stop"
                }

                $Parameters[$Setting] = $OriginalValue

                Set-NetAdapterPowerManagement @Parameters

                $Verify = Get-NetAdapterPowerManagement `
                    -Name $Adapter.Name `
                    -ErrorAction Stop

                if ("$($Verify.$Setting)" -eq $OriginalValue) {
                    Write-Restored "$Setting -> $OriginalValue" $Adapter.Name
                }
                else {
                    Write-Failed "$Setting verification failed"
                }
            }
            catch {
                Write-Failed "$Setting: $($_.Exception.Message)"
            }
        }

        # Device Manager checkbox
        if (
            $SavedAdapter.PowerManagement.PSObject.Properties.Name `
                -contains "AllowComputerToTurnOffDevice"
        ) {
            $OriginalValue =
                "$($SavedAdapter.PowerManagement.AllowComputerToTurnOffDevice)"

            if ($OriginalValue -in @("Enabled", "Disabled")) {
                try {
                    $PM = Get-NetAdapterPowerManagement `
                        -Name $Adapter.Name `
                        -ErrorAction Stop

                    if (
                        $PM.PSObject.Properties.Name `
                            -contains "AllowComputerToTurnOffDevice" -and
                        "$($PM.AllowComputerToTurnOffDevice)" -ne "Unsupported"
                    ) {
                        if ("$($PM.AllowComputerToTurnOffDevice)" -ne $OriginalValue) {
                            $PM.AllowComputerToTurnOffDevice = $OriginalValue

                            $PM |
                                Set-NetAdapterPowerManagement `
                                    -NoRestart `
                                    -ErrorAction Stop

                            $Verify = Get-NetAdapterPowerManagement `
                                -Name $Adapter.Name `
                                -ErrorAction Stop

                            if (
                                "$($Verify.AllowComputerToTurnOffDevice)" `
                                    -eq $OriginalValue
                            ) {
                                Write-Restored `
                                    "Allow computer to turn off device -> $OriginalValue" `
                                    $Adapter.Name
                            }
                            else {
                                Write-Failed `
                                    "Allow computer to turn off device verification failed"
                            }
                        }
                        else {
                            Write-Skipped `
                                "Allow computer to turn off device - already at original value"
                        }
                    }
                    else {
                        Write-Skipped `
                            "Allow computer to turn off device - unsupported"
                    }
                }
                catch {
                    Write-Failed `
                        "Allow computer to turn off device: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ---------------------------------------------------------------------
# Restore PCIe Link State Power Management to the saved values
# ---------------------------------------------------------------------

if ($null -ne $Backup.PCIeASPM) {
    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "PCI Express Link State Power Management" -ForegroundColor Cyan
    Write-Host ""

    try {
        $SchemeGuid = "$($Backup.PCIeASPM.SchemeGuid)"
        $AC = [int]$Backup.PCIeASPM.AC
        $DC = [int]$Backup.PCIeASPM.DC

        & powercfg.exe /setacvalueindex $SchemeGuid SUB_PCIEXPRESS ASPM $AC |
            Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Could not restore the AC PCIe setting."
        }

        & powercfg.exe /setdcvalueindex $SchemeGuid SUB_PCIEXPRESS ASPM $DC |
            Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Could not restore the battery PCIe setting."
        }

        $ActiveScheme = Get-ActiveSchemeGuid

        if (
            $null -ne $ActiveScheme -and
            $ActiveScheme -ieq $SchemeGuid
        ) {
            & powercfg.exe /setactive $SchemeGuid | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Could not refresh the active power scheme."
            }
        }

        $script:Restored++
        Write-Host `
            "  [RESTORED] PCIe Link State Power Management (AC/DC)" `
            -ForegroundColor Green
    }
    catch {
        Write-Failed "PCIe ASPM: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# Restart changed adapters only
# ---------------------------------------------------------------------

if ($NoRestart) {
    if ($script:AdapterNeedsRestart.Count -gt 0) {
        Write-Host ""
        Write-Host "Adapter restart skipped." -ForegroundColor Yellow
        Write-Host "A reboot may be required for every restored setting to take effect." `
            -ForegroundColor Yellow
    }
}
elseif ($script:AdapterNeedsRestart.Count -gt 0) {
    Write-Host ""
    Write-Host "Restarting restored Ethernet adapter(s)..." -ForegroundColor Cyan

    foreach ($AdapterName in @($script:AdapterNeedsRestart.Keys)) {
        try {
            $Adapter = Get-NetAdapter `
                -Name $AdapterName `
                -Physical `
                -ErrorAction Stop

            if ("$($Adapter.Status)" -notin @("Up", "Disconnected")) {
                Write-Host `
                    "  [NOT RESTARTED] $AdapterName - current state: $($Adapter.Status)" `
                    -ForegroundColor DarkGray
                continue
            }

            Restart-NetAdapter `
                -Name $AdapterName `
                -Confirm:$false `
                -ErrorAction Stop

            Write-Host "  [RESTARTED] $AdapterName" -ForegroundColor Green
        }
        catch {
            Write-Host `
                "  [REBOOT MAY BE REQUIRED] $AdapterName" `
                -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Restore complete" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restored: $script:Restored" -ForegroundColor Green
Write-Host "Skipped:  $script:Skipped" -ForegroundColor DarkGray

if ($script:Failed -eq 0) {
    Write-Host "Failed:   0" -ForegroundColor Green
}
else {
    Write-Host "Failed:   $script:Failed" -ForegroundColor Red
}

Write-Host ""

if ($script:Failed -gt 0) {
    exit 1
}

exit 0
