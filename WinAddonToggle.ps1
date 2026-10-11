#Requires -Version 5.1
<#
.SYNOPSIS
    WinAddonToggle - active / désactive à la carte les composants "add-on" de Windows 10 / 11.

.DESCRIPTION
    Inspiré de tiny11builder (ntdevlabs), mais réversible et sélectif :
      - sur le système en cours (en ligne) : désactivation ET réactivation de chaque composant ;
      - sur une image Windows montée (hors ligne, -ImagePath) : désactivation uniquement.

    Les composants sont décrits dans addons.json (paquets Appx, capacités Windows,
    fonctionnalités optionnelles, ou traitements spéciaux pour Edge et OneDrive).

    Sans paramètre, le script ouvre une interface graphique.

.PARAMETER List
    Affiche l'état de chaque composant et quitte.

.PARAMETER Disable
    Identifiants des composants à désactiver (voir -List). Mots-clés : base, extra, all.

.PARAMETER Enable
    Identifiants des composants à (ré)activer.

.PARAMETER ConfigFile
    Fichier profil JSON { "disable": [...], "enable": [...] } (exportable depuis la GUI).

.PARAMETER ImagePath
    Dossier d'une image Windows montée (ex. via Mount-WindowsImage / DISM). Mode hors ligne.

.PARAMETER KeepProvisioned
    Ne retire pas les paquets provisionnés : les nouveaux comptes recevront encore l'application.

.PARAMETER DryRun
    Simulation : affiche les actions sans rien modifier.

.EXAMPLE
    .\WinAddonToggle.ps1
    Ouvre l'interface graphique.

.EXAMPLE
    .\WinAddonToggle.ps1 -List

.EXAMPLE
    .\WinAddonToggle.ps1 -Disable Clipchamp,News,Weather,Solitaire -DryRun

.EXAMPLE
    .\WinAddonToggle.ps1 -Enable Weather

.EXAMPLE
    .\WinAddonToggle.ps1 -ConfigFile .\profil-client.json

.EXAMPLE
    .\WinAddonToggle.ps1 -ImagePath D:\mount -Disable base
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string[]]$Disable,
    [string[]]$Enable,
    [string]$ConfigFile,
    [string]$ImagePath,
    [string]$CatalogPath,
    [switch]$KeepProvisioned,
    [switch]$DryRun,
    [string]$LogDir
)

Set-StrictMode -Version 2.0

if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot 'addons.json' }
if (-not $LogDir)      { $LogDir      = Join-Path $env:ProgramData 'WinAddonToggle\logs' }

# ---------------------------------------------------------------------------
#  Relance : Windows PowerShell 5.1 obligatoire (module Appx) + élévation
# ---------------------------------------------------------------------------
function ConvertTo-ArgumentString {
    param([System.Collections.IDictionary]$Bound)
    $parts = foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { "-$k" } }
        elseif ($v -is [array]) { "-$k `"$($v -join ',')`"" }
        else { "-$k `"$v`"" }
    }
    return ($parts -join ' ')
}

$forwardArgs = ConvertTo-ArgumentString $PSBoundParameters

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'PowerShell 7 détecté : relance sous Windows PowerShell 5.1 (requis pour le module Appx)…' -ForegroundColor Yellow
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @($PSBoundParameters.GetEnumerator() | ForEach-Object {
        if ($_.Value -is [System.Management.Automation.SwitchParameter]) { if ($_.Value.IsPresent) { "-$($_.Key)" } }
        elseif ($_.Value -is [array]) { "-$($_.Key)"; ($_.Value -join ',') }
        else { "-$($_.Key)"; [string]$_.Value }
    })
    exit $LASTEXITCODE
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $isGui = -not ($List -or $Disable -or $Enable -or $ConfigFile)
    if ($isGui) {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardArgs"
        exit 0
    }
    Write-Error 'Ce script doit être exécuté en tant qu''administrateur.'
    exit 1
}

# ---------------------------------------------------------------------------
#  État global
# ---------------------------------------------------------------------------
$script:Offline               = [bool]$ImagePath
$script:DryRunMode            = [bool]$DryRun
$script:RemoveProvisionedMode = -not $KeepProvisioned
$script:RebootRequired        = $false
$script:Cache                 = $null
$script:LogSink               = $null
$script:LogFile               = $null
$script:Populating            = $false
$script:Ui                    = @{}

# ---------------------------------------------------------------------------
#  Journalisation
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO'
    )
    $line  = '{0} [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
    if ($script:LogSink) { & $script:LogSink $line }
}

