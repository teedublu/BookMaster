#Requires AutoHotkey v2.0
#SingleInstance Force

; --- Cross-instance safety net -----------------------------------------------
; #SingleInstance only replaces a prior instance running from the exact same file
; PATH. If this script runs from a USB stick that gets a different drive letter on
; reinsertion (e.g. E:\ then F:\), AHK treats it as a "different" script and won't
; replace the old one - leaving a stale instance running, silently holding onto the
; F9/F10 global hotkeys (Windows only lets one process own a given hotkey at a time)
; and pointing at a now-invalid log path. This uses a fixed window title, independent
; of file path, to find and forcibly close any other running instance of this script
; before continuing - so a fresh launch always wins, regardless of drive letter.
INSTANCE_MARKER := "UMPToolCaptureLogger_Instance_Marker_DoNotClose"

DetectHiddenWindows(true)
if WinExist(INSTANCE_MARKER) {
    try WinKill(INSTANCE_MARKER)
    Sleep(300)  ; give the old process a moment to fully release its hotkeys/handles
}
WinSetTitle(INSTANCE_MARKER, "ahk_id " . A_ScriptHwnd)
DetectHiddenWindows(false)  ; restore default - do NOT leave this on for the rest of
                            ; the script, or later WinExist("ahk_exe " . targetExe)
                            ; calls could match some other hidden window under the
                            ; same process instead of UMPTool's real main dialog.
; --------------------------------------------------------------------------------

logFile := A_ScriptDir . "\umptool_raw_log.csv"
targetExe := "UmpToolV6A.exe"

if !FileExist(logFile)
    FileAppend("timestamp`tstage`thwnd`tclass`ttext`n", logFile)

; --- Win32 callback used by EnumChildWindows ---
EnumChildProc(hwnd, lParam) {
    obj := ObjFromPtrAddRef(lParam)
    obj.Push(hwnd)
    return true
}

; --- Recursively collect every descendant HWND of a window, via the real Win32 API ---
; (needed because UMPTool's per-slot regions are nested child dialogs, not flat controls -
;  AutoHotkey's built-in WinGetControlsHwnd only sees direct children, which isn't enough here)
CollectAllDescendants(parentHwnd) {
    list := []
    cb := CallbackCreate(EnumChildProc, "F", 2)
    DllCall("EnumChildWindows", "ptr", parentHwnd, "ptr", cb, "ptr", ObjPtr(list))
    CallbackFree(cb)
    return list
}

