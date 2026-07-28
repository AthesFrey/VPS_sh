@echo off
setlocal EnableExtensions

REM This script is a CMD launcher with an embedded PowerShell management script.
REM All user-facing text and comments inside this file are in English.

title Windows 11 Hibernation Manager

set "THIS_SCRIPT=%~f0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Administrator privileges are required.
    echo Requesting elevation...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:THIS_SCRIPT -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$marker='### POWERSHELL SCRIPT START ###'; $raw=Get-Content -Raw -LiteralPath $env:THIS_SCRIPT; $idx=$raw.LastIndexOf($marker); if($idx -lt 0){Write-Error 'Embedded PowerShell section was not found.'; exit 1}; $ps=$raw.Substring($idx + $marker.Length); Invoke-Expression $ps"

exit /b %errorlevel%

### POWERSHELL SCRIPT START ###

# Embedded PowerShell script.
# This section is executed by the CMD launcher above.

$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Output encoding is not critical for this script.
}

$Host.UI.RawUI.WindowTitle = 'Windows 11 Hibernation Manager'

$PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$FlyoutKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
$HibernateFile = "$env:SystemDrive\hiberfil.sys"

function Pause-Menu {
    Write-Host ''
    [void](Read-Host 'Press Enter to continue')
}

function Write-Header {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Clear-Host
    Write-Host '=========================================='
    Write-Host $Title
    Write-Host '=========================================='
    Write-Host ''
}

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    $code = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $code
        Output   = $output
    }
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    if ($Bytes -le 0) {
        return '0 bytes'
    }

    return ('{0:N2} GiB ({1:N0} bytes)' -f ($Bytes / 1GB), $Bytes)
}

function Get-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $property = $item.PSObject.Properties[$Name]

        if ($null -eq $property) {
            return $null
        }

        return [int]$property.Value
    } catch {
        return $null
    }
}

function Get-HibernationInfo {
    $hibernateEnabled = Get-RegistryDwordValue -Path $PowerKey -Name 'HibernateEnabled'
    $hiberFileType = Get-RegistryDwordValue -Path $PowerKey -Name 'HiberFileType'
    $showHibernateOption = Get-RegistryDwordValue -Path $FlyoutKey -Name 'ShowHibernateOption'

    $fileItem = $null

    try {
        $fileItem = Get-Item -LiteralPath $HibernateFile -Force -ErrorAction SilentlyContinue
    } catch {
        $fileItem = $null
    }

    $fileExists = $null -ne $fileItem
    $fileSize = 0

    if ($fileExists) {
        $fileSize = [Int64]$fileItem.Length
    }

    $shouldShowInStartMenu = $false

    if ($hibernateEnabled -eq 1) {
        $shouldShowInStartMenu = $true
    }

    return [PSCustomObject]@{
        HibernateEnabled       = $hibernateEnabled
        HiberFileType          = $hiberFileType
        HibernateFilePath      = $HibernateFile
        HibernateFileExists    = $fileExists
        HibernateFileSizeBytes = $fileSize
        ShowHibernateOption    = $showHibernateOption
        ShouldShowInStartMenu  = $shouldShowInStartMenu
    }
}

function Set-StartMenuHibernateOption {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Show
    )

    $value = 0

    if ($Show) {
        $value = 1
    }

    try {
        New-Item -Path $FlyoutKey -Force | Out-Null
        New-ItemProperty -Path $FlyoutKey -Name 'ShowHibernateOption' -PropertyType DWord -Value $value -Force | Out-Null

        if ($Show) {
            Write-Host 'Start menu Hibernate option: Enabled'
        } else {
            Write-Host 'Start menu Hibernate option: Removed'
        }

        return $true
    } catch {
        Write-Host 'ERROR: Failed to update the Start menu Hibernate option.'
        Write-Host $_.Exception.Message
        return $false
    }
}

function Sync-StartMenuHibernateOption {
    $info = Get-HibernationInfo

    if ($info.ShouldShowInStartMenu) {
        [void](Set-StartMenuHibernateOption -Show $true)
    } else {
        [void](Set-StartMenuHibernateOption -Show $false)
    }
}

function Restart-StartMenu {
    Write-Host 'Refreshing Start menu components...'

    try {
        Stop-Process -Name 'StartMenuExperienceHost' -Force -ErrorAction SilentlyContinue
        Stop-Process -Name 'ShellExperienceHost' -Force -ErrorAction SilentlyContinue
    } catch {
        # The Start menu processes may not be running. This is not a critical error.
    }

    Write-Host 'Start menu refresh requested.'
    Write-Host 'If the option still does not appear or disappear, sign out or restart Windows.'
}

function Show-HibernationInfo {
    $info = Get-HibernationInfo

    Write-Host "OS drive: $env:SystemDrive"
    Write-Host "Expected hibernation file: $($info.HibernateFilePath)"
    Write-Host ''

    if ($info.HibernateEnabled -eq 1) {
        Write-Host 'Hibernate registry state: Enabled'
    } elseif ($info.HibernateEnabled -eq 0) {
        Write-Host 'Hibernate registry state: Disabled'
    } else {
        Write-Host 'Hibernate registry state: Unknown or not set'
    }

    if ($null -eq $info.HiberFileType) {
        Write-Host 'Hibernation file type registry value: Not set'
    } else {
        Write-Host "Hibernation file type registry value: $($info.HiberFileType)"
    }

    if ($info.HibernateFileExists) {
        Write-Host 'Hibernation file: Found'
        Write-Host "Hibernation file size: $(Format-ByteSize -Bytes $info.HibernateFileSizeBytes)"
    } else {
        Write-Host 'Hibernation file: Not found'
    }

    if ($null -eq $info.ShowHibernateOption) {
        Write-Host 'Start menu Hibernate registry option: Not set'
    } elseif ($info.ShowHibernateOption -eq 1) {
        Write-Host 'Start menu Hibernate registry option: Enabled'
    } else {
        Write-Host 'Start menu Hibernate registry option: Removed'
    }

    if ($info.ShouldShowInStartMenu) {
        Write-Host 'Start menu sync decision: Enable Hibernate option'
    } else {
        Write-Host 'Start menu sync decision: Remove Hibernate option'
    }

    Write-Host ''
    Write-Host 'Supported relocation target: None'
    Write-Host 'D:\hiberfil.sys relocation: Not supported'
}

