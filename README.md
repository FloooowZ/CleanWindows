# All-In-One Clean Windows (Gaming)

PowerShell script that optimizes Windows 11 for gaming: bloatware removal, minimal services and startup programs,
full black theme, network, sound, Defender, NVIDIA driver, software installs, final cleanup, and more.

## Install / run (PowerShell)

Open **PowerShell** (not CMD) and paste:

```powershell
$u = "https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1"
$f = "$env:TEMP\AllInOne-CleanWindows-Standalone.ps1"
irm $u -OutFile $f
powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

The script relaunches itself as administrator (accept the UAC prompt).

Short version (single line):

```powershell
irm "https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1" -OutFile "$env:TEMP\a.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\a.ps1"
```

> `irm ... | iex` is **not** supported: the script must be a file so it can relaunch itself as administrator.

## Run from the Command Prompt (CMD)

Paste this line into CMD:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1' -OutFile $env:TEMP\a.ps1; & $env:TEMP\a.ps1"
```

Or double-click `Launch-From-GitHub.bat`: it always downloads the latest version of the script from GitHub.

If you downloaded the whole repository, double-click `Launch-AllInOne.bat` (next to the `.ps1`) to run the local copy as administrator.

## Launch options

```powershell
# List the tasks (number + name) without running anything
powershell -NoProfile -ExecutionPolicy Bypass -File $f -List

# Run only some tasks (words contained in the name, comma-separated)
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Only "Services,Startup,Network"

# Run everything except some tasks
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Skip "Plex,Component Store"
```

## Tasks

Each task runs in its own job with a timeout (5 minutes by default, longer for downloads / DISM). In order:

- System Restore Point (safety)
- Visual C++ Redistributable x64 / x86, DirectX End-User Runtime
- Context Menu Clean
- AI Bloatware Removal (Copilot / Recall)
- Useless Apps Removal (APPX)
- Xbox / Gamebar Uninstall
- OneDrive Uninstall
- MSI Mode (GPU)
- Power Plan - Gaming (Ultimate Performance)
- Theme Black (Full Dark Everywhere)
- Windows Performance (Gaming + No Animations)
- Mouse Optimization (no acceleration, 1:1)
- Explorer Optimization (This PC + no history)
- Edge / WebView2 - Gaming Optimization
- Microsoft Store Optimization
- Windows Defender - Gaming Performance (antivirus only)
- Start Menu - Simple & Clean
- Taskbar - End Task in right-click menu
- Ensure winget (App Installer)
- Install Escape From Tarkov Launcher, Steam, VLC, Plex, Google Chrome, Discord, NanaZip, Notepad++
- Install MSI Afterburner + RTSS (FPS only)
- Gaming Runtimes (legacy VC++ + .NET)
- NVIDIA - Install NVCleanstall / Download latest Game Ready driver / Debloated driver install / Control Panel
- Display Mode (2560x1440 @ up to 180 Hz)
- Sound - Disable Windows Spatial Audio
- Network Optimization (Gaming IPv4)
- Services Optimization (Gaming)
- Startup Programs + Scheduled Tasks (Minimal)
- Process Reduction (svchost grouping)
- High-End PC Tweaks (i7-13700K / RTX 4080 class)
- Boot Tweaks (hypervisor off, default system timer)
- Optional Windows Features Cleanup (Hyper-V / WSL / Sandbox / legacy)
- Device Power Management Off (USB / HID / Network)
- Device Cleanup (ghost devices + old driver packages)
- Component Store Cleanup (DISM)
- Hardware Health Check (RAM speed, PCIe, Resizable BAR, DirectStorage)
- Final Check (read-back report)
- Restart Explorer (apply changes)
- Final Cleanup (Downloads / Disk C:)

Use `-List` to see the exact, numbered list.

## NVIDIA

If an NVIDIA card is detected, the script:

1. installs **NVCleanstall** (TechPowerUp) for manual use: it has no automatic mode;
2. downloads the **latest Game Ready driver** from NVIDIA;
3. installs it as a **slimmed-down** build (display driver + HDMI/DP audio + PhysX, without GeForce Experience, NVIDIA App or telemetry), the way NVCleanstall does;
4. installs the **NVIDIA Control Panel** (Microsoft Store).

No questions are asked. The NVIDIA tasks are skipped if there is no NVIDIA card.
A separate task sets the display to 2560x1440 at the highest refresh rate up to 180 Hz (no effect if the monitor lacks this mode; use `-Skip "Display Mode"` to skip it).

## Generated reports

| File | Contents |
|---|---|
| `Desktop\CLEANWINDOWS-SUMMARY.TXT` | Tasks, durations, final state check, before → now measurements, warnings/errors |
| `Desktop\CLEANWINDOWS-AFTER-REBOOT.TXT` | Before → after reboot comparison (created automatically ~2 min 30 s after the next sign-in) |
| `Documents\CLEANWINDOWSLOG.TXT` | Full log |
| `Documents\CleanWindows-Baseline.json` | Initial measurement (kept across re-runs) |
| `Documents\CleanWindows-RestoreServices.ps1` | Restores the disabled services |
| `Documents\CleanWindows-RemovedGhostDevices.csv` | Removed ghost devices |

On a **laptop**, the script leaves battery settings, hibernation and device power saving unchanged.

## After the run

- Summary (tasks, durations, final state check, warnings): `Desktop\CLEANWINDOWS-SUMMARY.TXT`
- Full log: `Documents\CLEANWINDOWSLOG.TXT`
- Services restore script: `Documents\CleanWindows-RestoreServices.ps1`
- Reboot the PC at the end.

## Settings at the top of the script

| Variable | Purpose |
|---|---|
| `$TaskTimeoutSeconds` | Maximum time per task (300 s) |
| `$CleanUserDownloads` | Also empties the Downloads folder at the end |
| `$RunComponentCleanup` | DISM component store cleanup (slow) |
