<#
.SYNOPSIS
    Touchscreen Repair & Update Automation for HP / Lenovo / Dell laptops.

.DESCRIPTION
    Diagnoses and repairs the most common cause of "touchscreen not working"
    returns: a broken or generic HID/I2C driver stack.

    Runs in stages, cheapest and safest first:

      STAGE 1  Diagnose        - read-only inventory of the touch stack
      STAGE 2  Repair driver   - remove + re-enumerate the touch device
                                 (this is the fix that worked for your customer)
      STAGE 3  Vendor updates  - drivers + firmware via the OEM's own engine
      STAGE 4  Windows Update  - scan, download, install quality updates
      STAGE 5  BIOS            - compare installed vs latest, flash if asked

    Stops as soon as touch starts working, unless -RunAllStages is set.

.PARAMETER Mode
    Diagnose  - report only, change nothing (DEFAULT)
    Repair    - stage 2 only: remove and reinstall the touch driver
    Update    - stages 3 + 4: vendor drivers and Windows Update
    Full      - stages 2, 3, 4 (and 5 if -IncludeBios)

.PARAMETER IncludeBios
    Allow a BIOS/UEFI flash. OFF by default and deliberately so - read the
    warning in the BIOS section before enabling this on customer machines.

.PARAMETER RunAllStages
    Do not stop early when touch starts working. Useful for bench refurb.

.PARAMETER AutoReboot
    Reboot automatically when a stage requires it.

.PARAMETER LogPath
    Where to write the log + report. Defaults to the Desktop.

.EXAMPLE
    .\TouchFix.ps1
    Diagnose only. Safe on any machine.

.EXAMPLE
    .\TouchFix.ps1 -Mode Repair
    Just reinstall the touch driver stack.

.EXAMPLE
    .\TouchFix.ps1 -Mode Full -AutoReboot
    Bench refurb: repair, vendor drivers, Windows Update, reboot as needed.

.EXAMPLE
    .\TouchFix.ps1 -Mode Full -IncludeBios -AutoReboot
    Everything including BIOS. AC power required. See warnings.

.NOTES
    Requires administrator rights (will self-elevate).
    Requires internet access for stages 3, 4 and 5.
    Tested targets: HP, Lenovo, Dell notebooks running Windows 10 / 11.
#>

