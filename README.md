# AutoUpdate VHDX

🇬🇧 **English** · 🇩🇪 [Deutsch](README.de.md)

**Fully automated Windows Update for sysprepped VHDX images** – without a single click inside the VM.

AutoUpdate VHDX boots a golden image (VHDX) in an invisible, temporary Hyper-V VM, installs all available Windows updates over several rounds, cleans up the image, re-runs Sysprep and only replaces the original once everything has succeeded. With the built-in scheduler it can also run overnight on selected weekdays.

The GUI, all messages and all logs can be switched between **English and German** (DE | EN in the title bar).

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The interface](#the-interface)
- [Schedule](#schedule)
- [Command line](#command-line)
- [How a run works](#how-a-run-works)
- [Security & notes](#security--notes)
- [Logs & monitoring](#logs--monitoring)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Changes](#changes)

---

## Features

- **Fully automated updates** via the Windows Update API built into Windows – no module is downloaded from the internet
- **Multiple update rounds** with restarts until two searches in a row find nothing
- **Restart detection**: if Windows restarts on its own in the middle of an installation, the tool continues automatically
- **Safety copy**: all work is done on a copy – the original is only replaced on success
- **Clean image** (optional): removes all local users including their profiles, as well as orphaned profiles
- **Leaves no traces**: the temporary account, answer file, autologon and update policies are removed or restored to their original state before Sysprep
- **Sysprep safeguards**: known blockers (Copilot/Widgets) are removed, `setuperr.log` is evaluated
- **Automatic switch detection**: finds a virtual switch with internet access by itself
- **Queue with color status**: process several images one after another – finished images are marked green, the running one turquoise, failed ones red
- **Scheduler** with freely selectable weekdays
- **Live status**: current step, update progress and runtime directly in the GUI
- **Bilingual**: English / German, switchable at any time
- **Self-elevation**: requests administrator rights automatically via UAC

## Requirements

| Area | Requirement |
|---|---|
| Host | Windows 10/11 Pro/Enterprise or Windows Server with **Hyper-V** enabled |
| PowerShell | Windows PowerShell 5.1 (included in Windows) |
| Rights | Administrator (requested automatically via UAC at startup) |
| Network | A Hyper-V virtual switch with **internet access** (an external switch is easiest) |
| Image | **VHDX** containing Windows, **Generation 2 / UEFI (GPT)** – `.vhd` and MBR images are not supported |
| Disk space | In the VHDX folder: size of the VHDX + approx. 15 GB buffer |

If you don't have a suitable switch yet, create one like this (adjust the adapter name):

```powershell
New-VMSwitch -Name "AutoUpdateSwitch" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

## Quick start

1. Download `AutoUpdateVhdxGui.ps1` and put it into a local folder, e.g. `C:\Tools\AutoUpdateVHDX\`.
2. If the file comes from the internet, unblock it once:
   ```powershell
   Unblock-File -Path "C:\Tools\AutoUpdateVHDX\AutoUpdateVhdxGui.ps1"
   ```
3. Right-click the file → **Run with PowerShell** → confirm the UAC prompt.
4. Switch the language to **EN** in the title bar if needed (the choice is saved).
5. Click **Self-test** first – all critical checks must be green.
6. Select a VHDX via **Browse**, review the settings and click **Start auto-update**.

Depending on the number of updates, a run usually takes 20–60 minutes.

## The interface

| Setting | Meaning |
|---|---|
| **VM RAM (GB)** | Memory of the temporary VM. Default: 8 GB – noticeably speeds up large cumulative and .NET updates. The host needs this much free memory. |
| **Max. update rounds** | Maximum number of install rounds. Confirmation searches don't count. Default: 5 |
| **Use safety copy** | Works on a copy; the original is only replaced on success. **Strongly recommended.** |
| **Remove all local users** | Removes all non-built-in local accounts including their profiles, as well as orphaned profiles. Administrator, Guest etc. are kept. Unchecked, only the temporary account is removed. |
| **Keep old image as .bak** | Keeps the old image as `<name>.vhdx.bak` after success. Unchecked, it is deleted (no daily backup). |
| **Automatic login** | Sets up an automatic login for the finished image and skips OOBE. Intended for test/reference images only. |
| **DE \| EN** (title bar) | Language of the interface, messages and logs. The choice is saved. |

### Queue

Use **Add** (or multi-select in **Browse**) to put several images into the queue; they are processed one after another. Each entry shows its status in color:

| Display | Meaning |
|---|---|
| Green – **Done** | successfully updated and sysprepped again |
| Turquoise – **Running** | currently being processed |
| Red – **Error** | failed or file not found |
| Orange – **Cancelled** | cancelled while this image was being processed |
| Gray – **Waiting** | still to come |

The markings stay visible after the run and are reset at the next start.

Other buttons:

- **Self-test** – checks Hyper-V, the management service, the switch and disk space
- **Reset rearm counter** – resets the Sysprep rearm state of a VHDX offline, without booting it
- **Cancel** – stops after the current step and cleans up the temporary VM

## Schedule

1. Select a VHDX or put several images into the **queue**.
2. Enter a time (format `HH:MM`) and tick the desired **weekdays** (all seven = daily).
3. Click **Create schedule**.

The scheduled task is called `AutoUpdate-VHDX` and runs invisibly as **SYSTEM**. It takes over the current settings (RAM, rounds, safety copy, remove users, backup). If you change settings, simply create the schedule again – the old one is replaced.

To test it right away without waiting for the scheduled time:

```powershell
schtasks /Run /TN "AutoUpdate-VHDX"
```

**Important:**

- Don't move the script after creating the schedule – the task calls it by its path.
- Don't use mapped network drives (`Z:\`) – the SYSTEM account doesn't know them. Use local paths or UNC paths (`\\server\share\...`) instead.
- The task's files are stored in `%ProgramData%\AutoUpdateVhdx\`.

## Command line

```powershell
# Self-test in the console
.\AutoUpdateVhdxGui.ps1 -SelfTest

# Unattended run (no GUI), e.g. for your own automation
.\AutoUpdateVhdxGui.ps1 -Unattended -VhdxPath "D:\VHDX\Win11-Template.vhdx" -RemoveAllLocalUsers

# Several images from a list file (one path per line), English logs
.\AutoUpdateVhdxGui.ps1 -Unattended -VhdxListFile "D:\VHDX\list.txt" -Language en
```

| Parameter | Description |
|---|---|
| `-SelfTest` | Runs only the self-test in the console |
| `-Unattended` | Run without GUI (for schedules/automation) |
| `-VhdxPath` | One or more VHDX files |
| `-VhdxListFile` | Text file with one VHDX path per line |
| `-LogPath` | Folder for log files (default: `Protokolle` next to the script) |
| `-MemoryGB` | RAM of the temporary VM (default: 8) |
| `-MaxRounds` | Maximum number of install rounds (default: 5) |
| `-NoSafeCopy` | Work directly on the original (not recommended) |
| `-RemoveAllLocalUsers` | Clean image: remove all local users and profiles |
| `-KeepBackup` | Keep the old image as `.bak` after success |
| `-Language` | `en` or `de` (overrides the saved language) |

Exit codes in unattended mode: `0` = all successful, `1` = at least one image failed, `2` = invalid call, `5` = no administrator rights.

## How a run works

| Phase | What happens |
|---|---|
| 1. Preparation | Checks file type and disk space, creates the safety copy |
| 2. OOBE automation | Offline: places an answer file with a temporary account, backs up existing answer files, resets the rearm state |
| 3. Create temporary VM | Generation 2 VM with the working copy, Secure Boot off, no checkpoints |
| 4. Start VM | Connects via PowerShell Direct, tests internet access, switches to another virtual switch automatically if needed |
| 5. Prepare Windows Update | Sets up the update helper in the VM, pauses Windows' own update automation during the run |
| 6. Install updates | Search → install → restart, until two searches in a row find nothing |
| 7. Run Sysprep | Removes blockers, cleans up accounts, removes all leftovers, `sysprep /generalize /oobe /shutdown` |
| 8. Clean up & replace original | Offline profile cleanup, removes the VM, replaces the original with the updated copy (with rollback on errors) |

## Security & notes

- **Temporary account:** For the automation, the tool creates the local administrator account `AutoUpdate` with the default password `Passw0rd` in the working copy. Account, answer file and autologon are removed again **before** the final Sysprep. If that fails, the run is aborted so that no image with a temporary administrator is created.
- **Built-in Administrator:** If it was enabled in the image, it receives the tool's default password during the run. Please change it after deployment. If it was disabled, it is disabled again.
- **Automatic login (optional):** The password is stored only lightly obfuscated in the finished image – use this for test and reference images only.
- **Without the safety copy** the tool works directly on the original. If something goes wrong, the image may become unusable.
- **Don't run in parallel:** Don't start a GUI run on an image while the scheduled task is processing it.

## Logs & monitoring

- **GUI:** log in the window, status line with the current step and runtime
- **Schedule:** log files in the `Protokolle` folder next to the script (`AutoUpdateVHDX_<date>.log`); the last 60 are kept
- **Event Viewer:** *Windows Logs → Application*, source `AutoUpdateVHDX`

| Event ID | Meaning |
|---|---|
| 1000 | Tool started in interactive mode |
| 1001 | Scheduled run successful |
| 1002 | Scheduled run with errors |

## Troubleshooting

| Problem | Solution |
|---|---|
| The VM sits at the **sign-in screen** | Normal during a run – the tool works via PowerShell Direct and doesn't need a desktop login. |
| An update (e.g. **.NET**) takes very long | Normal: afterwards Windows recompiles all .NET assemblies. More RAM helps. |
| The VM doesn't start ("not enough memory") | The host doesn't have 8 GB free – lower the RAM value in the GUI (e.g. 4 GB) or use `-MemoryGB 4`. |
| The finished image hangs at the sign-in screen with the account `AutoUpdate` | Leftover from an older version: run the image through the current version once. |
| "No internet access" | Set up a virtual switch with real internet access (see requirements). |
| "MBR partition table" / "Only VHDX" | The image is Generation 1 or a `.vhd` – not supported. |
| Sysprep fails | The last lines of `setuperr.log` are shown in the log. In safety copy mode the original stays unchanged. |
| There is a `.bak` next to the image | That's the old image (only with "Keep old image"). It can be deleted once the new image has been checked. |
| The VHDX is still "mounted" | The tool offers to dismount it at startup, alternatively: `Dismount-VHD -Path <path>` |

## Known limitations

- Only **VHDX** images with **Generation 2 / UEFI**.
- The temporary answer file uses German regional and language settings (`de-DE`).
- Update titles and error messages from Windows itself appear in the language of the VM or host.
- Updates that fail two rounds in a row are skipped and listed in the log.

## Changes

All changes per version are listed in the [CHANGELOG](CHANGELOG.md).

---

**Version:** 1.2 · Built for Windows PowerShell 5.1 and Hyper-V