function Enable-Hibernation {
    Write-Header 'Enable or Rebuild Hibernation'

    Write-Host 'This will enable hibernation, rebuild hiberfil.sys, and show Hibernate in the Start power menu.'
    Write-Host ''
    Write-Host 'Step 1: Turning hibernation off temporarily...'
    [void](Invoke-PowerCfg -Arguments @('/hibernate', 'off'))

    Start-Sleep -Seconds 2

    Write-Host 'Step 2: Turning hibernation on...'
    $enableResult = Invoke-PowerCfg -Arguments @('/hibernate', 'on')

    if ($enableResult.ExitCode -ne 0) {
        Write-Host ''
        Write-Host 'ERROR: Failed to enable hibernation.'
        Write-Host ''
        Write-Host 'Possible reasons:'
        Write-Host '- The firmware does not support hibernation.'
        Write-Host '- Hibernation is blocked by system policy.'
        Write-Host '- The OS configuration does not allow hibernation.'
        Write-Host ''

        Sync-StartMenuHibernateOption
        Pause-Menu
        return
    }

    Write-Host 'Step 3: Setting hibernation file type to full...'
    $typeResult = Invoke-PowerCfg -Arguments @('/hibernate', '/type', 'full')

    if ($typeResult.ExitCode -ne 0) {
        Write-Host 'WARNING: Failed to set the hibernation file type to full.'
        Write-Host 'Hibernation may still work, but the file type should be checked manually.'
        Write-Host ''
    }

    Write-Host 'Step 4: Synchronizing Start menu Hibernate option...'
    Sync-StartMenuHibernateOption

    Write-Host 'Step 5: Refreshing Start menu...'
    Restart-StartMenu

    Write-Host ''
    Write-Host 'Current status:'
    Write-Host ''
    Show-HibernationInfo

    Write-Host ''
    Write-Host 'Done.'
    Pause-Menu
}

function Disable-Hibernation {
    Write-Header 'Disable Hibernation'

    Write-Host 'This will disable hibernation, remove hiberfil.sys, and remove Hibernate from the Start power menu.'
    Write-Host 'Fast Startup may also be disabled.'
    Write-Host ''

    $confirm = Read-Host 'Type YES to continue'

    if ($confirm -ne 'YES') {
        Write-Host ''
        Write-Host 'Operation cancelled.'
        Pause-Menu
        return
    }

    Write-Host ''
    Write-Host 'Step 1: Turning hibernation off...'
    $disableResult = Invoke-PowerCfg -Arguments @('/hibernate', 'off')

    if ($disableResult.ExitCode -ne 0) {
        Write-Host ''
        Write-Host 'ERROR: Failed to disable hibernation.'
        Write-Host ''
        Pause-Menu
        return
    }

    Write-Host 'Step 2: Removing Hibernate from the Start power menu...'
    [void](Set-StartMenuHibernateOption -Show $false)

    Write-Host 'Step 3: Refreshing Start menu...'
    Restart-StartMenu

    Write-Host ''
    Write-Host 'Current status:'
    Write-Host ''
    Show-HibernationInfo

    Write-Host ''
    Write-Host 'Done.'
    Pause-Menu
}

function Repair-StartMenuOption {
    Write-Header 'Repair Start Menu Hibernate Option'

    Write-Host 'This will enable the Start menu Hibernate option only when hibernation is enabled.'
    Write-Host 'If hibernation is disabled, the Start menu Hibernate option will be removed.'
    Write-Host ''

    Sync-StartMenuHibernateOption
    Restart-StartMenu

    Write-Host ''
    Write-Host 'Current status:'
    Write-Host ''
    Show-HibernationInfo

    Write-Host ''
    Write-Host 'Done.'
    Pause-Menu
}

function Show-Status {
    Write-Header 'Hibernation Status'
    Show-HibernationInfo
    Pause-Menu
}

while ($true) {
    Write-Header 'Windows 11 Hibernation Manager'

    Write-Host "OS drive: $env:SystemDrive"
    Write-Host "Hibernation file path: $HibernateFile"
    Write-Host ''
    Write-Host 'Important:'
    Write-Host 'Windows requires hiberfil.sys to stay on the OS drive.'
    Write-Host 'Moving hiberfil.sys to D: is not supported by Windows.'
    Write-Host ''
    Write-Host 'Select an option:'
    Write-Host ''
    Write-Host '[1] Enable or rebuild hibernation'
    Write-Host '[2] Disable hibernation'
    Write-Host '[3] Repair Start menu Hibernate option'
    Write-Host '[4] Show hibernation status'
    Write-Host '[5] Sign out Windows immediately'
    Write-Host '[6] Exit'
    Write-Host ''

    $choice = Read-Host 'Enter your choice'

    switch ($choice) {
        '1' { Enable-Hibernation }
        '2' { Disable-Hibernation }
        '3' { Repair-StartMenuOption }
        '4' { Show-Status }
        '5' { & "$env:SystemRoot\System32\shutdown.exe" /l /f; return }
        '6' { break }
        default {
            Write-Host ''
            Write-Host 'Invalid choice.'
            Pause-Menu
        }
    }
}