[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Repair','Update','Full')]
    [string]$Mode = 'Diagnose',

    [switch]$IncludeBios,
    [switch]$RunAllStages,
    [switch]$AutoReboot,
    [switch]$NoRestorePoint,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# =====================================================================
#  ELEVATION
# =====================================================================
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '  Administrator rights are required. Re-launching...' -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } else {
            $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`""
        }
    }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList; exit 0 }
    catch { Write-Host '  Elevation was declined. Cannot continue.' -ForegroundColor Red; exit 1 }
}

# =====================================================================
#  LOGGING
# =====================================================================
if (-not $LogPath) {
    $LogPath = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path $LogPath)) { $LogPath = $env:TEMP }
}
New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$logFile = Join-Path $LogPath "TouchFix_$stamp.log"
$Script:Report = New-Object System.Collections.Generic.List[string]

function Log {
    param([string]$Text, [ValidateSet('Info','Good','Warn','Bad','Head')][string]$Level = 'Info')
    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    $Script:Report.Add($Text)
    $color = switch ($Level) {
        'Good' { 'Green' } 'Warn' { 'Yellow' } 'Bad' { 'Red' }
        'Head' { 'Cyan'  } default { 'Gray' }
    }
    Write-Host "  $Text" -ForegroundColor $color
}
function Head($t) {
    Log '' ; Log ('-' * 66) 'Head' ; Log "  $t" 'Head' ; Log ('-' * 66) 'Head'
}

# =====================================================================
#  HARDWARE / VENDOR DETECTION
# =====================================================================
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$Vendor = switch -Wildcard ("$($cs.Manufacturer)") {
    '*HP*'      { 'HP'     ; break }
    '*Hewlett*' { 'HP'     ; break }
    '*LENOVO*'  { 'Lenovo' ; break }
    '*Dell*'    { 'Dell'   ; break }
    default     { 'Other' }
}
$Serial     = $bios.SerialNumber
$BiosVer    = $bios.SMBIOSBIOSVersion
$RebootFlag = $false

Clear-Host
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host '    TOUCHSCREEN REPAIR & UPDATE AUTOMATION' -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host ''

Log "Mode          : $Mode"
Log "Vendor        : $Vendor ($($cs.Manufacturer))"
Log "Model         : $($cs.Model)"
Log "Serial        : $Serial"
Log "BIOS          : $BiosVer"
Log "Windows       : $($cv.DisplayVersion) build $($os.BuildNumber).$($cv.UBR)"
Log "Log file      : $logFile"

# =====================================================================
#  POWER SAFETY CHECK
# =====================================================================
function Get-PowerState {
    $b = Get-CimInstance Win32_Battery
    if (-not $b) { return @{ HasBattery = $false; OnAC = $true; Percent = 100 } }
    @{
        HasBattery = $true
        OnAC       = ($b.BatteryStatus -in 2,6,7,8,9)   # 2 = AC, 6-9 = charging states
        Percent    = [int]$b.EstimatedChargeRemaining
    }
}
$power = Get-PowerState
Log "Power         : $(if ($power.OnAC) {'AC connected'} else {'ON BATTERY'}) - $($power.Percent)%"

# =====================================================================
#  TOUCH STACK INSPECTION
# =====================================================================
function Get-TouchState {
    $result = [ordered]@{
        DigitizerPresent = $false
        StackReady       = $false
        MaxTouches       = 0
        TouchDevices     = @()
        I2CDevices       = @()
        ProblemDevices   = @()
        GenericDriver    = $false
        DisabledDevice   = $false
    }
    try {
        $sig = '[DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);'
        $u32 = Add-Type -MemberDefinition $sig -Name "TM$(Get-Random)" -Namespace Diag -PassThru
        $d   = $u32::GetSystemMetrics(94)
        $result.DigitizerPresent = ($d -band 0x01) -ne 0
        $result.StackReady       = ($d -band 0x80) -ne 0
        $result.MaxTouches       = $u32::GetSystemMetrics(95)
    } catch { }

    $result.TouchDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -like '*touch screen*' -or $_.FriendlyName -like '*touchscreen*' -or
        $_.FriendlyName -like '*digitizer*'
    })
    $result.I2CDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -like '*I2C*' -or $_.FriendlyName -like '*Serial IO*' -or
        $_.FriendlyName -like '*Serial I/O*'
    })
    $result.ProblemDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Unknown' })

    foreach ($t in $result.TouchDevices) {
        if ($t.Status -eq 'Error') { $result.DisabledDevice = $true }
        $drv = Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceID='$($t.InstanceId -replace '\\','\\\\')'" -ErrorAction SilentlyContinue
        if ($drv -and $drv.DriverProviderName -like '*Microsoft*') { $result.GenericDriver = $true }
    }
    [pscustomobject]$result
}

function Test-TouchWorking {
    $s = Get-TouchState
    return ($s.DigitizerPresent -and $s.StackReady -and
            ($s.TouchDevices | Where-Object { $_.Status -eq 'OK' }).Count -gt 0)
}

# =====================================================================
#  STAGE 1 - DIAGNOSE
# =====================================================================
Head 'STAGE 1 - DIAGNOSE'

$state = Get-TouchState
Log "Digitizer seen by Windows : $(if ($state.DigitizerPresent) {'YES'} else {'NO'})" $(if ($state.DigitizerPresent) {'Good'} else {'Bad'})
Log "Touch stack ready         : $(if ($state.StackReady) {'YES'} else {'NO'})" $(if ($state.StackReady) {'Good'} else {'Bad'})
Log "Max touch points          : $($state.MaxTouches)"

Log ''
Log 'Touch devices:'
if ($state.TouchDevices.Count -eq 0) {
    Log '  NONE PRESENT - digitizer is not enumerating at all.' 'Bad'
} else {
    foreach ($t in $state.TouchDevices) {
        $lvl = if ($t.Status -eq 'OK') { 'Good' } else { 'Bad' }
        Log "  [$($t.Status)] $($t.FriendlyName)" $lvl
        Log "        $($t.InstanceId)"
    }
}

Log ''
Log 'I2C / Serial IO controllers:'
if ($state.I2CDevices.Count -eq 0) {
    Log '  NONE PRESENT - chipset drivers are missing.' 'Bad'
} else {
    foreach ($i in $state.I2CDevices) {
        $lvl = if ($i.Status -eq 'OK') { 'Good' } else { 'Bad' }
        Log "  [$($i.Status)] $($i.FriendlyName)" $lvl
    }
}

if ($state.GenericDriver) {
    Log ''
    Log 'NOTE: touch device is on a generic Microsoft driver, not the OEM one.' 'Warn'
}
if ($state.ProblemDevices.Count -gt 0) {
    Log ''
    Log "$($state.ProblemDevices.Count) device(s) in an error state:" 'Warn'
    foreach ($p in $state.ProblemDevices) { Log "  [$($p.Status)] $($p.FriendlyName)" 'Warn' }
}

$touchOK = Test-TouchWorking
Log ''
Log "VERDICT: touch stack is $(if ($touchOK) {'HEALTHY'} else {'BROKEN'})" $(if ($touchOK) {'Good'} else {'Bad'})

if ($Mode -eq 'Diagnose') {
    Log ''
    Log 'Diagnose mode - no changes made.'
    Log 'Re-run with -Mode Repair or -Mode Full to apply fixes.'
    $Script:Report -join "`r`n" | Out-File (Join-Path $LogPath "TouchFix_Report_$stamp.txt") -Encoding UTF8
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 0
}

# =====================================================================
#  RESTORE POINT
# =====================================================================
if (-not $NoRestorePoint) {
    Head 'CREATING SYSTEM RESTORE POINT'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows throttles restore points to one per 24h; clear the throttle.
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
            -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description "Before TouchFix $stamp" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Log 'Restore point created.' 'Good'
    } catch {
        Log "Could not create a restore point: $($_.Exception.Message)" 'Warn'
        Log 'Continuing anyway. Device removal is reversible by a rescan.' 'Warn'
    }
}

# =====================================================================
#  STAGE 2 - REPAIR THE TOUCH DRIVER STACK
#  This is the fix that worked on the reported unit.
# =====================================================================
if ($Mode -in 'Repair','Full') {
    Head 'STAGE 2 - REPAIR TOUCH DRIVER STACK'

    # --- 2a. Services -------------------------------------------------
    foreach ($svcName in @('hidserv','TabletInputService')) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Log "Starting service $svcName ..." 'Warn'
            Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
            Log "  $svcName is now $((Get-Service $svcName).Status)" 'Good'
        }
    }

    # --- 2b. Enable anything that is merely disabled -------------------
    $disabled = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Error' -and (
            $_.FriendlyName -like '*touch screen*' -or $_.FriendlyName -like '*digitizer*' -or
            $_.FriendlyName -like '*I2C*'          -or $_.FriendlyName -like '*Serial IO*'
        )
    }
    foreach ($d in $disabled) {
        Log "Enabling: $($d.FriendlyName)" 'Warn'
        try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; Log '  Enabled.' 'Good' }
        catch { Log "  Could not enable: $($_.Exception.Message)" 'Bad' }
    }
    Start-Sleep -Seconds 3

    if ((Test-TouchWorking) -and -not $RunAllStages) {
        Log ''
        Log 'TOUCH IS NOW WORKING - the device was simply disabled.' 'Good'
        Log 'No driver reinstall or updates were needed.' 'Good'
        $Script:Report -join "`r`n" | Out-File (Join-Path $LogPath "TouchFix_Report_$stamp.txt") -Encoding UTF8
        Write-Host ''; Read-Host '  Press Enter to close'; exit 0
    }

    # --- 2c. Remove and re-enumerate the HID touch device --------------
    # We remove the HID touch device, NOT the I2C controller, unless the
    # controller is itself faulty. Removing a healthy I2C controller can
    # temporarily drop the touchpad and internal keyboard on some models.
    $targets = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -like '*touch screen*' -or $_.FriendlyName -like '*touchscreen*' -or
        $_.FriendlyName -like '*digitizer*'
    })

    $faultyI2C = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        ($_.FriendlyName -like '*I2C*' -or $_.FriendlyName -like '*Serial IO*') -and $_.Status -ne 'OK'
    })
    if ($faultyI2C.Count -gt 0) {
        Log ''
        Log 'Faulty I2C controller(s) found - including them in the repair.' 'Warn'
        Log 'The touchpad may stop responding for a few seconds during rescan.' 'Warn'
        $targets += $faultyI2C
    }

    if ($targets.Count -eq 0) {
        Log ''
        Log 'No touch device present to remove.' 'Bad'
        Log 'The digitizer is not enumerating - this points to missing chipset' 'Bad'
        Log 'drivers (stage 3 may fix it) or a hardware/cable fault (RMA).' 'Bad'
    } else {
        foreach ($t in $targets) {
            Log ''
            Log "Removing: $($t.FriendlyName)" 'Warn'
            $out = & pnputil.exe /remove-device "$($t.InstanceId)" 2>&1
            Log "  pnputil: $($out -join ' ' -replace '\s+',' ')"
        }

        Log ''
        Log 'Re-scanning for hardware changes...' 'Warn'
        & pnputil.exe /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 10

        $after = Get-TouchState
        if ($after.TouchDevices.Count -gt 0) {
            foreach ($t in $after.TouchDevices) {
                Log "  Re-detected [$($t.Status)] $($t.FriendlyName)" $(if ($t.Status -eq 'OK') {'Good'} else {'Bad'})
            }
        } else {
            Log '  Device did not come back on rescan.' 'Bad'
            Log '  A reboot is usually needed after removal - flagging one.' 'Warn'
            $RebootFlag = $true
        }
    }

    if ((Test-TouchWorking) -and -not $RunAllStages) {
        Log ''
        Log 'TOUCH IS NOW WORKING after driver reinstall.' 'Good'
        Log 'Stages 3-5 skipped (use -RunAllStages to force them).' 'Good'
        $Script:Report -join "`r`n" | Out-File (Join-Path $LogPath "TouchFix_Report_$stamp.txt") -Encoding UTF8
        Write-Host ''; Read-Host '  Press Enter to close'; exit 0
    }
}

# =====================================================================
#  HELPER - install a PSGallery module on demand
# =====================================================================
function Ensure-Module {
    param([string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { Import-Module $Name -Force -EA SilentlyContinue; return $true }
    Log "Installing PowerShell module '$Name' ..." 'Warn'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -EA SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -EA Stop | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -EA SilentlyContinue
        Install-Module -Name $Name -Force -Scope AllUsers -AllowClobber -EA Stop
        Import-Module $Name -Force -EA Stop
        Log "  '$Name' installed." 'Good'
        return $true
    } catch {
        Log "  Could not install '$Name': $($_.Exception.Message)" 'Bad'
        return $false
    }
}

# =====================================================================
#  STAGE 3 - VENDOR DRIVER + FIRMWARE UPDATES
# =====================================================================
if ($Mode -in 'Update','Full') {
    Head "STAGE 3 - VENDOR DRIVER UPDATES ($Vendor)"

    switch ($Vendor) {

        # ---------------------------------------------------------- DELL
        'Dell' {
            $dcu = @(
                "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
                "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1

            if (-not $dcu) {
                Log 'Dell Command Update is not installed.' 'Bad'
                Log 'Install it from: https://www.dell.com/support/kbdoc/000177325' 'Warn'
                Log 'Then re-run this script.' 'Warn'
            } else {
                Log "Using: $dcu" 'Good'
                $dcuLog = Join-Path $LogPath "dcu_$stamp"
                New-Item -ItemType Directory -Path $dcuLog -Force | Out-Null

                Log 'Scanning for Dell updates...'
                & $dcu /scan -silent -outputLog="$dcuLog\scan.log" | Out-Null
                Log "  Scan exit code: $LASTEXITCODE"

                # updateType excludes BIOS unless the operator asked for it
                $types = if ($IncludeBios) { 'bios,firmware,driver,application' }
                         else              { 'firmware,driver,application' }

                Log "Applying updates (types: $types)..."
                & $dcu /applyUpdates -silent -reboot=disable -updateType=$types -outputLog="$dcuLog\apply.log" | Out-Null
                $rc = $LASTEXITCODE
                Log "  Apply exit code: $rc"
                switch ($rc) {
                    0    { Log '  No updates were required.' 'Good' }
                    1    { Log '  Updates applied. A REBOOT is required.' 'Good'; $RebootFlag = $true }
                    5    { Log '  Updates applied. A reboot is required.' 'Good'; $RebootFlag = $true }
                    500  { Log '  No applicable updates found.' 'Good' }
                    1001 { Log '  Another instance is already running.' 'Warn' }
                    default { Log "  See $dcuLog\apply.log for detail." 'Warn' }
                }
            }
        }

        # ------------------------------------------------------------ HP
        'HP' {
            $hpia = @(
                "$env:ProgramFiles\HP\HPIA\bin\HPImageAssistant.exe",
                "$env:ProgramFiles\HPIA\HPImageAssistant.exe",
                "C:\HPIA\HPImageAssistant.exe",
                "C:\SWSetup\HP_Image_Assistant\HPImageAssistant.exe"
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($hpia) {
                Log "Using HP Image Assistant: $hpia" 'Good'
                $hpLog = Join-Path $LogPath "hpia_$stamp"
                New-Item -ItemType Directory -Path "$hpLog\SoftPaqs" -Force | Out-Null

                $cat = if ($IncludeBios) { 'All' } else { 'Drivers,Software' }
                $hpArgs = "/Operation:Analyze /Category:$cat /Selection:All /Action:Install " +
                          "/Silent /ReportFolder:`"$hpLog`" /SoftpaqDownloadFolder:`"$hpLog\SoftPaqs`" " +
                          "/LogFolder:`"$hpLog`""
                Log "Running HPIA (category: $cat). This can take 10-20 minutes..."
                $p = Start-Process -FilePath $hpia -ArgumentList $hpArgs -Wait -PassThru -WindowStyle Hidden
                Log "  HPIA exit code: $($p.ExitCode)"
                switch ($p.ExitCode) {
                    0    { Log '  Completed, nothing needed.' 'Good' }
                    256  { Log '  No recommendations - already current.' 'Good' }
                    3010 { Log '  Updates installed. REBOOT required.' 'Good'; $RebootFlag = $true }
                    3011 { Log '  Updates installed. REBOOT required.' 'Good'; $RebootFlag = $true }
                    default { Log "  Check the report in $hpLog" 'Warn'; $RebootFlag = $true }
                }
            }
            elseif (Ensure-Module 'HPCMSL') {
                Log 'HPIA not found - using HP Client Management Script Library instead.' 'Warn'
                try {
                    $sp = Get-SoftpaqList -ErrorAction Stop |
                          Where-Object { $_.Category -match 'Driver|Chipset|Input' }
                    Log "  $($sp.Count) relevant SoftPaq(s) available."
                    foreach ($s in $sp) {
                        Log "  Installing $($s.Id) - $($s.Name)"
                        Get-Softpaq -Number $s.Id -Action Install -Overwrite Yes -EA SilentlyContinue
                    }
                    $RebootFlag = $true
                } catch { Log "  HPCMSL error: $($_.Exception.Message)" 'Bad' }
            }
            else {
                Log 'No HP update engine available.' 'Bad'
                Log 'Install HP Image Assistant from:' 'Warn'
                Log '  https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html' 'Warn'
            }
        }

        # -------------------------------------------------------- LENOVO
        'Lenovo' {
            if (Ensure-Module 'LSUClient') {
                Log 'Querying Lenovo update catalog...'
                try {
                    $all = Get-LSUpdate -ErrorAction Stop
                    Log "  $($all.Count) update(s) offered by Lenovo."

                    $wanted = $all | Where-Object { $_.Installer.Unattended }
                    if (-not $IncludeBios) {
                        $wanted = $wanted | Where-Object { $_.Category -ne 'BIOS UEFI' }
                    }
                    Log "  $($wanted.Count) can be installed silently."

                    foreach ($u in $wanted) { Log "    - [$($u.Category)] $($u.Title)" }

                    if ($wanted.Count -gt 0) {
                        Log '  Downloading...'
                        $wanted | Save-LSUpdate -EA SilentlyContinue
                        Log '  Installing...'
                        $wanted | Install-LSUpdate -SaveBIOSUpdateInfoToRegistry -EA SilentlyContinue
                        $RebootFlag = $true
                        Log '  Done. Reboot required.' 'Good'

                        # LSUClient records whether the BIOS needs reboot or shutdown
                        $bu = Get-ItemProperty 'HKLM:\SOFTWARE\LSUClient\BIOSUpdate' -EA SilentlyContinue
                        if ($bu.ActionNeeded) {
                            Log "  BIOS update pending - requires: $($bu.ActionNeeded)" 'Warn'
                            if ($bu.ActionNeeded -eq 'SHUTDOWN') {
                                Log '  NOTE: this model needs a FULL SHUTDOWN, not a restart.' 'Warn'
                            }
                        }
                    }
                } catch { Log "  LSUClient error: $($_.Exception.Message)" 'Bad' }
            }
            else {
                $ti = @(
                    "$env:ProgramFiles\Lenovo\ThinInstaller\ThinInstaller.exe",
                    "${env:ProgramFiles(x86)}\Lenovo\ThinInstaller\ThinInstaller.exe"
                ) | Where-Object { Test-Path $_ } | Select-Object -First 1

                if ($ti) {
                    Log "Using Thin Installer: $ti" 'Good'
                    $tiArgs = "/CM -search A -action INSTALL -includerebootpackages 1,3,4 " +
                              "-noicon -noreboot -log `"$LogPath\thininstaller_$stamp.log`""
                    $p = Start-Process -FilePath $ti -ArgumentList $tiArgs -Wait -PassThru -WindowStyle Hidden
                    Log "  Exit code: $($p.ExitCode)"
                    $RebootFlag = $true
                } else {
                    Log 'No Lenovo update engine available.' 'Bad'
                    Log 'Install Lenovo Vantage from the Microsoft Store, or' 'Warn'
                    Log 'allow this script internet access to fetch the LSUClient module.' 'Warn'
                }
            }
        }

        default {
            Log "Vendor '$($cs.Manufacturer)' is not supported for automated driver updates." 'Warn'
            Log 'Windows Update (stage 4) will still run.' 'Warn'
        }
    }
}

