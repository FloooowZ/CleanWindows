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
- Windows Performance (Gaming + No Animations, foreground CPU priority, Fast Startup off)
- Mouse Optimization (no acceleration, 1:1)
- Explorer Optimization (This PC + no history)
- Edge / WebView2 - Gaming Optimization
- Microsoft Store Optimization
- Windows Defender - Gaming Performance (antivirus only)
- Start Menu - Simple & Clean
- Taskbar - End Task in right-click menu
- Ensure winget (App Installer)
- Install Escape From Tarkov Launcher, Steam, VLC, Plex, Google Chrome, Discord (with gaming optimization: no auto-start, no tray, caches cleared), NanaZip, Notepad++
- Gaming Runtimes (legacy VC++ + .NET)
- NVIDIA - Install NVCleanstall / Download latest Game Ready driver / Debloated driver install / Control Panel
- NVIDIA - Profile Inspector Gaming Settings (optional, asked at startup)
- Sound - Disable Windows Spatial Audio
- Network Optimization (Gaming IPv4)
- Services Optimization (Gaming)
- Startup Programs + Scheduled Tasks (Minimal)
- Process Reduction (svchost grouping)
- System Performance Tweaks (memory, SSD TRIM, driver updates)
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
4. installs the **NVIDIA Control Panel** (Microsoft Store);
5. optionally applies **NVIDIA Profile Inspector** tweaks to the global driver profile (*Base Profile*), see below.

The NVIDIA tasks are skipped if there is no NVIDIA card.

### NVIDIA Profile Inspector

At startup the script asks once: **Apply NVIDIA Profile Inspector optimizations (max performance, low latency, unlimited shader cache)? [Y/N]**.
The question is not asked when no NVIDIA card is detected or when `-Only` / `-Skip` already excludes the task.
Answer `N` to skip it. To skip the question, pass `-NvidiaProfile Yes` or `-NvidiaProfile No`.

The latest [NVIDIA Profile Inspector](https://github.com/Orbmu2k/nvidiaProfileInspector) release is downloaded from its official
GitHub releases and these settings are merged into the *Base Profile* (`-silentImport -mergeImport`: other settings are kept):

| Setting | ID | Value |
|---|---|---|
| Power management mode | `0x1057EB71` | Prefer maximum performance (1) |
| Maximum pre-rendered frames (Low Latency Mode) | `0x007BA09E` | 1 |
| Ultra Low Latency - CPL State | `0x0005F543` | On (1) |
| Ultra Low Latency - Enabled | `0x10835000` | 0 (Low Latency Mode *On*, not *Ultra*) |
| Shader Cache - Cache Size | `0x00AC8497` | Unlimited (`0xFFFFFFFF`) |

Current values are read first (export of the customized profiles); nothing is imported if they are already set.
A backup of the original customized profiles (`CleanWindows-NvidiaProfiles-Backup.nip`) and the imported file
(`CleanWindows-NvidiaGaming.nip`) are kept in `Documents\CleanWindows`. To undo, restore the Base Profile in
NVIDIA Profile Inspector. A clean driver reinstall also resets these settings.

## Game launchers

At startup the script asks once: **Install game launchers? [Y/N]** (Steam and the Escape From Tarkov launcher). Answer `N` to skip them; launchers that are already installed are skipped either way.

To skip the question, pass `-Launchers Yes` or `-Launchers No`.

## Power plan

The script keeps **one single plan**: *Gaming - Ultimate Performance* (a copy of Ultimate Performance, or High
Performance if Ultimate is not available). It is activated, then **every other plan is deleted**.

| Setting (plugged in) | Value |
|---|---|
| CPU minimum / maximum state | 5% / 100% (idle cores can clock down; good for hybrid P/E CPUs such as the i7 13700K) |
| Core parking | Ultimate Performance default (not forced) |
| CPU boost mode / energy preference | Aggressive / performance |
| PCIe link state power management | Off |
| USB selective suspend / USB 3 link power | Off |
| Turn off hard disk / sleep / hybrid sleep | Never / never / off |
| Wireless adapter | Maximum performance |

On a desktop the same values are also written for battery (DC). Re-running it only changes values that differ.

## Re-running the script (check before apply)

Every task first checks the current state and only writes what is different: registry values (value and type),
services, scheduled tasks, optional features, boot settings, Defender settings and exclusions, network adapter
properties and bindings, power plan, memory settings, APPX packages and installed programs (uninstall registry,
known files, APPX, then `winget list`). The Start menu pins are reset only once (marker
`HKCU:\Software\CleanWindows\StartPinsReset`). The summary shows, per task, how many items were **changed** and
how many were **already set**; a task with nothing to change is shown as `ALREADY APPLIED`.

## Generated reports

All files are written to a single folder, `Documents\CleanWindows`. At the end of the run, the script opens it in File Explorer with the summary selected (files from older versions are moved there automatically).

| File | Contents |
|---|---|
| `Documents\CleanWindows\CLEANWINDOWS-SUMMARY.TXT` | Tasks, durations, final state check, before → now measurements, warnings/errors |
| `Desktop\CLEANWINDOWS-AFTER-REBOOT.TXT` | Before → after reboot comparison (created automatically ~2 min 30 s after the next sign-in) |
| `Documents\CleanWindows\CLEANWINDOWSLOG.TXT` | Full log |
| `Documents\CleanWindows\CleanWindows-Baseline.json` | Initial measurement (kept across re-runs) |
| `Documents\CleanWindows\CleanWindows-RestoreServices.ps1` | Restores the disabled services |
| `Documents\CleanWindows\CleanWindows-ServicesBaseline.json` | Original service start values (recorded on the first run, kept across re-runs) |
| `Documents\CleanWindows\CleanWindows-RemovedGhostDevices.csv` | Removed ghost devices |

On a **laptop**, the script leaves battery settings, hibernation and device power saving unchanged.

## After the run

- Summary (tasks, durations, final state check, warnings): `Documents\CleanWindows\CLEANWINDOWS-SUMMARY.TXT`
- Full log: `Documents\CleanWindows\CLEANWINDOWSLOG.TXT`
- Services restore script: `Documents\CleanWindows\CleanWindows-RestoreServices.ps1`
- Reboot the PC at the end.

## Settings at the top of the script

| Variable | Purpose |
|---|---|
| `$TaskTimeoutSeconds` | Maximum time per task (300 s) |
| `$CleanUserDownloads` | Also cleans the Downloads folder at the end: items are moved to the **Recycle Bin** (recoverable); the script, `Launch-*.bat`, `*CleanWindows*` / `AllInOne*` files and the script's folder are kept |
| `$RunComponentCleanup` | DISM component store cleanup (slow) |
