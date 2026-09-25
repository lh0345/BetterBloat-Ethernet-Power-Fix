# BetterBloat Ethernet Power Saving Fix

A conservative Windows PowerShell utility that disables common Ethernet power-saving features **only when the installed network driver exposes a supported setting**.

It is designed to avoid the usual "gaming tweak" behavior of blindly changing unrelated network features.

## Download

For normal users, download the ZIP from the latest **GitHub Release**, extract it, then run:

**`Run BetterBloat Ethernet Fix.bat`**

Approve the Windows UAC Administrator prompt.

Your Ethernet connection may disconnect for a few seconds while the changed adapter restarts.

## What it changes

When supported by the installed Ethernet driver:

- Energy Efficient Ethernet / EEE
- Advanced EEE
- Green Ethernet
- Gigabit Lite
- Power Saving Mode / Power Save Mode
- Auto Disable Gigabit
- Reduce Speed On Power Down
- DMA Coalescing
- Selective Suspend
- Device Sleep On Disconnect
- D0 Packet Coalescing
- `Allow the computer to turn off this device to save power`
- PCIe Link State Power Management on **AC power**

## What it deliberately does NOT change

- Wi-Fi adapters
- Virtual network adapters
- Wake-on-LAN settings
- Speed & Duplex
- RSS
- checksum offloads
- Large Send Offload
- Receive Segment Coalescing
- interrupt moderation
- flow control
- receive/transmit buffers
- Jumbo Frames
- VLAN settings

Those are not simply Ethernet power-saving controls and should not be bundled into a generic power-saving fix.

## Laptop battery behavior

PCIe Link State Power Management is a **system-wide PCIe setting**, not an Ethernet-only setting.

For that reason, the normal launcher changes it only while plugged into AC power.

Advanced users who intentionally want PCIe Link State Power Management disabled on battery too can run an elevated PowerShell window from this folder:

```powershell
.\BetterBloat-EthernetPower.ps1 -AlsoDisableOnBattery
```

This can increase battery usage.

## Restore original settings

The fix creates a backup before changing anything:

```text
C:\ProgramData\BetterBloat\EthernetPowerBackups\
```

To restore the newest backup, run:

**`Restore BetterBloat Ethernet Fix.bat`**

The restore script uses the original values recorded before the fix was applied.

## Advanced usage

Run without restarting changed Ethernet adapters:

```powershell
.\BetterBloat-EthernetPower.ps1 -NoRestart
```

Restore a specific backup:

```powershell
.\Restore-BetterBloat-EthernetPower.ps1 -BackupPath "C:\ProgramData\BetterBloat\EthernetPowerBackups\YYYYMMDD-HHMMSS\original-settings.json"
```

## Safety design

The script:

1. requires Administrator privileges;
2. targets only physical Ethernet interfaces;
3. reads the existing state first;
4. creates a backup before making changes;
5. uses Microsoft's standardized `*EEE` value for Energy Efficient Ethernet;
6. uses vendor-specific options only when the driver itself exposes an explicit `Disabled`, `Disable`, or `Off` value;
7. verifies settings after changing them;
8. skips unsupported properties rather than guessing registry values;
9. preserves Wake-on-LAN settings;
10. restarts only Ethernet adapters that were actually changed.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator privileges
- A physical Ethernet adapter supported by the Windows `NetAdapter` module

Different Intel, Realtek, Killer, Marvell/Aquantia, USB Ethernet, and OEM drivers expose different settings. Seeing `SKIPPED` for an unsupported property is normal.

## Important

This utility removes selected power-saving behavior. It does **not** guarantee lower latency, higher throughput, or better gaming performance on every system.

Reducing power saving can increase power consumption, particularly on laptops.

## Files

- `BetterBloat-EthernetPower.ps1` — applies the fix
- `Run BetterBloat Ethernet Fix.bat` — easy Administrator launcher
- `Restore-BetterBloat-EthernetPower.ps1` — restores backed-up settings
- `Restore BetterBloat Ethernet Fix.bat` — easy restore launcher