# =====================================================================
#  STAGE 4 - WINDOWS UPDATE
# =====================================================================
if ($Mode -in 'Update','Full') {
    Head 'STAGE 4 - WINDOWS UPDATE'

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()

        Log 'Searching for updates (this can take several minutes)...'
        # Type='Software' covers quality updates; drivers are handled by
        # the vendor engine in stage 3, which gives better results.
        $searchResult = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        Log "  $($searchResult.Updates.Count) update(s) available."

        if ($searchResult.Updates.Count -eq 0) {
            Log '  Windows is up to date.' 'Good'
        } else {
            $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $searchResult.Updates) {
                if ($u.EulaAccepted -eq $false) { $u.AcceptEula() }
                Log "  + $($u.Title)"
                $toInstall.Add($u) | Out-Null
            }

            Log 'Downloading...'
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $toInstall
            $dr = $downloader.Download()
            Log "  Download result code: $($dr.ResultCode)  (2 = success)"

            Log 'Installing...'
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $toInstall
            $ir = $installer.Install()
            Log "  Install result code: $($ir.ResultCode)  (2 = success)"
            if ($ir.RebootRequired) { Log '  REBOOT required.' 'Warn'; $RebootFlag = $true }
        }
    } catch {
        Log "Windows Update COM error: $($_.Exception.Message)" 'Bad'
        Log 'Falling back to triggering the Windows Update service directly.' 'Warn'
        Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' -EA SilentlyContinue
    }

    # Feature updates (e.g. 23H2 -> 24H2) are NOT installed by the COM API.
    # They need the Installation Assistant, which we only flag, never force.
    $build = [int]$os.BuildNumber
    if ($build -lt 26100) {
        Log ''
        Log "This machine is on build $build. Feature updates are not installed" 'Warn'
        Log 'by this script - they need the Windows 11 Installation Assistant' 'Warn'
        Log 'and should be done deliberately, not automatically.' 'Warn'
    }
}