; --- Query every disk (not just ones WMI happens to tag InterfaceType=USB - that
;     field is unreliable, plenty of USB mass storage reports as SCSI instead).
;     Dumps EVERYTHING with full diagnostic fields; filtering to "is this actually
;     USB" happens later in the Python parser, using PNPDeviceID content instead.
;     Any PowerShell-level error gets written into the output file itself as an
;     ERROR| line, rather than just vanishing as an empty result.
;
;     Drive-letter lookup tries the modern Storage module first (Get-Partition
;     -DiskNumber) - direct DriveLetter property, no associator hop, generally more
;     reliable than the older Win32_DiskDrive -> Win32_DiskPartition -> Win32_LogicalDisk
;     CIM chain (that chain was confirmed flaky against real data: the same
;     still-connected drive's letter association was present in one capture and
;     silently missing four minutes later).
;
;     BUT: real "before"-stage captures (drives not yet repaired) showed Get-Partition
;     consistently finding a letter for only ~1 of N connected drives, even though
;     Windows Explorer clearly showed drive letters for all of them - not a mount-timing
;     issue. Working theory (unconfirmed - these are the bad/write-damaged drives under
;     investigation): a drive can get a letter from the volume manager without having a
;     partition table entry Get-Partition can enumerate, e.g. if it's RAW/corrupted or
;     was never partitioned. "after" captures (post-repair, freshly re-partitioned by
;     UMPTool) don't show this problem. To get real evidence instead of guessing further,
;     a failed Get-Partition now falls back to the old CIM associator chain (two
;     different mechanisms failing identically on the same disk is much less likely
;     than either alone), and any disk that still resolves nothing gets a DIAG| line
;     with the actual exception message - previously silently swallowed via catch {}.
GetUsbDiskInfo() {
    outPath := A_Temp . "\umptool_usbinfo_out.txt"
    scriptPath := A_Temp . "\umptool_usbinfo.ps1"
    try FileDelete(outPath)

    ; Built line-by-line (not as one big continuation-section literal) to avoid any
    ; ambiguity about how AHK v2 handles literal $ characters inside a multi-line string.
    ; AHK has no special meaning for $ at all, so no escaping of it is needed here -
    ; each line below is just plain concatenation of literal PowerShell source text.
    psLines := []
    psLines.Push("$outPath = '" . outPath . "'")
    psLines.Push("try {")
    psLines.Push("    $disks = Get-CimInstance Win32_DiskDrive")
    psLines.Push("    foreach ($disk in $disks) {")
    psLines.Push("        $vid = ''")
    psLines.Push("        $pidVal = ''")
    psLines.Push("        if ($disk.PNPDeviceID -match 'VID_([0-9A-Fa-f]{4})') { $vid = $matches[1] }")
    psLines.Push("        if ($disk.PNPDeviceID -match 'PID_([0-9A-Fa-f]{4})') { $pidVal = $matches[1] }")
    psLines.Push("        $driveLetters = @()")
    psLines.Push("        $lastErr = ''")
    psLines.Push("        for ($attempt = 1; $attempt -le 2; $attempt++) {")
    psLines.Push("            try {")
    psLines.Push("                $parts = Get-Partition -DiskNumber $disk.Index -ErrorAction Stop")
    psLines.Push("                foreach ($p in $parts) {")
    psLines.Push("                    if ($p.DriveLetter -match '[A-Za-z]') { $driveLetters += ($p.DriveLetter + ':') }")
    psLines.Push("                }")
    psLines.Push("            } catch { $lastErr = $_.Exception.Message }")
    psLines.Push("            if ($driveLetters.Count -gt 0) { break }")
    psLines.Push("            Start-Sleep -Milliseconds 400")
    psLines.Push("        }")
    psLines.Push("        if ($driveLetters.Count -eq 0) {")
    psLines.Push("            try {")
    psLines.Push("                $cimParts = Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction Stop")
    psLines.Push("                foreach ($part in $cimParts) {")
    psLines.Push("                    $logicalDisks = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction Stop")
    psLines.Push("                    foreach ($ld in $logicalDisks) { $driveLetters += $ld.DeviceID }")
    psLines.Push("                }")
    psLines.Push("            } catch { $lastErr = $_.Exception.Message }")
    psLines.Push("        }")
    psLines.Push("        if ($driveLetters.Count -eq 0 -and $lastErr -ne '') {")
    psLines.Push("            Add-Content -Path $outPath -Value ('DIAG|Disk ' + $disk.Index + ' (' + $disk.Model + '): Get-Partition + CIM fallback both failed to resolve a drive letter. Last error: ' + $lastErr)")
    psLines.Push("        } elseif ($driveLetters.Count -eq 0) {")
    psLines.Push("            Add-Content -Path $outPath -Value ('DIAG|Disk ' + $disk.Index + ' (' + $disk.Model + '): Get-Partition + CIM fallback both returned zero partitions/logical disks, no exception thrown')")
    psLines.Push("        }")
    psLines.Push("        if ($driveLetters.Count -eq 0) { $driveLetters = @('') }")
    psLines.Push("        foreach ($dl in $driveLetters) {")
    psLines.Push("            $line = $dl + '|' + $disk.SerialNumber + '|' + $vid + '|' + $pidVal + '|' + $disk.Model + '|' + $disk.InterfaceType + '|' + $disk.PNPDeviceID")
    psLines.Push("            Add-Content -Path $outPath -Value $line")
    psLines.Push("        }")
    psLines.Push("    }")
    psLines.Push("    if ($disks.Count -eq 0) { Add-Content -Path $outPath -Value 'INFO|No Win32_DiskDrive instances returned at all' }")
    psLines.Push("} catch {")
    psLines.Push("    Add-Content -Path $outPath -Value ('ERROR|' + $_.Exception.Message)")
    psLines.Push("}")

    psScript := ""
    for l in psLines
        psScript .= l . "`r`n"

    try {
        f := FileOpen(scriptPath, "w", "UTF-8")
        f.Write(psScript)
        f.Close()
    } catch as e {
        return []
    }

    try RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' . scriptPath . '"', , "Hide")

    result := []
    if FileExist(outPath) {
        content := ""
        try content := FileRead(outPath)
        for line in StrSplit(content, "`n", "`r") {
            line := Trim(line)
            if (line = "")
                continue
            parts := StrSplit(line, "|")
            if (parts.Length >= 2 && (parts[1] = "ERROR" || parts[1] = "INFO" || parts[1] = "DIAG")) {
                result.Push({driveLetter: "", serial: parts[1], vid: "", pidVal: "",
                             model: (parts.Length >= 2 ? parts[2] : ""), interfaceType: "", pnpId: ""})
                continue
            }
            if (parts.Length >= 7)
                result.Push({driveLetter: Trim(parts[1], ":"), serial: parts[2], vid: parts[3],
                             pidVal: parts[4], model: parts[5], interfaceType: parts[6], pnpId: parts[7]})
        }
    }
    return result
}