# Exécute une action modifiante, en respectant le mode simulation. Retourne $true si succès.
function Invoke-Step {
    param([string]$StepDescription, [scriptblock]$StepAction)
    if ($script:DryRunMode) {
        Write-Log "[SIMULATION] $StepDescription"
        return $true
    }
    Write-Log $StepDescription 'STEP'
    try {
        $ErrorActionPreference = 'Stop'
        $null = & $StepAction
        return $true
    }
    catch {
        Write-Log "Échec : $($_.Exception.Message)" 'ERR'
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Outils : winget, ruches de registre hors ligne
# ---------------------------------------------------------------------------
function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Invoke-Winget {
    param([string[]]$WingetArgs)
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget introuvable (installez "App Installer" depuis le Microsoft Store).' }
    $ErrorActionPreference = 'Continue'
    $output = & $winget @WingetArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($l in ($output -split "`r?`n")) {
        $t = $l.Trim()
        # On filtre les barres de progression de winget
        if ($t -and $t -notmatch '^[\s\-\\|/█▒]+$' -and $t -notmatch '^\d+(\.\d+)?\s*(KB|MB|GB)\s*/') { Write-Log "  winget> $t" }
    }
    # -1978335189 = 0x8A15002B : déjà installé / aucune mise à jour applicable
    if ($code -ne 0 -and $code -ne -1978335189) { throw "winget a retourné le code $code" }
}

function Invoke-WithHive {
    param([string]$HiveFile, [string]$MountName, [scriptblock]$Body)
    if (-not (Test-Path $HiveFile)) { throw "Ruche introuvable : $HiveFile" }
    $null = & reg.exe load "HKLM\$MountName" $HiveFile
    if ($LASTEXITCODE -ne 0) { throw "Impossible de charger la ruche $HiveFile" }
    try { & $Body }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
        $null = & reg.exe unload "HKLM\$MountName"
    }
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord
}

# ---------------------------------------------------------------------------
#  Catalogue et inventaire
# ---------------------------------------------------------------------------
function Import-Catalog {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Catalogue introuvable : $Path" }
    $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($c in $json.components) {
        foreach ($p in 'appx', 'capabilities', 'features', 'special', 'warning', 'notes', 'set', 'category') {
            if (-not ($c.PSObject.Properties.Name -contains $p)) { $c | Add-Member -NotePropertyName $p -NotePropertyValue $null }
        }
        foreach ($a in @($c.appx)) {
            if (-not $a) { continue }
            foreach ($p in 'storeId', 'winget') {
                if (-not ($a.PSObject.Properties.Name -contains $p)) { $a | Add-Member -NotePropertyName $p -NotePropertyValue $null }
            }
        }
    }
    return @($json.components)
}

function Update-SystemCache {
    Write-Log 'Inventaire du système (paquets, capacités, fonctionnalités)… cela peut prendre une minute.'
    $needCaps  = @($script:Catalog | Where-Object { $_.capabilities }).Count -gt 0
    $needFeats = @($script:Catalog | Where-Object { $_.features }).Count -gt 0
    if ($script:Offline) {
        $script:Cache = @{
            Appx  = @()
            Prov  = @(Get-AppxProvisionedPackage -Path $ImagePath -ErrorAction SilentlyContinue)
            Caps  = if ($needCaps)  { @(Get-WindowsCapability -Path $ImagePath -ErrorAction SilentlyContinue) } else { @() }
            Feats = if ($needFeats) { @(Get-WindowsOptionalFeature -Path $ImagePath -ErrorAction SilentlyContinue) } else { @() }
        }
    }
    else {
        $script:Cache = @{
            Appx  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
            Prov  = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
            Caps  = if ($needCaps)  { @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue) } else { @() }
            Feats = if ($needFeats) { @(Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue) } else { @() }
        }
    }
    Write-Log ("Inventaire : {0} paquets installés, {1} provisionnés, {2} capacités, {3} fonctionnalités." -f `
        $script:Cache.Appx.Count, $script:Cache.Prov.Count, $script:Cache.Caps.Count, $script:Cache.Feats.Count)
}

function Get-SystemBase {
    if ($script:Offline) { return $ImagePath } else { return "$env:SystemDrive\" }
}

function Get-EdgeExecutables {
    $base = Get-SystemBase
    @('Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'Program Files\Microsoft\Edge\Application\msedge.exe') |
        ForEach-Object { Join-Path $base $_ } | Where-Object { Test-Path $_ }
}

function Get-OneDriveFootprint {
    $base = Get-SystemBase
    $setups = @('Windows\System32\OneDriveSetup.exe', 'Windows\SysWOW64\OneDriveSetup.exe') |
        ForEach-Object { Join-Path $base $_ } | Where-Object { Test-Path $_ }
    $exes = @('Program Files\Microsoft OneDrive\OneDrive.exe', 'Program Files (x86)\Microsoft OneDrive\OneDrive.exe') |
        ForEach-Object { Join-Path $base $_ } | Where-Object { Test-Path $_ }
    if (-not $script:Offline) {
        $exes = @($exes) + @(Get-ChildItem -Path (Join-Path $base 'Users\*\AppData\Local\Microsoft\OneDrive\OneDrive.exe') -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    $blocked = $false
    if (-not $script:Offline) {
        $pol = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name DisableFileSyncNGSC -ErrorAction SilentlyContinue
        $blocked = [bool]($pol -and $pol.DisableFileSyncNGSC -eq 1)
    }
    [pscustomobject]@{ Setups = @($setups); Exes = @($exes | Where-Object { $_ }); Blocked = $blocked }
}

function Get-AddonState {
    param($Addon)
    $present = $false; $applicable = $false
    $details = New-Object System.Collections.Generic.List[string]

    foreach ($a in @($Addon.appx)) {
        if (-not $a) { continue }
        $applicable = $true
        $u = @($script:Cache.Appx | Where-Object { $_.Name -eq $a.name })
        $p = @($script:Cache.Prov | Where-Object { $_.DisplayName -eq $a.name })
        if ($u.Count -or $p.Count) {
            $present = $true
            $flags = @()
            if ($u.Count) { $flags += 'installé' }
            if ($p.Count) { $flags += 'provisionné' }
            $details.Add("$($a.name) [$($flags -join '+')]")
        }
    }
    foreach ($pattern in @($Addon.capabilities)) {
        if (-not $pattern) { continue }
        foreach ($c in @($script:Cache.Caps | Where-Object { $_.Name -like $pattern })) {
            $applicable = $true
            if ([string]$c.State -eq 'Installed') { $present = $true; $details.Add("$($c.Name) [capacité installée]") }
        }
    }
    foreach ($pattern in @($Addon.features)) {
        if (-not $pattern) { continue }
        foreach ($f in @($script:Cache.Feats | Where-Object { $_.FeatureName -like $pattern })) {
            $applicable = $true
            if ([string]$f.State -eq 'Enabled') { $present = $true; $details.Add("$($f.FeatureName) [fonctionnalité activée]") }
        }
    }
    switch ($Addon.special) {
        'edge' {
            $applicable = $true
            $exe = @(Get-EdgeExecutables)
            if ($exe.Count) { $present = $true; $details.Add($exe -join ', ') }
        }
        'onedrive' {
            $applicable = $true
            $od = Get-OneDriveFootprint
            if ($script:Offline) {
                if ($od.Setups.Count) { $present = $true; $details.Add($od.Setups -join ', ') }
            }
            else {
                if ($od.Blocked) { $details.Add('bloqué par stratégie DisableFileSyncNGSC') }
                if ($od.Exes.Count) {
                    $details.Add("$($od.Exes.Count) installation(s)")
                    if (-not $od.Blocked) { $present = $true }
                }
            }
        }
    }

    $state = if ($present) { 'Présent' } elseif ($applicable) { 'Absent' } else { 'N/A' }
    if ($Addon.notes -and $state -ne 'Présent') { $details.Add($Addon.notes) }
    [pscustomobject]@{ State = $state; Detail = ($details -join ' ; ') }
}

# ---------------------------------------------------------------------------
#  Désactivation
# ---------------------------------------------------------------------------
function Disable-AppxItem {
    param($Item)
    $name = $Item.name
    if (-not $script:Offline) {
        foreach ($pkg in @($script:Cache.Appx | Where-Object { $_.Name -eq $name })) {
            $target = $pkg
            [void](Invoke-Step "Désinstallation de $($target.PackageFullName) (tous les utilisateurs)" {
                $target | Remove-AppxPackage -AllUsers
            })
        }
    }
    if ($script:Offline -or $script:RemoveProvisionedMode) {
        foreach ($prov in @($script:Cache.Prov | Where-Object { $_.DisplayName -eq $name })) {
            $pn = $prov.PackageName
            [void](Invoke-Step "Retrait du paquet provisionné $pn" {
                if ($script:Offline) { Remove-AppxProvisionedPackage -Path $ImagePath -PackageName $pn | Out-Null }
                else { Remove-AppxProvisionedPackage -Online -PackageName $pn | Out-Null }
            })
        }
    }
}

function Disable-CapabilityItem {
    param([string]$Pattern)
    foreach ($c in @($script:Cache.Caps | Where-Object { $_.Name -like $Pattern -and [string]$_.State -eq 'Installed' })) {
        $n = $c.Name
        [void](Invoke-Step "Suppression de la capacité $n" {
            $r = if ($script:Offline) { Remove-WindowsCapability -Path $ImagePath -Name $n } else { Remove-WindowsCapability -Online -Name $n }
            if ($r -and $r.RestartNeeded) { $script:RebootRequired = $true }
        })
    }
}

function Disable-FeatureItem {
    param([string]$Pattern)
    foreach ($f in @($script:Cache.Feats | Where-Object { $_.FeatureName -like $Pattern -and [string]$_.State -eq 'Enabled' })) {
        $n = $f.FeatureName
        [void](Invoke-Step "Désactivation de la fonctionnalité $n" {
            $r = if ($script:Offline) { Disable-WindowsOptionalFeature -Path $ImagePath -FeatureName $n }
                 else { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart }
            if ($r -and $r.RestartNeeded) { $script:RebootRequired = $true }
        })
    }
}

function Disable-Edge {
    if ($script:Offline) {
        foreach ($rel in 'Program Files (x86)\Microsoft\Edge', 'Program Files (x86)\Microsoft\EdgeCore') {
            $dir = Join-Path $ImagePath $rel
            if (Test-Path $dir) { [void](Invoke-Step "Suppression de $dir" { Remove-Item -Path $dir -Recurse -Force }) }
        }
        [void](Invoke-Step 'Image : blocage de la réinstallation d''Edge et nettoyage de l''entrée de désinstallation' {
            Invoke-WithHive -HiveFile (Join-Path $ImagePath 'Windows\System32\config\SOFTWARE') -MountName 'WAT_SOFT' -Body {
                Set-RegDword -Path 'HKLM:\WAT_SOFT\Microsoft\EdgeUpdate' -Name 'DoNotUpdateToEdgeWithChromium' -Value 1
                Remove-Item -Path 'HKLM:\WAT_SOFT\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -Recurse -Force -ErrorAction SilentlyContinue
            }
        })
        return
    }

    $roots = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application", "$env:ProgramFiles\Microsoft\Edge\Application") | Where-Object { Test-Path $_ }
    $setup = @(foreach ($r in $roots) { Get-ChildItem -Path $r -Filter setup.exe -Recurse -ErrorAction SilentlyContinue }) |
        Where-Object { $_.Directory.Name -eq 'Installer' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $setup) { Write-Log 'Programme de désinstallation d''Edge introuvable.' 'WARN'; return }

    [void](Invoke-Step "Désinstallation de Microsoft Edge ($($setup.FullName))" {
        Get-Process -Name msedge -ErrorAction SilentlyContinue | Stop-Process -Force
        $p = Start-Process -FilePath $setup.FullName -ArgumentList '--uninstall', '--system-level', '--verbose-logging', '--force-uninstall' -Wait -PassThru
        # 19 = UNINSTALL_SUCCESSFUL dans l'installeur Chromium
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 19) {
            throw "setup.exe a retourné $($p.ExitCode) (hors EEE, Microsoft bloque la désinstallation d'Edge)"
        }
    })
    [void](Invoke-Step 'Blocage de la réinstallation d''Edge via EdgeUpdate (best effort)' {
        Set-RegDword -Path 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' -Name 'DoNotUpdateToEdgeWithChromium' -Value 1
    })
}

function Start-UninstallString {
    param([string]$UninstallString)
    if ($UninstallString -match '^\s*"?(?<exe>[^"]+?\.exe)"?\s*(?<args>.*)$') {
        $p = Start-Process -FilePath $Matches['exe'] -ArgumentList $Matches['args'] -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Code de retour $($p.ExitCode)" }
    }
    else { throw "Chaîne de désinstallation non reconnue : $UninstallString" }
}

function Disable-OneDrive {
    if ($script:Offline) {
        foreach ($rel in 'Windows\System32\OneDriveSetup.exe', 'Windows\SysWOW64\OneDriveSetup.exe') {
            $file = Join-Path $ImagePath $rel
            if (Test-Path $file) {
                [void](Invoke-Step "Suppression de $file" {
                    $null = & takeown.exe /f $file
                    $null = & icacls.exe $file /grant '*S-1-5-32-544:F'
                    Remove-Item -Path $file -Force
                })
            }
        }
        [void](Invoke-Step 'Image : stratégie DisableFileSyncNGSC' {
            Invoke-WithHive -HiveFile (Join-Path $ImagePath 'Windows\System32\config\SOFTWARE') -MountName 'WAT_SOFT' -Body {
                Set-RegDword -Path 'HKLM:\WAT_SOFT\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1
            }
        })
        [void](Invoke-Step 'Image : retrait de OneDriveSetup du profil par défaut' {
            Invoke-WithHive -HiveFile (Join-Path $ImagePath 'Users\Default\NTUSER.DAT') -MountName 'WAT_DEFAULT' -Body {
                Remove-ItemProperty -Path 'HKLM:\WAT_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
            }
        })
        return
    }

    [void](Invoke-Step 'Arrêt de OneDrive' { Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force })

    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
    )
    $done = $false
    foreach ($k in $uninstallKeys) {
        $entry = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($entry -and $entry.PSObject.Properties['UninstallString'] -and $entry.UninstallString) {
            $us = [string]$entry.UninstallString
            if ($us -notmatch '/silent') { $us += ' /silent' }
            [void](Invoke-Step "Désinstallation de OneDrive ($k)" { Start-UninstallString $us })
            $done = $true
        }
    }
    if (-not $done) {
        $legacy = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($legacy) {
            [void](Invoke-Step "Désinstallation de OneDrive ($legacy /uninstall)" {
                $p = Start-Process -FilePath $legacy -ArgumentList '/uninstall' -Wait -PassThru
                if ($p.ExitCode -ne 0) { throw "Code de retour $($p.ExitCode)" }
            })
        }
        else { Write-Log 'Aucun désinstalleur OneDrive trouvé pour l''utilisateur courant.' 'WARN' }
    }

    [void](Invoke-Step 'Stratégie DisableFileSyncNGSC = 1 (bloque OneDrive pour tous les utilisateurs)' {
        Set-RegDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1
    })
    [void](Invoke-Step 'Retrait de OneDriveSetup du profil par défaut (nouveaux comptes)' {
        Invoke-WithHive -HiveFile "$env:SystemDrive\Users\Default\NTUSER.DAT" -MountName 'WAT_DEFAULT' -Body {
            Remove-ItemProperty -Path 'HKLM:\WAT_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
        }
    })
}

function Disable-Addon {
    param($Addon)
    foreach ($a in @($Addon.appx))         { if ($a) { Disable-AppxItem $a } }
    foreach ($c in @($Addon.capabilities)) { if ($c) { Disable-CapabilityItem $c } }
    foreach ($f in @($Addon.features))     { if ($f) { Disable-FeatureItem $f } }
    switch ($Addon.special) {
        'edge'     { Disable-Edge }
        'onedrive' { Disable-OneDrive }
    }
}

# ---------------------------------------------------------------------------
#  Activation (en ligne uniquement)
# ---------------------------------------------------------------------------
function Find-AppxManifest {
    param([string]$Name)
    $src = @($script:Cache.Appx | Where-Object { $_.Name -eq $Name -and $_.InstallLocation } | Sort-Object Version -Descending) | Select-Object -First 1
    if ($src) {
        $m = Join-Path $src.InstallLocation 'AppxManifest.xml'
        if (Test-Path $m) { return $m }
    }
    # Fichiers encore présents dans WindowsApps (paquet provisionné non retiré)
    $dirs = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Directory -Filter "$($Name)_*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_neutral_split\.|_neutral_~_' } | Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $m = Join-Path $d.FullName 'AppxManifest.xml'
        if (Test-Path $m) { return $m }
    }
    return $null
}

function Enable-AppxItem {
    param($Item)
    $name = $Item.name
    if (Get-AppxPackage -Name $name -ErrorAction SilentlyContinue) {
        Write-Log "$name est déjà installé pour l'utilisateur courant."
        return
    }
    $manifest = Find-AppxManifest $name
    if ($manifest) {
        $ok = Invoke-Step "Ré-enregistrement de $name depuis $manifest" { Add-AppxPackage -Register $manifest -DisableDevelopmentMode }
        if ($ok) { return }
    }
    if ($Item.storeId) {
        $id = $Item.storeId
        [void](Invoke-Step "Installation de $name depuis le Microsoft Store ($id)" {
            Invoke-Winget -WingetArgs @('install', '--id', $id, '--source', 'msstore', '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        })
        return
    }
    if ($Item.winget) {
        $id = $Item.winget
        [void](Invoke-Step "Installation de $name via winget ($id)" {
            Invoke-Winget -WingetArgs @('install', '--id', $id, '--source', 'winget', '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        })
        return
    }
    Write-Log "$name : pas de source de réinstallation connue (application retirée par Microsoft ou inexistante sur cette version de Windows)." 'WARN'
}

function Enable-CapabilityItem {
    param([string]$Pattern)
    foreach ($c in @($script:Cache.Caps | Where-Object { $_.Name -like $Pattern -and [string]$_.State -ne 'Installed' })) {
        $n = $c.Name
        [void](Invoke-Step "Ajout de la capacité $n (Windows Update requis)" {
            $r = Add-WindowsCapability -Online -Name $n
            if ($r -and $r.RestartNeeded) { $script:RebootRequired = $true }
        })
    }
}

function Enable-FeatureItem {
    param([string]$Pattern)
    foreach ($f in @($script:Cache.Feats | Where-Object { $_.FeatureName -like $Pattern -and [string]$_.State -ne 'Enabled' })) {
        $n = $f.FeatureName
        [void](Invoke-Step "Activation de la fonctionnalité $n" {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart
            if ($r -and $r.RestartNeeded) { $script:RebootRequired = $true }
        })
    }
}

function Enable-Edge {
    [void](Invoke-Step 'Suppression du blocage DoNotUpdateToEdgeWithChromium' {
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' -Name 'DoNotUpdateToEdgeWithChromium' -ErrorAction SilentlyContinue
    })
    if (@(Get-EdgeExecutables).Count) { Write-Log 'Edge est déjà installé.'; return }
    [void](Invoke-Step 'Installation de Microsoft Edge via winget' {
        Invoke-Winget -WingetArgs @('install', '--id', 'Microsoft.Edge', '--source', 'winget', '--exact', '--silent', '--scope', 'machine',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    })
}

function Enable-OneDrive {
    [void](Invoke-Step 'Suppression de la stratégie DisableFileSyncNGSC' {
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -ErrorAction SilentlyContinue
    })
    $od = Get-OneDriveFootprint
    $mine = @($od.Exes | Where-Object { $_ -like "$env:LOCALAPPDATA*" -or $_ -like "$env:ProgramFiles*" -or $_ -like "${env:ProgramFiles(x86)}*" })
    if (-not $mine.Count) {
        [void](Invoke-Step 'Installation de OneDrive via winget' {
            Invoke-Winget -WingetArgs @('install', '--id', 'Microsoft.OneDrive', '--source', 'winget', '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        })
    }
    else { Write-Log 'OneDrive est déjà installé pour l''utilisateur courant.' }

    $setup = "$env:SystemRoot\System32\OneDriveSetup.exe"
    if (Test-Path $setup) {
        [void](Invoke-Step 'Réactivation de OneDriveSetup dans le profil par défaut (nouveaux comptes)' {
            Invoke-WithHive -HiveFile "$env:SystemDrive\Users\Default\NTUSER.DAT" -MountName 'WAT_DEFAULT' -Body {
                $run = 'HKLM:\WAT_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run'
                if (-not (Test-Path $run)) { $null = New-Item -Path $run -Force }
                Set-ItemProperty -Path $run -Name 'OneDriveSetup' -Value "$setup /thfirstsetup"
            }
        })
    }
}

function Enable-Addon {
    param($Addon)
    foreach ($a in @($Addon.appx))         { if ($a) { Enable-AppxItem $a } }
    foreach ($c in @($Addon.capabilities)) { if ($c) { Enable-CapabilityItem $c } }
    foreach ($f in @($Addon.features))     { if ($f) { Enable-FeatureItem $f } }
    switch ($Addon.special) {
        'edge'     { Enable-Edge }
        'onedrive' { Enable-OneDrive }
    }
}

# ---------------------------------------------------------------------------
#  Plan d'exécution
# ---------------------------------------------------------------------------
function Resolve-Addons {
    param([string[]]$Ids)
    $tokens = @($Ids | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tokens) {
        $matched = switch ($t.ToLower()) {
            'all'   { $script:Catalog }
            'base'  { $script:Catalog | Where-Object { $_.set -eq 'base' } }
            'extra' { $script:Catalog | Where-Object { $_.set -eq 'extra' } }
            default { $script:Catalog | Where-Object { $_.id -eq $t } }
        }
        if (-not $matched) { throw "Composant inconnu : '$t'. Utilisez -List pour voir les identifiants." }
        foreach ($m in @($matched)) { if (-not $result.Contains($m)) { $result.Add($m) } }
    }
    return , $result.ToArray()
}

function Invoke-Plan {
    param([object[]]$ToDisable = @(), [object[]]$ToEnable = @())
    if ($script:Offline -and $ToEnable.Count) {
        Write-Log ("Activation impossible sur une image hors ligne, ignorée pour : {0}" -f (($ToEnable | ForEach-Object { $_.id }) -join ', ')) 'WARN'
        $ToEnable = @()
    }
    $script:RebootRequired = $false
    if (-not $script:Cache) { Update-SystemCache }
    if ($script:DryRunMode) { Write-Log '*** MODE SIMULATION : aucune modification ne sera effectuée ***' 'WARN' }

    foreach ($a in $ToDisable) {
        $st = Get-AddonState $a
        if ($st.State -ne 'Présent') { Write-Log "$($a.name) : déjà absent ($($st.State)), rien à faire."; continue }
        Write-Log "──── Désactivation : $($a.name)"
        if ($a.warning) { Write-Log $a.warning 'WARN' }
        Disable-Addon $a
    }
    foreach ($a in $ToEnable) {
        $st = Get-AddonState $a
        if ($st.State -eq 'N/A') { Write-Log "$($a.name) : non applicable sur ce système." 'WARN'; continue }
        Write-Log "──── Activation : $($a.name)"
        Enable-Addon $a
    }
    Write-Log 'Terminé.' 'OK'
    if ($script:RebootRequired) { Write-Log 'Un redémarrage est nécessaire pour finaliser certaines modifications.' 'WARN' }
    Write-Log "Journal : $script:LogFile"
}

# ---------------------------------------------------------------------------
#  Interface graphique
# ---------------------------------------------------------------------------
function Update-PlannedActions {
    foreach ($row in $script:Ui.Grid.Rows) {
        $info = $row.Tag
        if (-not $info) { continue }
        $keep = [bool]$row.Cells['Keep'].Value
        $act = ''
        if ($info.State -eq 'Présent' -and -not $keep) { $act = 'Désactiver' }
        elseif ($info.State -eq 'Absent' -and $keep -and -not $script:Offline) { $act = 'Activer' }
        $row.Cells['Action'].Value = $act
        $row.Cells['Action'].Style.BackColor = switch ($act) {
            'Désactiver' { [System.Drawing.Color]::MistyRose }
            'Activer'    { [System.Drawing.Color]::Honeydew }
            default      { [System.Drawing.Color]::Empty }
        }
    }
}

function Update-GridRows {
    $grid = $script:Ui.Grid
    $script:Populating = $true
    try {
        $grid.Rows.Clear()
        Update-SystemCache
        foreach ($addon in $script:Catalog) {
            $st  = Get-AddonState $addon
            $idx = $grid.Rows.Add()
            $row = $grid.Rows[$idx]
            $row.Tag = [pscustomobject]@{ Addon = $addon; State = $st.State }
            $row.Cells['Keep'].Value     = ($st.State -eq 'Présent')
            $row.Cells['Name'].Value     = $addon.name
            $row.Cells['Category'].Value = $addon.category
            $row.Cells['State'].Value    = $st.State
            $row.Cells['Detail'].Value   = $st.Detail
            if ($addon.warning) { $row.Cells['Name'].ToolTipText = $addon.warning; $row.Cells['Name'].Value = "$($addon.name)  ⚠" }
            if ($st.State -eq 'N/A' -or ($script:Offline -and $st.State -ne 'Présent')) {
                $row.Cells['Keep'].ReadOnly = $true
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
            }
        }
    }
    finally { $script:Populating = $false }
    Update-PlannedActions
}

function Set-UiBusy {
    param([bool]$Busy)
    foreach ($c in $script:Ui.Buttons) { $c.Enabled = -not $Busy }
    $script:Ui.Grid.Enabled = -not $Busy
    $script:Ui.Form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

function Set-RowsKeep {
    param([scriptblock]$Predicate)
    $script:Populating = $true
    try {
        foreach ($row in $script:Ui.Grid.Rows) {
            if ($row.Cells['Keep'].ReadOnly) { continue }
            $r = & $Predicate $row.Tag
            if ($null -ne $r) { $row.Cells['Keep'].Value = [bool]$r }
        }
    }
    finally { $script:Populating = $false }
    Update-PlannedActions
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinAddonToggle — composants Windows à la carte'
    $form.Size = New-Object System.Drawing.Size(1150, 780)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:Ui.Form = $form

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 4
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 64)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 36)))
    $form.Controls.Add($layout)

    # En-tête
    $target = if ($script:Offline) { "Image hors ligne : $ImagePath (désactivation uniquement)" }
              else { $os = Get-CimInstance Win32_OperatingSystem; "$($os.Caption) — build $($os.BuildNumber) — $env:COMPUTERNAME" }
    $header = New-Object System.Windows.Forms.Label
    $header.Dock = 'Fill'; $header.TextAlign = 'MiddleLeft'
    $header.Text = "Cible : $target`nCoché = composant conservé / à activer · Décoché = à retirer · ⚠ = survolez le nom pour l'avertissement"
    $layout.Controls.Add($header, 0, 0)

    # Grille
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false; $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    $colKeep = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colKeep.Name = 'Keep'; $colKeep.HeaderText = 'Conserver'; $colKeep.FillWeight = 9
    [void]$grid.Columns.Add($colKeep)
    foreach ($def in @(@('Name', 'Composant', 26), @('Category', 'Catégorie', 17), @('State', 'État', 9), @('Action', 'Action prévue', 11), @('Detail', 'Détail', 55))) {
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $def[0]; $c.HeaderText = $def[1]; $c.FillWeight = $def[2]; $c.ReadOnly = $true
        [void]$grid.Columns.Add($c)
    }
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($script:Ui.Grid.IsCurrentCellDirty) { [void]$script:Ui.Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $grid.Add_CellValueChanged({ if (-not $script:Populating) { Update-PlannedActions } })
    $layout.Controls.Add($grid, 0, 1)
    $script:Ui.Grid = $grid

    # Options et boutons
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.WrapContents = $true; $panel.Padding = New-Object System.Windows.Forms.Padding(2)
    $layout.Controls.Add($panel, 0, 2)

    $chkProv = New-Object System.Windows.Forms.CheckBox
    $chkProv.Text = 'Retirer aussi les paquets provisionnés (nouveaux comptes)'; $chkProv.AutoSize = $true
    $chkProv.Checked = $script:RemoveProvisionedMode
    $chkDry = New-Object System.Windows.Forms.CheckBox
    $chkDry.Text = 'Mode simulation'; $chkDry.AutoSize = $true; $chkDry.Checked = $script:DryRunMode
    $panel.Controls.AddRange(@($chkProv, $chkDry))
    $script:Ui.ChkProv = $chkProv; $script:Ui.ChkDry = $chkDry

    $newButton = {
        param([string]$Text, [scriptblock]$OnClick)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text; $b.AutoSize = $true; $b.Height = 30
        $b.Add_Click($OnClick)
        $panel.Controls.Add($b)
        $b
    }

    $buttons = @()
    $buttons += & $newButton 'Rafraîchir' { Set-UiBusy $true; try { Update-GridRows } finally { Set-UiBusy $false } }
    $buttons += & $newButton 'Réinitialiser la sélection' { Set-RowsKeep { param($i) $i.State -eq 'Présent' } }
    $buttons += & $newButton 'Décocher la liste de base' { Set-RowsKeep { param($i) if ($i.Addon.set -eq 'base') { $false } else { $null } } }
    $buttons += & $newButton 'Tout décocher' { Set-RowsKeep { param($i) $false } }
    $buttons += & $newButton 'Importer un profil…' {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Profil JSON (*.json)|*.json'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        try {
            $prof = Get-Content -Path $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            $dis = @($prof.disable); $en = @($prof.enable)
            Set-RowsKeep { param($i) if ($dis -contains $i.Addon.id) { $false } elseif ($en -contains $i.Addon.id) { $true } else { $null } }
            Write-Log "Profil chargé : $($dlg.FileName)" 'OK'
        }
        catch { Write-Log "Profil illisible : $($_.Exception.Message)" 'ERR' }
    }
    $buttons += & $newButton 'Exporter le profil…' {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Profil JSON (*.json)|*.json'; $dlg.FileName = 'profil-addons.json'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $prof = [ordered]@{ disable = @(); enable = @() }
        foreach ($row in $script:Ui.Grid.Rows) {
            if ($row.Tag.State -eq 'N/A') { continue }
            if ([bool]$row.Cells['Keep'].Value) { $prof.enable += $row.Tag.Addon.id } else { $prof.disable += $row.Tag.Addon.id }
        }
        $prof | ConvertTo-Json | Set-Content -Path $dlg.FileName -Encoding UTF8
        Write-Log "Profil exporté : $($dlg.FileName)" 'OK'
    }
    $btnApply = & $newButton 'Appliquer' {
        $dis = @(); $en = @()
        foreach ($row in $script:Ui.Grid.Rows) {
            switch ([string]$row.Cells['Action'].Value) {
                'Désactiver' { $dis += $row.Tag.Addon }
                'Activer'    { $en  += $row.Tag.Addon }
            }
        }
        if (($dis.Count + $en.Count) -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Aucune modification à appliquer.', 'WinAddonToggle')
            return
        }
        $lines = @()
        if ($dis.Count) { $lines += "À désactiver : $(($dis | ForEach-Object { $_.name }) -join ', ')" }
        if ($en.Count)  { $lines += "À activer : $(($en | ForEach-Object { $_.name }) -join ', ')" }
        if ($script:Ui.ChkDry.Checked) { $lines += '(mode simulation)' }
        $answer = [System.Windows.Forms.MessageBox]::Show(($lines -join "`n`n") + "`n`nContinuer ?", 'Confirmer',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $script:DryRunMode            = $script:Ui.ChkDry.Checked
        $script:RemoveProvisionedMode = $script:Ui.ChkProv.Checked
        Set-UiBusy $true
        try {
            Invoke-Plan -ToDisable $dis -ToEnable $en
            Update-GridRows
        }
        finally { Set-UiBusy $false }
        if ($script:RebootRequired) {
            [void][System.Windows.Forms.MessageBox]::Show('Un redémarrage est nécessaire pour finaliser certaines modifications.', 'WinAddonToggle')
        }
    }
    $btnApply.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $buttons += $btnApply
    $script:Ui.Buttons = $buttons

    # Journal
    $log = New-Object System.Windows.Forms.TextBox
    $log.Dock = 'Fill'; $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
    $log.Font = New-Object System.Drawing.Font('Consolas', 9); $log.BackColor = [System.Drawing.SystemColors]::Window
    $layout.Controls.Add($log, 0, 3)
    $script:Ui.Log = $log
    $script:LogSink = {
        param($line)
        $script:Ui.Log.AppendText($line + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $form.Add_Shown({
        Set-UiBusy $true
        try { Update-GridRows } finally { Set-UiBusy $false }
    })
    [void]$form.ShowDialog()
    $script:LogSink = $null
}

# ---------------------------------------------------------------------------
#  Point d'entrée
# ---------------------------------------------------------------------------
try {
    $null = New-Item -Path $LogDir -ItemType Directory -Force
    $script:LogFile = Join-Path $LogDir ('WinAddonToggle_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
}
catch { $script:LogFile = $null }

if ($script:Offline) {
    if (-not (Test-Path (Join-Path $ImagePath 'Windows\System32'))) {
        Write-Error "$ImagePath ne ressemble pas à une image Windows montée (Windows\System32 introuvable)."
        exit 1
    }
    Write-Log "Mode hors ligne sur l'image : $ImagePath"
}

try { $script:Catalog = Import-Catalog $CatalogPath }
catch { Write-Error $_.Exception.Message; exit 1 }

if ($List) {
    Update-SystemCache
    $rows = foreach ($a in $script:Catalog) {
        $s = Get-AddonState $a
        [pscustomobject]@{ Id = $a.id; Composant = $a.name; Groupe = $a.set; Etat = $s.State; Detail = $s.Detail }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    exit 0
}

if ($Disable -or $Enable -or $ConfigFile) {
    try {
        $toDisable = @(); $toEnable = @()
        if ($ConfigFile) {
            $prof = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($prof.PSObject.Properties['disable'] -and $prof.disable) { $toDisable += Resolve-Addons @($prof.disable) }
            if ($prof.PSObject.Properties['enable'] -and $prof.enable)   { $toEnable  += Resolve-Addons @($prof.enable) }
        }
        if ($Disable) { $toDisable += Resolve-Addons $Disable }
        if ($Enable)  { $toEnable  += Resolve-Addons $Enable }
        $conflict = @($toDisable | Where-Object { $toEnable -contains $_ })
        if ($conflict.Count) { throw "Composant(s) à la fois à activer et à désactiver : $(($conflict | ForEach-Object { $_.id }) -join ', ')" }
        Invoke-Plan -ToDisable $toDisable -ToEnable $toEnable
        if ($script:RebootRequired) { exit 3010 }
        exit 0
    }
    catch { Write-Log $_.Exception.Message 'ERR'; exit 1 }
}

Show-MainWindow