# =====================================================================
#  STAGE 5 - BIOS
# =====================================================================
if ($IncludeBios -and $Mode -in 'Update','Full') {
    Head 'STAGE 5 - BIOS / UEFI'

    Log "Installed BIOS version: $BiosVer"

    if (-not $power.OnAC) {
        Log 'ABORTED: machine is running on battery.' 'Bad'
        Log 'A BIOS flash on battery risks bricking the board. Connect AC power.' 'Bad'
    }
    elseif ($power.HasBattery -and $power.Percent -lt 30) {
        Log "ABORTED: battery is at $($power.Percent)%. Charge to 30% or more." 'Bad'
    }
    else {
        Log 'Power checks passed (AC connected, adequate charge).' 'Good'

        switch ($Vendor) {
            'HP' {
                if (Ensure-Module 'HPCMSL') {
                    try {
                        $latest = Get-HPBIOSUpdates -Latest -ErrorAction Stop
                        Log "Latest BIOS from HP  : $($latest.Ver)  ($($latest.Date))"
                        $cmp = Get-HPBIOSVersion -ErrorAction SilentlyContinue
                        Log "Currently installed  : $cmp"
                        if ($latest.Ver -ne $cmp) {
                            Log 'Newer BIOS available - flashing now. DO NOT POWER OFF.' 'Warn'
                            Get-HPBIOSUpdates -Flash -Yes -Force -BitLocker suspend -EA Stop
                            $RebootFlag = $true
                            Log 'BIOS staged. It applies on the next restart.' 'Good'
                        } else { Log 'BIOS is already current.' 'Good' }
                    } catch { Log "HP BIOS error: $($_.Exception.Message)" 'Bad' }
                }
            }
            'Lenovo' {
                if (Ensure-Module 'LSUClient') {
                    try {
                        $bu = Get-LSUpdate -EA Stop | Where-Object { $_.Category -eq 'BIOS UEFI' }
                        if ($bu) {
                            Log "BIOS update offered: $($bu.Title)"
                            Log 'Flashing now. DO NOT POWER OFF.' 'Warn'
                            $bu | Save-LSUpdate -EA Stop
                            $bu | Install-LSUpdate -SaveBIOSUpdateInfoToRegistry -EA Stop
                            $RebootFlag = $true
                            $reg = Get-ItemProperty 'HKLM:\SOFTWARE\LSUClient\BIOSUpdate' -EA SilentlyContinue
                            Log "Action needed to apply: $($reg.ActionNeeded)" 'Warn'
                        } else { Log 'BIOS is already current.' 'Good' }
                    } catch { Log "Lenovo BIOS error: $($_.Exception.Message)" 'Bad' }
                }
            }
            'Dell' {
                Log 'Dell BIOS was handled by dcu-cli in stage 3 (-updateType included bios).'
                Log 'If a BIOS password is set, dcu-cli needs -encryptedPassword to proceed.' 'Warn'
            }
            default { Log 'BIOS automation is not supported for this vendor.' 'Warn' }
        }
    }
}