CaptureSnapshot(stage) {
    if !WinExist("ahk_exe " . targetExe) {
        MsgBox("UMPTool window not found — is it open?")
        return
    }
    mainHwnd := WinExist("ahk_exe " . targetExe)
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")

    children := CollectAllDescendants(mainHwnd)

    items := []
    for hwnd in children {
        cls := ""
        try cls := WinGetClass("ahk_id " . hwnd)
        if (cls = "")
            continue
        if !(InStr(cls, "Edit") = 1 || InStr(cls, "msctls_progress32") = 1 || InStr(cls, "Static") = 1 || InStr(cls, "Button") = 1)
            continue
        txt := ""
        ; NOTE: must pass the raw hwnd integer here, NOT "ahk_id " . hwnd -
        ; confirmed via diagnostic that the "ahk_id" form throws "Target control not found"
        ; for this application, while the bare integer works correctly.
        try txt := ControlGetText(hwnd)
        if (txt = "")
            continue
        items.Push({hwnd: hwnd, ctrlClass: cls, text: txt})
    }

    for item in items {
        txt := StrReplace(item.text, "`t", " ")
        txt := StrReplace(txt, "`r`n", " | ")
        txt := StrReplace(txt, "`n", " | ")
        line := ts . "`t" . stage . "`t" . item.hwnd . "`t" . item.ctrlClass . "`t" . txt . "`n"
        FileAppend(line, logFile)
    }

    ; --- Disk correlation info (all disks, not just USB - see GetUsbDiskInfo notes),
    ;     tagged with a distinct pseudo-class so the parser can tell it apart from
    ;     real UMPTool control captures ---
    usbInfo := GetUsbDiskInfo()
    for d in usbInfo {
        line := ts . "`t" . stage . "`t0`tUSB_DISK_INFO`t" . d.driveLetter . "|" . d.serial . "|" . d.vid . "|" . d.pidVal . "|" . d.model . "|" . d.interfaceType . "|" . d.pnpId . "`n"
        FileAppend(line, logFile)
    }

    TrayTip("Snapshot [" . stage . "] captured — " . items.Length . " UI fields, " . usbInfo.Length . " USB disk(s).", "UMPTool Logger", 1)
}

F9::CaptureSnapshot("before")
F10::CaptureSnapshot("after")
F12::ExitApp()
