# touch_windows
Touchscreen repair and update automation for HP / Lenovo / Dell notebooks.

1. Download the file and save it to your **Desktop**. -> https://raw.githubusercontent.com/ls-com/touch_windows/main/TouchFix.ps1
2. Open PowerShell (Press the **Windows key**, type: powershell )
3. Right-click **Windows PowerShell** in the results and choose **Run as administrator**. Click **Yes** when Windows asks for permission.
4. A blue window opens. Type this and press **Enter**:
```
    cd $env:USERPROFILE\Desktop
```
5. Run the check (Type this and press **Enter**:)
```
    powershell -ExecutionPolicy Bypass -File .\TouchFix.ps1
```
This only **checks** your laptop. It does not change anything.
Wait about 30 seconds. When it finishes, a report is saved to your Desktop.

6. Repair (only if Step 5 said BROKEN). In the same blue window, type this and press **Enter**:

recommended -> reinstall drivers, OS, firmware
```
     powershell -ExecutionPolicy Bypass -File .\TouchFix.ps1 -Mode Full
```
or only drivers
```
     powershell -ExecutionPolicy Bypass -File .\TouchFix.ps1 -Mode Repair
```
This reinstalls the touchscreen driver. It takes about a minute.

7. **Restart your laptop when it finishes**, then try the touchscreen.
8. If the touchscreen still doesn't work, email us the report file from your Desktop. It's named:
```
    TouchFix_Report_2026-08-20_1430.txt
```
 
---

## Quick start

| Situation | Command |
|---|---|
| Unit arrived, want to know what's wrong | `.\TouchFix.ps1` |
| Suspect driver stack (most common) | `.\TouchFix.ps1 -Mode Repair` |
| Bench refurb, do everything | `.\TouchFix.ps1 -Mode Full -AutoReboot` |
| Everything including BIOS | `.\TouchFix.ps1 -Mode Full -IncludeBios -AutoReboot` |
| Confirm fix after reboot | `.\TouchFix.ps1` |

Run from an elevated PowerShell prompt. The script self-elevates if you forget.


---

## What each stage does

**Stage 1 — Diagnose (always runs, read-only)**
Queries the Win32 digitizer API, enumerates HID touch devices and I2C/Serial IO
controllers, checks their problem codes, and flags generic-Microsoft drivers
sitting where an OEM driver should be.

**Stage 2 — Repair driver stack**
Starts `hidserv` and `TabletInputService` if stopped, enables any disabled touch
device, then `pnputil /remove-device` on the HID touch device followed by
`pnputil /scan-devices`. This is the fix your customer performed manually.

**Stage 3 — Vendor drivers and firmware**

| Vendor | Primary engine | Fallback |
|---|---|---|
| Dell | `dcu-cli.exe /scan` then `/applyUpdates` | none — DCU must be installed |
| HP | HP Image Assistant `/Operation:Analyze /Action:Install` | HPCMSL module |
| Lenovo | LSUClient module (`Get-LSUpdate`) | Thin Installer `/CM -search A` |

**Stage 4 — Windows Update**
Microsoft.Update COM API: search, accept EULAs, download, install.

**Stage 5 — BIOS** (only with `-IncludeBios`)
Compares installed version against the vendor catalog and flashes if newer.

---

## Design decisions worth knowing

**Repair runs before updates.** Your customer's fix was a driver reinstall.
Running a 20-minute BIOS flash first to reach the same outcome wastes bench time
and adds risk. The script also **stops as soon as touch works** — pass
`-RunAllStages` to override.

**BIOS is off by default.** Enabling it is a deliberate choice, not a default.
See the warning below.

**Removes the HID touch device, not the I2C controller.** On several HP and
Lenovo models the touchpad and internal keyboard also hang off the I2C bus.
Removing a healthy controller can leave a bench tech with no input device until
the rescan completes. The controller is only included when it is *itself* in an
error state, and the script warns first.

**Creates a restore point** before any change, and clears the 24-hour throttle
that normally blocks a second one.

**Does not force feature updates.** The COM API doesn't install 23H2 → 24H2
anyway, and silently upgrading a customer's Windows build is a support incident
waiting to happen. The script flags it instead.

---

## Warnings

**BIOS flashing on customer machines.** The script gates this on AC power and
≥30% battery, but a flash interrupted by a power loss can brick the board. On a
customer-owned machine you are absorbing that liability. Recommended: use
`-IncludeBios` on bench units only, and have customers run without it.

**Lenovo ThinkCentre and ThinkStation need a full shutdown**, not a restart, to
apply BIOS. The script reads `HKLM\SOFTWARE\LSUClient\BIOSUpdate\ActionNeeded`
and reports which is required — read that line before hitting restart.

**Dell BIOS passwords.** If your units ship with a BIOS password set, `dcu-cli`
needs `-encryptedPassword` and `-encryptionKey`. Add them to the stage 3 call.

**Vendor tools must already be installed** for Dell and HP. The script reports
the download URL if missing rather than pulling executables from the internet
unattended. Lenovo is the exception — LSUClient comes from PSGallery, which the
script will install.

---

## Deployment

**Bench use:** drop both files on the tech's desktop.

**Customer self-service:** ship `-Mode Repair` only. It's the highest-yield,
lowest-risk stage and needs no vendor tooling. Wrap it in a `.cmd` like the
earlier diagnostic so it's a double-click.

**Fleet use:** the script is idempotent and returns a report file per run. Ship
it via your RMM, collect `TouchFix_Report_*.txt`, and grep for the final verdict
line to auto-triage RMAs.

---

## Reading the output

The last section is the decision point:

- `*** TOUCHSCREEN IS WORKING ***` → confirm, then close the ticket
- `*** REBOOT REQUIRED ***` → restart, re-run in Diagnose mode
- `*** TOUCHSCREEN STILL NOT WORKING ***` → software exhausted, approve the RMA

---