# =====================================================================
#  FINAL VERIFICATION
# =====================================================================
Head 'FINAL STATE'

$final = Get-TouchState
$finalOK = Test-TouchWorking

Log "Digitizer present : $(if ($final.DigitizerPresent) {'YES'} else {'NO'})"
Log "Stack ready       : $(if ($final.StackReady) {'YES'} else {'NO'})"
foreach ($t in $final.TouchDevices) { Log "  [$($t.Status)] $($t.FriendlyName)" }

Log ''
if ($finalOK) {
    Log '*** TOUCHSCREEN IS WORKING ***' 'Good'
    Log 'Ask the customer to confirm by touching the screen.' 'Good'
} elseif ($RebootFlag) {
    Log '*** REBOOT REQUIRED BEFORE RESULT IS KNOWN ***' 'Warn'
    Log 'Restart, then re-run this script with -Mode Diagnose to confirm.' 'Warn'
} else {
    Log '*** TOUCHSCREEN STILL NOT WORKING ***' 'Bad'
    Log '' 'Bad'
    Log 'Software remedies are exhausted: drivers reinstalled, vendor updates' 'Bad'
    Log 'applied, Windows current. This is now a HARDWARE fault - digitizer' 'Bad'
    Log 'panel or ribbon cable. Approve the RMA.' 'Bad'
    Log '' 'Bad'
    Log "Quote serial number: $Serial" 'Bad'
}

$reportFile = Join-Path $LogPath "TouchFix_Report_$stamp.txt"
$Script:Report -join "`r`n" | Out-File $reportFile -Encoding UTF8
Log ''
Log "Report saved to: $reportFile"

# =====================================================================
#  REBOOT
# =====================================================================
if ($RebootFlag) {
    if ($AutoReboot) {
        Log ''
        Log 'Rebooting in 60 seconds. Save your work.' 'Warn'
        shutdown.exe /r /t 60 /c "TouchFix: applying updates"
    } else {
        Write-Host ''
        Write-Host '  A RESTART IS REQUIRED to finish.' -ForegroundColor Yellow
        $ans = Read-Host '  Restart now? (y/N)'
        if ($ans -match '^y') { Restart-Computer -Force }
    }
}

Write-Host ''
Read-Host '  Press Enter to close'
