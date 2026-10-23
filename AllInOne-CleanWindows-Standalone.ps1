# =============================================================================
# All-In-One Clean Windows (Self-Contained) - v3
# - Chaque tache tourne dans un job isole avec un TIMEOUT de 5 minutes
#   (si elle bloque, elle est tuee et le script passe a la suivante).
# - Installations 100% silencieuses (aucune fenetre, aucune sortie console).
# - Barre de progression globale + barre de progression par tache (en %).
# - Log complet : Documents\CLEANWINDOWSLOG.TXT
# - Resume (taches, durees, avertissements/erreurs) : Bureau\CLEANWINDOWS-RESUME.TXT
# - Options : -List (liste les taches) | -Only "NVIDIA,Services" | -Skip "Plex,Final Cleanup"
# - Apres redemarrage : Bureau\CLEANWINDOWS-APRES-REBOOT.TXT (comparaison avant / apres)
# =============================================================================

#Requires -Version 5.1

param(
    [string]$Only = '',   # ex. -Only "NVIDIA,Services" : ne lance que les taches dont le nom contient l'un de ces mots
    [string]$Skip = '',   # ex. -Skip "Plex,Final Cleanup" : ignore ces taches
    [switch]$List         # affiche la liste des taches (numeros / noms) puis quitte
)

# === Admin elevation (relance automatique en Administrateur, avec Bypass) ===
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
$env:PSExecutionPolicyPreference = 'Bypass'   # herite par les processus enfants (jobs)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        # Execute depuis la memoire (irm ... | iex) : le script n'existe pas sur le disque, impossible de le relancer en administrateur
        Write-Host "This script must run from a file. Download it first, then run it:" -ForegroundColor Yellow
        Write-Host '  irm "<URL>" -OutFile "$env:TEMP\AllInOne.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\AllInOne.ps1"' -ForegroundColor Gray
        Start-Sleep -Seconds 8
        Exit
    }
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    try {
        $fwd = ''
        if ($Only) { $fwd += ' -Only "' + ($Only -replace '"', '') + '"' }
        if ($Skip) { $fwd += ' -Skip "' + ($Skip -replace '"', '') + '"' }
        if ($List) { $fwd += ' -List' }
        Start-Process PowerShell.exe -ArgumentList (("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) + $fwd) -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "Administrator rights are required (UAC was refused). Exiting." -ForegroundColor Red
        Start-Sleep -Seconds 3
    }
    Exit
}

$Host.UI.RawUI.WindowTitle = "All-In-One Clean Windows (Self-Contained)"
$Host.UI.RawUI.BackgroundColor = "Black"
Clear-Host

# === Settings ===
$TaskTimeoutSeconds = 300          # Timeout applique a CHAQUE tache (5 minutes)
$CleanUserDownloads = $true        # $true = vide aussi le dossier Telechargements a la fin ($false pour le conserver)
$RunComponentCleanup = $true       # $true = nettoyage du magasin de composants (DISM) : libere des Go mais peut durer plusieurs minutes
$ProgressPreference = 'Continue'   # Necessaire pour afficher les barres

# === Logging (fichier uniquement : la console reste propre) ===
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = Join-Path $env:USERPROFILE 'Documents' }
$logPath = Join-Path $docs "CLEANWINDOWSLOG.TXT"
$tempDir = Join-Path $env:TEMP "CleanWindows"

try { if (-not (Test-Path -LiteralPath $docs)) { New-Item -ItemType Directory -Path $docs -Force | Out-Null } } catch { }
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$script:ActiveLog = $logPath
$script:Problems  = New-Object 'System.Collections.Generic.List[string]'
$script:Checks    = New-Object 'System.Collections.Generic.List[string]'
$script:RunStart  = Get-Date

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($Level -in 'WARNING', 'ERROR', 'JOBERR') { $script:Problems.Add($line) }
    if ($Message -like 'CHECK *') { $script:Checks.Add($line) }
    try {
        [IO.File]::AppendAllText($script:ActiveLog, $line + "`r`n", [Text.Encoding]::UTF8)
    } catch {
        # Dossier Documents inaccessible (redirection, droits...) : on bascule sur %TEMP% pour ne JAMAIS perdre le log
        $script:ActiveLog = Join-Path $env:TEMP 'CLEANWINDOWSLOG.TXT'
        try { [IO.File]::AppendAllText($script:ActiveLog, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
    }
}

Write-Log "=== All-In-One Clean Windows started ===" "INFO"
try {
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpuI = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $gpuI = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
    Write-Log ("OS: {0} (build {1}) | CPU: {2} | RAM: {3} GB | GPU: {4}" -f $os.Caption, $os.BuildNumber, $cpuI.Name, [math]::Round($os.TotalVisibleMemorySize / 1MB), $gpuI)
    Write-Log ("PowerShell: {0} | User: {1} | Script: {2} | Log: {3}" -f $PSVersionTable.PSVersion, $env:USERNAME, $PSCommandPath, $script:ActiveLog)
} catch { Write-Log "System information unavailable: $($_.Exception.Message)" "WARNING" }
try { if ((Get-Item -LiteralPath $script:ActiveLog -ErrorAction Stop).Length -le 0) { Write-Host "WARNING: the log file is empty - check write permissions on $script:ActiveLog" -ForegroundColor Yellow } } catch { }

# === Mesures AVANT (comparees a la fin du script et apres redemarrage) + type de machine ===
function Get-SystemMetrics {
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $svc = @(Get-Service -ErrorAction SilentlyContinue)
    [ordered]@{
        Processes       = @(Get-Process -ErrorAction SilentlyContinue).Count
        Svchost         = @(Get-Process -Name svchost -ErrorAction SilentlyContinue).Count
        ServicesRunning = @($svc | Where-Object { $_.Status -eq 'Running' }).Count
        ServicesAuto    = @($svc | Where-Object { $_.StartType -eq 'Automatic' }).Count
        RamUsedGB       = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        FreeDiskGB      = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
    }
}
$script:Baseline     = $null
$script:BaselineRef  = $null
$script:BaselineFile = Join-Path $docs 'CleanWindows-Baseline.json'
try {
    $script:Baseline = Get-SystemMetrics
    Write-Log ("BASELINE (before): " + (($script:Baseline.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '))
    if (Test-Path -LiteralPath $script:BaselineFile) {
        # Re-execution : on garde la toute premiere mesure comme reference ("avant" reel)
        $old = Get-Content -LiteralPath $script:BaselineFile -Raw | ConvertFrom-Json
        $script:BaselineRef = $old.Metrics
        Write-Log "Baseline from the first run kept as reference ($($old.Date))"
    } else {
        @{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Metrics = $script:Baseline } | ConvertTo-Json | Set-Content -LiteralPath $script:BaselineFile -Encoding UTF8
        $script:BaselineRef = [pscustomobject]$script:Baseline
    }
} catch { Write-Log "Baseline unavailable: $($_.Exception.Message)" "WARNING" }
$script:IsLaptop = $false
try {
    $ct = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    $script:IsLaptop = (@($ct | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }).Count -gt 0)
} catch { }
Write-Log ("Chassis: " + $(if ($script:IsLaptop) { 'portable (laptop) - battery-related settings are left alone' } else { 'desktop / VM' }))

# =============================================================================
# Fonctions disponibles DANS chaque job (chaque tache)
# Les jobs communiquent avec le script principal via des lignes de texte :
#   P|<pourcentage>|<message>   -> progression de la tache
#   L|<niveau>|<message>        -> ligne de log
#   PID|<id>                    -> processus enfant (tue en cas de timeout)
# =============================================================================
$Init = {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    function P { param([int]$Pct, [string]$Msg) "P|$Pct|$Msg" }
    function L { param([string]$Level, [string]$Msg) "L|$Level|$Msg" }

    function Set-Reg {
        param($Path, $Name, $Value, $Type = 'DWord')
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force
    }

    function Remove-Key {
        param($Path)
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Telecharge depuis une liste d'URLs (sources de secours) - leve une erreur si toutes echouent
    function Get-FileAny {
        param([string[]]$Urls, $Out, [int]$From = 0, [int]$To = 45)
        $ok = $false
        foreach ($u in $Urls) {
            try { Get-File $u $Out $From $To; $ok = $true; break }
            catch { L WARNING "Download failed ($u): $($_.Exception.Message)" }
        }
        if (-not $ok) { throw "All download sources failed" }
    }

    # API Windows (SystemParametersInfo / broadcast) pour appliquer theme + animations IMMEDIATEMENT
    function Initialize-Native {
        if ('CleanWin.Native' -as [type]) { return }
        $sig = @(
            '[StructLayout(LayoutKind.Sequential)] public struct ANIMATIONINFO { public uint cbSize; public int iMinAnimate; }',
            '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern bool SystemParametersInfo(uint a, uint b, string c, uint d);',
            '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);',
            '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, ref ANIMATIONINFO c, uint d);',
            '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);'
        ) -join "`n"
        Add-Type -Namespace CleanWin -Name Native -MemberDefinition $sig
    }

    # Ajoute des exclusions Windows Defender (chemins / processus)
    function Add-DefExclusion {
        param([string[]]$Paths = @(), [string[]]$Processes = @())
        foreach ($x in $Paths) {
            try { Add-MpPreference -ExclusionPath $x -ErrorAction Stop; L INFO "Defender exclusion added (path): $x" }
            catch { L WARNING "Defender exclusion NOT added for $x : $($_.Exception.Message.Split("`n")[0])" }
        }
        foreach ($x in $Processes) {
            try { Add-MpPreference -ExclusionProcess $x -ErrorAction Stop; L INFO "Defender exclusion added (process): $x" }
            catch { L WARNING "Defender exclusion NOT added for $x : $($_.Exception.Message.Split("`n")[0])" }
        }
    }

    # Liste les antivirus tiers enregistres dans le Centre de securite (hors Windows Defender)
    function Get-ThirdPartyAV {
        try {
            Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
                Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } |
                ForEach-Object { $_.displayName }
        } catch { }
    }

    # Retrouve winget.exe (alias utilisateur ou dossier WindowsApps)
    function Get-WingetPath {
        $c = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $p) { return $p }
        $d = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($d) { return $d.FullName }
        return $null
    }

    # Lance un processus cache avec pourcentage estime. Code retour dans $global:LastExitCode2.
    function Invoke-Proc {
        param([string]$Path, [string]$Arguments, [string]$WorkDir = '', [int]$From = 10, [int]$To = 95, [string]$Label = 'Working', [double]$Tau = 40)
        $sp = @{ FilePath = $Path; ArgumentList = $Arguments; WindowStyle = 'Hidden'; PassThru = $true }
        if ($WorkDir) { $sp.WorkingDirectory = $WorkDir }
        try { $p = Start-Process @sp } catch { throw "Cannot start '$Path' ($($_.Exception.Message))" }
        "PID|$($p.Id)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited) {
            $pct = $From + [int](($To - $From) * (1 - [math]::Exp(-$sw.Elapsed.TotalSeconds / $Tau)))
            P $pct ("{0}... {1}s" -f $Label, [int]$sw.Elapsed.TotalSeconds)
            Start-Sleep -Milliseconds 1000
            $p.Refresh()
        }
        $p.WaitForExit()
        $global:LastExitCode2 = $p.ExitCode
    }

    # Installation silencieuse via winget (source officielle de l'editeur)
    function Install-Winget {
        param([string]$Id, [string]$Source = 'winget', [int]$From = 10, [int]$To = 95)
        $w = Get-WingetPath
        if (-not $w) { throw "winget not found" }
        $a = "install --id $Id --exact --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        Invoke-Proc $w $a '' $From $To "winget install $Id" 45
        $code = $global:LastExitCode2
        # 0 = OK ; -1978335135 = deja installe ; -1978335189 = rien a mettre a jour
        if ($code -in 0, -1978335135, -1978335189) { L INFO "winget: $Id OK (code $code)" }
        else { throw "winget install $Id failed (exit code $code)" }
    }

    # GPU NVIDIA present ?
    function Get-NvidiaGpu {
        Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA' }
    }

    # Verifie un installeur telecharge : vrai executable / MSI (pas une page web) + signature numerique (journalisee ; refus si altere)
    function Test-InstallerFile {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $fs = [IO.File]::OpenRead($Path)
        try { $hdr = New-Object byte[] 4; [void]$fs.Read($hdr, 0, 4); $len = $fs.Length } finally { $fs.Close() }
        $isExe = ($hdr[0] -eq 0x4D -and $hdr[1] -eq 0x5A)      # "MZ"
        $isMsi = ($hdr[0] -eq 0xD0 -and $hdr[1] -eq 0xCF)      # OLE (MSI)
        if (-not ($isExe -or $isMsi)) {
            throw ("Downloaded file is not a valid installer ({0}, {1:N0} bytes, header {2}) - probably a web page or an interrupted download" -f (Split-Path $Path -Leaf), $len, (($hdr | ForEach-Object { $_.ToString('X2') }) -join ' '))
        }
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop } catch { }
        if ($sig) {
            $who = 'unsigned'
            if ($sig.SignerCertificate) { $who = [regex]::Match($sig.SignerCertificate.Subject, 'CN=("[^"]+"|[^,]+)').Groups[1].Value.Trim('"') }
            if ($sig.Status -eq 'HashMismatch') { throw ("Signature check FAILED for {0}: the file was altered after signing (hash mismatch) - installation cancelled" -f (Split-Path $Path -Leaf)) }
            L INFO ("Installer signature: {0} -> {1} [{2}]" -f (Split-Path $Path -Leaf), $who, $sig.Status)
        }
    }

    # Portable ? (type de chassis) - les reglages batterie / hibernation sont alors laisses tels quels
    function Test-Laptop {
        try {
            $ct = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
            return (@($ct | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }).Count -gt 0)
        } catch { return $false }
    }

    # Execute une commande native sans faire planter le job (retourne Code + Out)
    function Invoke-Native {
        param([string]$Exe, [string[]]$Arguments)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $Exe @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        [pscustomobject]@{ Code = $code; Out = $out }
    }

    # Desinstalle des packages APPX (tous les utilisateurs + packages provisionnes) avec progression
    function Remove-AppxByName {
        param([string[]]$Patterns, [int]$From = 0, [int]$To = 100)
        P $From "Scanning installed apps"
        $all  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        $targets = @($all | Where-Object { $n = $_.Name; @($Patterns | Where-Object { $n -like $_ }).Count -gt 0 })
        $provTargets = @($prov | Where-Object { $n = $_.DisplayName; @($Patterns | Where-Object { $n -like $_ }).Count -gt 0 })
        $total = $targets.Count + $provTargets.Count
        if ($total -eq 0) { L INFO "No matching app found (already clean)"; P $To "Nothing to remove"; return }
        $i = 0
        # 1) D'abord retirer le provisionnement : une fois le package installe supprime, Windows ne retrouve plus ses fichiers
        #    et Remove-AppxProvisionedPackage echoue avec "chemin introuvable".
        foreach ($pp in $provTargets) {
            $i++
            P ($From + [int](($To - $From) * $i / $total)) "Deprovisioning $($pp.DisplayName)"
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                L INFO "Deprovisioned: $($pp.DisplayName)"
            } catch {
                $msg = $_.Exception.Message.Split("`n")[0]
                if ($msg -match 'introuvable|not found|cannot find|0x80070002|0x80070003') { L INFO "Already deprovisioned: $($pp.DisplayName)" }
                else { L WARNING "Could not deprovision $($pp.DisplayName): $msg" }
            }
        }
        # 2) Puis supprimer les packages installes (tous les utilisateurs)
        foreach ($pkg in $targets) {
            $i++
            P ($From + [int](($To - $From) * $i / $total)) "Removing $($pkg.Name)"
            if ($pkg.NonRemovable) { L INFO "System package, skipped: $($pkg.Name)"; continue }
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
                L INFO "Removed: $($pkg.Name)"
            } catch { L WARNING "Could not remove $($pkg.Name): $($_.Exception.Message.Split("`n")[0])" }
        }
    }

    # Telechargement avec pourcentage reel
    function Get-File {
        param($Url, $Out, [int]$From = 0, [int]$To = 50)
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'Mozilla/5.0'
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $fs = [IO.File]::Create($Out)
        try {
            $buf = New-Object byte[] 81920
            $done = 0
            $last = [DateTime]::MinValue
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $done += $n
                if (([DateTime]::Now - $last).TotalMilliseconds -ge 250) {
                    $last = [DateTime]::Now
                    if ($total -gt 0) { $pct = $From + [int](($To - $From) * $done / $total) } else { $pct = $From }
                    P $pct ("Downloading {0:N1} MB" -f ($done / 1MB))
                }
            }
        } finally {
            $fs.Close(); $in.Close(); $resp.Close()
        }
        P $To "Download complete"
        L INFO "Downloaded: $Url"
    }

    # Installation silencieuse (fenetre cachee) - le % est une estimation basee sur le temps
    function Invoke-Installer {
        param($Path, $Arguments, [int]$From = 50, [int]$To = 98)
        if ($Path -match '\.(exe|msi)$') { Test-InstallerFile $Path }
        try { $p = Start-Process -FilePath $Path -ArgumentList $Arguments -WindowStyle Hidden -PassThru } catch { throw "Cannot start '$Path' ($($_.Exception.Message))" }
        "PID|$($p.Id)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited) {
            $pct = $From + [int](($To - $From) * (1 - [math]::Exp(-$sw.Elapsed.TotalSeconds / 30)))
            P $pct ("Silent install... {0}s" -f [int]$sw.Elapsed.TotalSeconds)
            Start-Sleep -Milliseconds 1000
            $p.Refresh()
        }
        $p.WaitForExit()
        $code = $p.ExitCode
        # 0 = OK, 3010/1641 = OK (reboot requis), 1638 = deja installe (version plus recente)
        if ($code -in 0, 1638, 1641, 3010) {
            L INFO "Installer finished: $(Split-Path $Path -Leaf) (ExitCode: $code)"
        } else {
            throw "Installer $(Split-Path $Path -Leaf) failed (ExitCode: $code)"
        }
        P 100 "Done"
    }
}

# --- IMPORTANT : Start-Job envoie -InitializationScript en ligne de commande (base64 UTF-16, limite Windows = 32 767 caracteres).
# On ecrit donc les fonctions communes dans un fichier et le job ne recoit qu'une ligne qui le charge.
$initFile = Join-Path $tempDir 'cleanwindows_init.ps1'
Set-Content -LiteralPath $initFile -Value $Init.ToString() -Encoding UTF8
$InitLoader = [scriptblock]::Create("Invoke-Expression ([System.IO.File]::ReadAllText('" + $initFile.Replace("'", "''") + "'))")

# =============================================================================
# Lance une tache dans un job avec timeout + barres de progression
# =============================================================================
$script:Summary = @()

function Invoke-Task {
    param([string]$Name, [scriptblock]$Script, [int]$Index, [int]$Total, [int]$Timeout = 0)
    if (-not $Timeout) { $Timeout = $TaskTimeoutSeconds }

    Write-Log ">>> [$Index/$Total] $Name (timeout: ${Timeout}s)" "INFO"
    $job = Start-Job -InitializationScript $InitLoader -ScriptBlock $Script -ArgumentList $tempDir, $PSCommandPath, $CleanUserDownloads
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pct = 0; $msg = "Starting"; $procId = $null
    $hadError = $false; $hadWarn = $false; $timedOut = $false; $skipped = $false
    $jobErrors = New-Object 'System.Collections.Generic.List[string]'
    $stray = 0

    while ($true) {
        $running = ($job.State -eq 'Running')

        $received = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobEv)
        foreach ($ev in @($jobEv)) { $m = ($ev | Out-String).Trim(); if ($m -and -not $jobErrors.Contains($m)) { $jobErrors.Add($m) } }
        foreach ($line in $received) {
            if ($line -isnot [string]) { continue }
            $parts = $line.Split('|', 3)
            if ($parts[0] -notin 'P', 'L', 'PID' -and $stray -lt 5 -and $line.Trim()) { $stray++; Write-Log "Unexpected task output: $line" "DEBUG" }
            switch ($parts[0]) {
                'P'   { $pct = [int]$parts[1]; $msg = $parts[2] }
                'L'   {
                    $lvl = $parts[1]
                    if ($lvl -eq 'SKIP') { $skipped = $true; $lvl = 'INFO' }      # tache non applicable : pas un avertissement
                    Write-Log $parts[2] $lvl
                    if ($lvl -eq 'ERROR')   { $hadError = $true }
                    if ($lvl -eq 'WARNING') { $hadWarn = $true }
                }
                'PID' { $procId = [int]$parts[1] }
            }
        }

        $pct = [Math]::Max(0, [Math]::Min(100, $pct))
        $overall = [int]((($Index - 1) * 100 + $pct) / $Total)
        Write-Progress -Id 1 -Activity "All-In-One Clean Windows" -Status "Task $Index/$Total - overall $overall%" -PercentComplete $overall
        Write-Progress -Id 2 -ParentId 1 -Activity $Name -Status ("{0}  [{1}s / {2}s]" -f $msg, [int]$sw.Elapsed.TotalSeconds, $Timeout) -PercentComplete $pct

        if (-not $running) { break }
        if ($sw.Elapsed.TotalSeconds -ge $Timeout) { $timedOut = $true; break }
        Start-Sleep -Milliseconds 200
    }

    if ($timedOut) {
        Write-Log "Timeout after $Timeout seconds: $Name - task killed, moving on" "WARNING"
        Stop-Job $job -ErrorAction SilentlyContinue
        if ($procId) { & taskkill.exe /PID $procId /T /F *> $null }
    } elseif ($job.State -eq 'Failed') {
        $hadError = $true
        Write-Log "Job failed: $($job.ChildJobs[0].JobStateInfo.Reason.Message)" "ERROR"
    }
    # Erreurs non fatales emises par la tache (conservees pour le diagnostic)
    foreach ($je in ($jobErrors | Select-Object -First 8)) { Write-Log ("[{0}] {1}" -f $Name, ($je -replace '\s+', ' ')) "JOBERR" }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Progress -Id 2 -Activity $Name -Completed

    # Resultat sur une seule ligne, avec barre en texte
    if ($timedOut)      { $status = "TIMEOUT (skipped)"; $color = "Yellow"; $final = $pct }
    elseif ($hadError)  { $status = "ERROR (see log)";    $color = "Red";    $final = $pct }
    elseif ($hadWarn)   { $status = "OK (warnings)";      $color = "Yellow"; $final = 100 }
    elseif ($skipped)   { $status = "SKIPPED (n/a)";      $color = "DarkGray"; $final = 100 }
    else                { $status = "OK";                 $color = "Green";  $final = 100 }

    $w = 20; $n = [int]($w * $final / 100)
    $bar = "[" + ("#" * $n) + ("-" * ($w - $n)) + "]"
    Write-Host ("{0} {1,3}%  {2} - {3}" -f $bar, $final, $Name, $status) -ForegroundColor $color
    $secs = [int]$sw.Elapsed.TotalSeconds
    Write-Log "<<< $Name : $status (${secs}s)" $(if ($timedOut -or $hadError) { "WARNING" } else { "SUCCESS" })
    $script:Summary += [pscustomobject]@{ Name = $Name; Status = $status; Seconds = $secs }
}

# =============================================================================
# DEFINITION DES TACHES
# Chaque tache est executee dans son propre job (donc soumise au timeout).
# =============================================================================
$Tasks = @(

    # Point de restauration : filet de securite AVANT toute modification
    @{ Name = "System Restore Point (safety)"; Script = {
        param($tempDir)
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = $null
        try {
            P 0 "Enabling System Protection"
            try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; L INFO "System Protection enabled on $env:SystemDrive" }
            catch { L INFO "System Protection: $($_.Exception.Message.Split("`n")[0])" }
            # Windows limite a 1 point de restauration par 24 h : on leve cette limite le temps de la creation
            try { $old = (Get-ItemProperty -LiteralPath $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop).SystemRestorePointCreationFrequency } catch { }
            Set-Reg $key 'SystemRestorePointCreationFrequency' 0
            P 15 "Creating restore point (can take up to a minute)"
            try {
                Checkpoint-Computer -Description "Before All-In-One Clean Windows" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
                L SUCCESS "Restore point created: 'Before All-In-One Clean Windows' (Windows > Create a restore point > System Restore)"
            } catch { L WARNING "Restore point NOT created: $($_.Exception.Message.Split("`n")[0])" }
            P 100 "Done"
        } catch { L ERROR "Restore point step failed: $($_.Exception.Message)" }
        finally {
            try {
                if ($null -ne $old) { Set-Reg $key 'SystemRestorePointCreationFrequency' $old }
                else { Remove-ItemProperty -LiteralPath $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
            } catch { }
        }
    } },

    # VC++ x64
    @{ Name = "Visual C++ Redistributable x64"; Script = {
        param($tempDir)
        try {
            $f = Join-Path $tempDir "vc_redist_x64.exe"
            P 0 "Downloading"
            Get-File "https://aka.ms/vc14/vc_redist.x64.exe" $f 0 50
            Invoke-Installer $f "/quiet /norestart" 50 98
            L SUCCESS "VC++ x64 installed"
        } catch { L ERROR $_.Exception.Message }
    } },

    # VC++ x86
    @{ Name = "Visual C++ Redistributable x86"; Script = {
        param($tempDir)
        try {
            $f = Join-Path $tempDir "vc_redist_x86.exe"
            P 0 "Downloading"
            Get-File "https://aka.ms/vc14/vc_redist.x86.exe" $f 0 50
            Invoke-Installer $f "/quiet /norestart" 50 98
            L SUCCESS "VC++ x86 installed"
        } catch { L ERROR $_.Exception.Message }
    } },

    # DirectX
    @{ Name = "DirectX End-User Runtime"; Script = {
        param($tempDir)
        try {
            $f = Join-Path $tempDir "dxwebsetup.exe"
            P 0 "Downloading"
            Get-File "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe" $f 0 40
            Invoke-Installer $f "/Q" 40 98
            L SUCCESS "DirectX installed"
        } catch { L ERROR $_.Exception.Message }
    } },

    # Context Menu
    @{ Name = "Context Menu Clean"; Script = {
        param($tempDir)
        try {
            $blocked = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
            $steps = @(
                { Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String' },
                { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoCustomizeThisFolder' 1 },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\Folder\shell\pintohome' },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\*\shell\pintohomefile' },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\exefile\shellex\ContextMenuHandlers\Compatibility' },
                { Set-Reg $blocked '{9F156763-7844-4DC4-B2B1-901F640F5155}' '' 'String' },
                { Set-Reg $blocked '{09A47860-11B0-4DA5-AFA5-26D86198A780}' '' 'String' },
                { Set-Reg $blocked '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}' '' 'String' },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\Folder\ShellEx\ContextMenuHandlers\Library Location' },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing' },
                { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'NoPreviousVersionsPage' 1 },
                { Remove-Key 'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo' }
            )
            $i = 0
            foreach ($s in $steps) {
                & $s
                $i++
                P ([int](100 * $i / $steps.Count)) "Step $i/$($steps.Count)"
            }
            L SUCCESS "Context Menu cleaned"
        } catch { L ERROR "Context Menu failed: $($_.Exception.Message)" }
    } },

    # IA : Copilot / Recall / Click to Do
    @{ Name = "AI Bloatware Removal (Copilot / Recall)"; Script = {
        param($tempDir)
        try {
            P 0 "Stopping Copilot processes"
            foreach ($pn in 'Copilot', 'CopilotRuntime') { Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue }

            # Politiques + masquage du bouton Copilot
            $steps = @(
                { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 },
                { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 },
                { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 },
                { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 },
                { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 },
                { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 },
                { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0 }
            )
            $i = 0
            foreach ($s in $steps) { & $s; $i++; P (5 + [int](25 * $i / $steps.Count)) "Policy $i/$($steps.Count)" }
            L INFO "Copilot / Recall / Click to Do policies applied"

            # Applications IA
            Remove-AppxByName @(
                'Microsoft.Copilot',
                'Microsoft.Windows.Copilot',
                'Microsoft.Windows.Ai.Copilot.Provider',
                'MicrosoftWindows.Client.AIX',
                'MicrosoftWindows.Client.CoreAI'
            ) 30 70

            # Fonctionnalite Windows Recall
            P 70 "Checking Windows Recall feature"
            try {
                $f = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction Stop
                if ($f -and $f.State -eq 'Enabled') {
                    P 80 "Removing Windows Recall"
                    Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart -ErrorAction Stop | Out-Null
                    L INFO "Windows Recall feature disabled"
                } else { L INFO "Windows Recall feature not enabled / not present" }
            } catch { L INFO "Recall feature not available on this Windows build" }
            P 100 "Done"
            L SUCCESS "AI bloatware removed / disabled"
        } catch { L ERROR "AI removal failed: $($_.Exception.Message)" }
    } },

    # APPX inutiles pour le gaming
    @{ Name = "Useless Apps Removal (APPX)"; Script = {
        param($tempDir)
        try {
            # Conserves volontairement : Microsoft Store, winget (App Installer), Calculatrice, Terminal, Outil Capture, Bloc-notes,
            # codecs (HEVC/AV1/WebP...), runtimes (VCLibs, .NET Native, UI.Xaml), panneaux NVIDIA/AMD/Realtek.
            Remove-AppxByName @(
                'Clipchamp.Clipchamp',
                'Microsoft.549981C3F5F10',
                'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance', 'Microsoft.BingSports',
                'Microsoft.GetHelp', 'Microsoft.Getstarted',
                'Microsoft.MicrosoftOfficeHub',
                'Microsoft.MicrosoftSolitaireCollection',
                'Microsoft.MicrosoftStickyNotes',
                'Microsoft.Todos',
                'Microsoft.PowerAutomateDesktop',
                'Microsoft.WindowsFeedbackHub',
                'Microsoft.WindowsMaps',
                'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice',
                'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
                'Microsoft.People',
                'Microsoft.Office.OneNote',
                'Microsoft.OutlookForWindows',
                'Microsoft.Windows.DevHome',
                'MicrosoftCorporationII.QuickAssist',
                'MicrosoftCorporationII.MicrosoftFamily',
                'MicrosoftTeams', 'MSTeams',
                'Microsoft.SkypeApp',
                'Microsoft.MixedReality.Portal',
                'Microsoft.Microsoft3DViewer',
                'Microsoft.MSPaint',
                'Microsoft.WindowsSoundRecorder',
                'Microsoft.WindowsAlarms',
                'Microsoft.Wallet',
                'Microsoft.MicrosoftJournal',
                'Microsoft.Whiteboard',
                'Microsoft.StartExperiencesApp',
                'Microsoft.Windows.Photos',
                'Microsoft.WindowsCamera',
                'Microsoft.Paint',
                'Microsoft.WindowsCommunicationsApps',
                'Microsoft.BingTranslator',
                'Microsoft.OneConnect',
                'Microsoft.Print3D',
                'Microsoft.MicrosoftPCManager',
                'MicrosoftCorporationII.Windows365',
                'Microsoft.Edge.GameAssist',
                'Microsoft.WidgetsPlatformRuntime',
                '*WhatsApp*', '*LinkedIn*', '*Messenger*', '*Telegram*', '*Snapchat*', '*Pinterest*',
                '*Duolingo*', '*Evernote*', '*PicsArt*', '*Flipboard*', '*Hulu*', '*Plex*',
                'AdobeSystemsIncorporated.*', '*McAfee*', '*Norton*', '*ExpressVPN*', '*Dropbox*',
                'Microsoft.Windows.NarratorQuickStart',
                'MicrosoftWindows.Client.WebExperience',
                'LinkedIn.LinkedIn',
                'Disney.*', 'SpotifyAB.SpotifyMusic', '*Netflix*', 'AmazonVideo.PrimeVideo',
                '*CandyCrush*', 'king.com.*', '*TikTok*', '*Facebook*', '*Instagram*', '*Twitter*'
            ) 0 90

            # Empeche Windows de reinstaller WhatsApp, LinkedIn, etc. (apps "suggerees" du Store)
            P 90 "Disabling consumer features"
            $cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            Set-Reg $cc 'DisableWindowsConsumerFeatures' 1
            Set-Reg $cc 'DisableSoftLanding' 1
            Set-Reg $cc 'DisableCloudOptimizedContent' 1
            P 100 "Done"
            L SUCCESS "Useless apps removal completed (consumer features disabled)"
        } catch { L ERROR "Apps removal failed: $($_.Exception.Message)" }
    } },

    # Xbox / Gamebar
    @{ Name = "Xbox / Gamebar Uninstall"; Script = {
        param($tempDir)
        try {
            P 0 "Stopping Xbox / GameBar processes"
            foreach ($pn in 'GameBar', 'GameBarPresenceWriter', 'GameBarFTServer', 'XboxPcApp', 'XboxAppServices') {
                Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue
            }

            # Applications : Xbox, Game Bar, Gaming Services, Xbox Identity Provider, TCUI, overlays...
            Remove-AppxByName @('Microsoft.Xbox*', 'Microsoft.Gaming*') 5 60

            # Services Xbox : arretes et desactives (Start=4)
            P 60 "Disabling Xbox services"
            foreach ($svc in 'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc', 'GamingServices', 'GamingServicesNet') {
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                if (Test-Path -LiteralPath $k) {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                    Set-Reg $k 'Start' 4
                    L INFO "Service disabled: $svc"
                }
            }

            # Registre : capture / Game DVR / bouton manette
            P 75 "Registry"
            $steps = @(
                { Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 },
                { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 },
                { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 },
                { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamepadNexusChordEnabled' 0 },
                { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 }
            )
            $j = 0
            foreach ($s in $steps) { & $s; $j++; P (75 + [int](15 * $j / $steps.Count)) "Registry $j/$($steps.Count)" }

            # Evite la popup "Obtenir une application pour ms-gamingoverlay" (Win+G / bouton Xbox de la manette)
            P 92 "Blocking ms-gamebar popup"
            foreach ($proto in 'ms-gamebar', 'ms-gamingoverlay') {
                $b = "Registry::HKEY_CLASSES_ROOT\$proto"
                Set-Reg $b '(default)' "URL:$proto" 'String'
                Set-Reg $b 'URL Protocol' '' 'String'
                Set-Reg "$b\shell\open\command" '(default)' '%SystemRoot%\System32\systray.exe' 'ExpandString'
            }
            P 100 "Done"
            L SUCCESS "Xbox / Gamebar uninstalled and disabled"
        } catch { L ERROR "Xbox / Gamebar failed: $($_.Exception.Message)" }
    } },

    # OneDrive
    @{ Name = "OneDrive Uninstall"; Script = {
        param($tempDir)
        try {
            P 0 "Stopping OneDrive"
            foreach ($pn in 'OneDrive', 'OneDriveSetup', 'FileCoAuth') { Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2

            $docs = [Environment]::GetFolderPath('MyDocuments')
            if ($docs -like '*OneDrive*') { L WARNING "Documents is redirected to OneDrive ($docs): your files are NOT deleted, they stay in that folder" }

            P 10 "Policy + startup entries"
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
            foreach ($rn in 'OneDrive', 'OneDriveSetup') {
                try { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $rn -ErrorAction Stop } catch { }
            }
            Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

            P 20 "Uninstalling OneDrive"
            # Commandes de desinstallation : registre (installation par utilisateur / machine) puis emplacements connus
            $cmds = New-Object 'System.Collections.Generic.List[object]'
            foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') {
                $us = $null
                try { $us = [string](Get-ItemProperty -LiteralPath $rk -ErrorAction Stop).UninstallString } catch { }
                if (-not $us) { continue }
                $exe = $null; $argl = ''
                if ($us -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $argl = $Matches[2] }
                elseif ($us -match '^\s*(\S+?\.exe)\s*(.*)$') { $exe = $Matches[1]; $argl = $Matches[2] }
                if ($exe -and (Test-Path -LiteralPath $exe)) { $cmds.Add(@($exe, $(if ($argl) { $argl } else { '/uninstall' }))) }
            }
            foreach ($c in "$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") {
                if (Test-Path -LiteralPath $c) { $cmds.Add(@($c, '/uninstall')) }
            }
            foreach ($g in "$env:ProgramFiles\Microsoft OneDrive\*\OneDriveSetup.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\*\OneDriveSetup.exe", "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe") {
                foreach ($f in @(Get-ChildItem -Path $g -ErrorAction SilentlyContinue)) { $cmds.Add(@($f.FullName, '/uninstall')) }
            }
            $seen = @{}
            $ran = 0
            foreach ($c in $cmds) {
                $key = ([string]$c[0]).ToLower()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true; $ran++
                L INFO "OneDrive uninstall command: $($c[0]) $($c[1])"
                try { Invoke-Proc $c[0] $c[1] '' 20 65 'Uninstalling OneDrive' 20; L INFO "OneDrive uninstaller exit code: $($global:LastExitCode2)" }
                catch { L WARNING "OneDrive uninstall failed: $($_.Exception.Message)" }
            }
            if ($ran -eq 0) { L INFO "No OneDrive uninstaller found (OneDrive absent or already removed)" }

            # Si OneDrive est toujours present : desinstallation via winget
            $present = { @(@("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") | Where-Object { Test-Path -LiteralPath $_ }) }
            if ((& $present).Count -gt 0) {
                $w = Get-WingetPath
                if ($w) {
                    P 66 "winget uninstall OneDrive"
                    try { Invoke-Proc $w 'uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements --disable-interactivity' '' 66 82 'winget uninstall OneDrive' 25; L INFO "winget uninstall OneDrive exit code: $($global:LastExitCode2)" }
                    catch { L WARNING "winget uninstall OneDrive failed: $($_.Exception.Message)" }
                }
            }

            P 85 "Cleaning leftovers"
            foreach ($d in "$env:LOCALAPPDATA\Microsoft\OneDrive", "$env:ProgramData\Microsoft OneDrive", "$env:SystemDrive\OneDriveTemp") {
                if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
            }
            foreach ($c in 'Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}', 'Registry::HKEY_CLASSES_ROOT\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}') {
                try { Set-Reg $c 'System.IsPinnedToNameSpaceTree' 0 } catch { }
            }
            P 95 "Verifying"
            Start-Sleep -Seconds 2
            $left = @(& $present)
            P 100 "Done"
            if ($left.Count -eq 0) { L SUCCESS "OneDrive uninstalled (your OneDrive folder was not deleted)" }
            else { L WARNING ("OneDrive is still present: " + ($left -join ', ') + " - uninstall it from Settings > Apps") }
        } catch { L ERROR "OneDrive failed: $($_.Exception.Message)" }
    } },

    # MSI Mode
    @{ Name = "MSI Mode (GPU)"; Script = {
        param($tempDir)
        try {
            P 0 "Detecting GPUs"
            $gpus = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
            $i = 0
            foreach ($gpu in $gpus) {
                $id = $gpu.InstanceId
                $path = "HKLM:\SYSTEM\ControlSet001\Enum\$id\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                Set-Reg $path 'MSISupported' 1
                L INFO "MSI enabled for: $id"
                $i++
                P ([int](100 * $i / $gpus.Count)) "GPU $i/$($gpus.Count)"
            }
            P 100 "Done"
            L SUCCESS "MSI Mode applied"
        } catch { L ERROR "MSI Mode failed: $($_.Exception.Message)" }
    } },

    # Plan d'alimentation Gaming
    @{ Name = "Power Plan - Gaming (Ultimate Performance)"; Script = {
        param($tempDir)
        try {
            $name = "Gaming - Ultimate Performance"
            $guidRx = '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})'

            # Plan deja cree par une execution precedente ? On le reutilise.
            P 0 "Looking for existing plan"
            $guid = $null
            $list = (Invoke-Native powercfg.exe @('/list')).Out
            foreach ($l in ($list -split "`r?`n")) {
                if ($l -match [regex]::Escape($name) -and $l -match $guidRx) { $guid = $Matches[1]; break }
            }

            # Sinon : duplique Ultimate Performance (ou High Performance si indisponible)
            if (-not $guid) {
                P 10 "Creating power plan"
                foreach ($base in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
                    $r = Invoke-Native powercfg.exe @('-duplicatescheme', $base)
                    if ($r.Code -eq 0 -and $r.Out -match $guidRx) {
                        $guid = $Matches[1]
                        L INFO "Plan created from base scheme $base"
                        break
                    }
                }
                if (-not $guid) { throw "Unable to create a power plan (powercfg failed)" }
                Invoke-Native powercfg.exe @('-changename', $guid, $name, 'Maximum performance plan for gaming') | Out-Null
            }

            # Reglages : sous-groupe, reglage, valeur, libelle
            $PROC = '54533251-82be-4824-96c1-47b60b740d00'
            $settings = @(
                @($PROC, '893dee8e-2bef-41e0-89c6-b55d0929964c', 100, 'CPU minimum state 100%'),
                @($PROC, 'bc5038f7-23e0-4960-96da-33abaf5935ec', 100, 'CPU maximum state 100%'),
                @($PROC, '0cc5b647-c1df-4637-891a-dec35c318583', 100, 'Core parking disabled'),
                @($PROC, 'be337238-0d82-4146-a960-4f3749d470c7', 2,   'CPU boost mode: aggressive'),
                @($PROC, '36687f9e-e3a5-4dbf-b1dc-15eb381c6863', 0,   'CPU energy performance preference: performance'),
                @($PROC, '45bcc044-d885-43e2-8605-ee0ec6e96b59', 100, 'CPU boost policy 100%'),
                @($PROC, '94d3a615-a899-4ac5-ae2b-e4d8f634367f', 1,   'Cooling policy: active'),
                @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0, 'PCIe link state power management: off'),
                @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0, 'USB selective suspend: disabled'),
                @('2a737441-1930-4402-8d77-b2bebba308a3', 'd4e98f31-5ffe-4ce1-be31-1b38b384c009', 0, 'USB 3 link power management: off'),
                @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0, 'Hard disk never turns off'),
                @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 0, 'Sleep: never'),
                @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '94ac6d29-73ce-41a6-809f-6363ba21b47e', 0, 'Hybrid sleep: off'),
                @('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', 0, 'Wireless adapter: max performance')
            )
            $laptop = Test-Laptop
            if ($laptop) { L INFO "Laptop detected: battery (DC) values left at their defaults, only plugged-in (AC) values are applied" }
            $i = 0
            foreach ($s in $settings) {
                $i++
                P (15 + [int](75 * $i / $settings.Count)) $s[3]
                $ac = Invoke-Native powercfg.exe @('-setacvalueindex', $guid, $s[0], $s[1], "$($s[2])")
                $dc = if ($laptop) { [pscustomobject]@{ Code = 1 } } else { Invoke-Native powercfg.exe @('-setdcvalueindex', $guid, $s[0], $s[1], "$($s[2])") }
                if ($ac.Code -ne 0 -and $dc.Code -ne 0) { L INFO "Setting not supported on this PC (skipped): $($s[3])" }
                else { L INFO "Applied: $($s[3])" }
            }

            P 92 "Activating plan"
            $act = Invoke-Native powercfg.exe @('-setactive', $guid)
            if ($act.Code -ne 0) { throw "powercfg -setactive failed: $($act.Out.Trim())" }

            # Supprime tous les autres plans (le plan actif ne peut pas etre supprime : on a active le notre avant)
            P 94 "Removing other power plans"
            $list = (Invoke-Native powercfg.exe @('/list')).Out
            $others = @()
            foreach ($l in ($list -split "`r?`n")) {
                if ($l -match $guidRx -and $Matches[1] -ine $guid) { $others += $Matches[1] }
            }
            $k = 0
            foreach ($o in $others) {
                $k++
                P (94 + [int](6 * $k / $others.Count)) "Deleting plan $k/$($others.Count)"
                $d = Invoke-Native powercfg.exe @('-delete', $o)
                if ($d.Code -eq 0) { L INFO "Deleted power plan: $o" }
                else { L WARNING "Could not delete power plan $o : $($d.Out.Trim())" }
            }
            P 100 "Done"
            L SUCCESS "Power plan '$name' created and activated ($guid) - $($others.Count) other plan(s) removed"
        } catch { L ERROR "Power plan failed: $($_.Exception.Message)" }
    } },

    # THEME NOIR COMPLET : vrai noir partout (apps, systeme, barre des taches, demarrer, ouverture de session)
    @{ Name = "Theme Black (Full Dark Everywhere)"; Script = {
        param($tempDir)
        try {
            # CAUSE de la barre bleue : Windows utilise AccentPalette, qui ecrase AccentColorMenu / StartColorMenu.
            # On ecrit donc la palette complete (gris clair pour les liens/survols, noir pour les fonds) + les couleurs DWM.
            $accent   = 0x1F000000
            $accentIn = 0x1F202020
            $palette  = [byte[]](0xC8,0xC8,0xC8,0x1F, 0xC8,0xC8,0xC8,0x1F, 0xC8,0xC8,0xC8,0x1F, 0xC8,0xC8,0xC8,0x1F,
                                 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00)
            $items = @()
            # Utilisateur courant + profil .DEFAULT (ecran de connexion)
            foreach ($root in 'HKCU:\SOFTWARE\Microsoft\Windows', 'Registry::HKEY_USERS\.DEFAULT\SOFTWARE\Microsoft\Windows') {
                $pers = "$root\CurrentVersion\Themes\Personalize"
                $acc  = "$root\CurrentVersion\Explorer\Accent"
                $dwm  = "$root\DWM"
                $items += ,@($pers, 'AppsUseLightTheme', 0)
                $items += ,@($pers, 'SystemUsesLightTheme', 0)
                $items += ,@($pers, 'EnableTransparency', 0)
                $items += ,@($pers, 'EnabledBlurBehind', 0)
                $items += ,@($pers, 'ColorPrevalence', 1)              # couleur d'accent sur Demarrer + barre des taches (= noir)
                $items += ,@($acc, 'AccentColorMenu', $accent)
                $items += ,@($acc, 'StartColorMenu', $accentIn)
                $items += ,@($acc, 'AccentPalette', $palette, 'Binary')
                $items += ,@($dwm, 'ColorPrevalence', 0)               # pas de couleur sur les barres de titre
                $items += ,@($dwm, 'AccentColor', $accent)
                $items += ,@($dwm, 'AccentColorInactive', $accentIn)
            }
            # Ouverture de session / ecran de verrouillage / Ctrl+Alt+Suppr en noir
            $items += ,@('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'Background', '0 0 0', 'String')
            $items += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'DisableAcrylicBackgroundOnLogon', 1)
            $items += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'DisableLogonBackgroundImage', 1)
            $items += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization', 'PersonalColors_Background', '#000000', 'String')
            $items += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization', 'NoLockScreen', 1)
            # Fond d'ecran noir uni
            $items += ,@('HKCU:\Control Panel\Colors', 'Background', '0 0 0', 'String')
            $items += ,@('HKCU:\Control Panel\Desktop', 'Wallpaper', '', 'String')
            $items += ,@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers', 'BackgroundType', 1)

            $i = 0
            foreach ($it in $items) {
                $i++
                $type = if ($it.Count -gt 3) { $it[3] } else { 'DWord' }
                try { Set-Reg $it[0] $it[1] $it[2] $type }
                catch { L WARNING "Not applied: $($it[1]) ($($_.Exception.Message.Split("`n")[0]))" }
                P ([int](80 * $i / $items.Count)) "Setting $i/$($items.Count)"
            }

            # Application immediate : fond noir + notification "theme change" a toutes les fenetres
            P 85 "Applying black wallpaper"
            try {
                Initialize-Native
                [CleanWin.Native]::SystemParametersInfo(20, 0, [string]'', 3) | Out-Null     # SPI_SETDESKWALLPAPER (vide = couleur unie)
                P 92 "Broadcasting theme change"
                $r = [UIntPtr]::Zero
                [CleanWin.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$r) | Out-Null
                [CleanWin.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'WindowsThemeElement', 2, 5000, [ref]$r) | Out-Null
            } catch { L INFO "Immediate refresh unavailable - the theme will fully apply after Explorer restart / sign-out" }

            P 100 "Done"
            L SUCCESS "Full black theme applied (taskbar/Start accent palette rewritten, logon + lock screen black). Sign out or reboot for 100% of the changes"
        } catch { L ERROR "Theme failed: $($_.Exception.Message)" }
    } },

    # PERFORMANCE WINDOWS GAMING : animations coupees (appliquees en direct) + reglages jeu
    @{ Name = "Windows Performance (Gaming + No Animations)"; Script = {
        param($tempDir)
        try {
            # ---- 1) ANIMATIONS : appliquees directement par l'API Windows (effet immediat, sans reconnexion) ----
            P 0 "Disabling all animations"
            Initialize-Native
            $off = @(
                0x103F,   # SPI_SETUIEFFECTS (interrupteur general des effets)
                0x1043,   # SPI_SETCLIENTAREAANIMATION  ("Effets d'animation" de Windows 11)
                0x1003,   # menus animes
                0x1005,   # listes deroulantes animees
                0x1007,   # defilement fluide des listes
                0x1013,   # fondu des menus
                0x1015,   # fondu de selection
                0x1017,   # info-bulles animees
                0x1019,   # fondu des info-bulles
                0x101B,   # ombre du curseur
                0x1009    # barres de titre en degrade
            )
            $n = 0
            foreach ($a in $off) {
                $n++
                try { [CleanWin.Native]::SystemParametersInfo([uint32]$a, 0, [IntPtr]::Zero, 3) | Out-Null } catch { }
                P ([int](20 * $n / $off.Count)) "Animation setting $n/$($off.Count)"
            }
            # Reduction / agrandissement des fenetres sans animation
            $ai = New-Object CleanWin.Native+ANIMATIONINFO
            $ai.cbSize = 8; $ai.iMinAnimate = 0
            [CleanWin.Native]::SystemParametersInfo(0x49, 8, [ref]$ai, 3) | Out-Null
            # Texte lisse (ClearType) conserve pour la lisibilite
            [CleanWin.Native]::SystemParametersInfo(0x4B, 1, [IntPtr]::Zero, 3) | Out-Null
            [CleanWin.Native]::SystemParametersInfo(0x200B, 0, [IntPtr]2, 3) | Out-Null
            L INFO "Animations disabled via SystemParametersInfo (immediate)"

            # ---- 2) REGISTRE : effets visuels, explorateur, jeu ----
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            $mm  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
            $items = @(
                # Effets visuels : personnalise = tout coupe sauf polices lissees, miniatures et ombres (lisibilite sur fond noir)
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects', 'VisualFXSetting', 3),
                @('HKCU:\Control Panel\Desktop', 'MenuShowDelay', '0', 'String'),
                @('HKCU:\Control Panel\Desktop', 'FontSmoothing', '2', 'String'),
                @('HKCU:\Control Panel\Desktop\WindowMetrics', 'MinAnimate', '0', 'String'),
                @($adv, 'TaskbarAnimations', 0),
                @($adv, 'ListviewAlphaSelect', 0),
                @($adv, 'ListviewShadow', 0),
                @('HKCU:\Software\Microsoft\Windows\DWM', 'EnableAeroPeek', 0),
                @('HKCU:\Software\Microsoft\Windows\DWM', 'AlwaysHibernateThumbnails', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize', 'StartupDelayInMSec', 0),
                # Pubs / suggestions / reinstallation automatique d'apps
                @($cdm, 'ContentDeliveryAllowed', 0),
                @($cdm, 'OemPreInstalledAppsEnabled', 0),
                @($cdm, 'PreInstalledAppsEnabled', 0),
                @($cdm, 'PreInstalledAppsEverEnabled', 0),
                @($cdm, 'SilentInstalledAppsEnabled', 0),
                @($cdm, 'SystemPaneSuggestionsEnabled', 0),
                @($cdm, 'SoftLandingEnabled', 0),
                @($cdm, 'FeatureManagementEnabled', 0),
                @($cdm, 'RotatingLockScreenEnabled', 0),
                @($cdm, 'RotatingLockScreenOverlayEnabled', 0),
                @($cdm, 'SubscribedContent-338387Enabled', 0),
                @($cdm, 'SubscribedContent-338388Enabled', 0),
                @($cdm, 'SubscribedContent-338389Enabled', 0),
                @($cdm, 'SubscribedContent-353694Enabled', 0),
                @($cdm, 'SubscribedContent-353696Enabled', 0),
                @($cdm, 'SubscribedContent-338393Enabled', 0),
                # Gaming : Game Mode, pas d'apps en arriere-plan, priorite multimedia/jeux, planification GPU
                @('HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled', 1),
                @('HKCU:\Software\Microsoft\GameBar', 'AllowAutoGameMode', 1),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications', 'GlobalUserDisabled', 1),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy', 'LetAppsRunInBackground', 2),
                @($mm, 'NetworkThrottlingIndex', -1),
                @($mm, 'SystemResponsiveness', 0),
                @("$mm\Tasks\Games", 'GPU Priority', 8),
                @("$mm\Tasks\Games", 'Priority', 6),
                @("$mm\Tasks\Games", 'Scheduling Category', 'High', 'String'),
                @("$mm\Tasks\Games", 'SFIO Priority', 'High', 'String'),
                @('HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode', 2),
                @('HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling', 'PowerThrottlingOff', 1),
                @('HKCU:\Software\Microsoft\DirectX\UserGpuPreferences', 'DirectXUserGlobalSettings', 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;', 'String'),
                # Pas de popups Sticky Keys en jeu (reglages souris : tache "Mouse Optimization")
                @('HKCU:\Control Panel\Accessibility\StickyKeys', 'Flags', '506', 'String'),
                @('HKCU:\Control Panel\Accessibility\Keyboard Response', 'Flags', '122', 'String'),
                @('HKCU:\Control Panel\Accessibility\ToggleKeys', 'Flags', '58', 'String'),
                # Moins de processus en arriere-plan : telemetrie minimale + rapports d'erreurs coupes
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 0),
                @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'Disabled', 1)
            )
            $i = 0
            foreach ($it in $items) {
                $i++
                $type = if ($it.Count -gt 3) { $it[3] } else { 'DWord' }
                try { Set-Reg $it[0] $it[1] $it[2] $type }
                catch { L INFO "Skipped (protected or unavailable): $($it[1])" }
                P (20 + [int](55 * $i / $items.Count)) "Setting $i/$($items.Count)"
            }

            # ---- 3) SERVICES + SYSTEME DE FICHIERS ----
            P 78 "Disabling telemetry services"
            foreach ($svc in 'DiagTrack', 'dmwappushservice') {
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                if (Test-Path -LiteralPath $k) {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                    try { Set-Reg $k 'Start' 4; L INFO "Service disabled: $svc" } catch { L INFO "Could not disable $svc" }
                }
            }
            P 88 "Hibernation off / NTFS last-access off"
            if (Test-Laptop) { L INFO "Laptop detected: hibernation left enabled" }
            else {
                $h = Invoke-Native powercfg.exe @('/hibernate', 'off')
                if ($h.Code -eq 0) { L INFO "Hibernation + Fast Startup disabled (frees hiberfil.sys)" } else { L INFO "Hibernation unchanged" }
            }
            $f = Invoke-Native fsutil.exe @('behavior', 'set', 'disablelastaccess', '1')
            if ($f.Code -eq 0) { L INFO "NTFS last access time updates disabled" }

            P 100 "Done"
            L SUCCESS "Windows performance applied: animations OFF (live), Game Mode, GPU scheduling, MMCSS, no telemetry. Reboot recommended"
        } catch { L ERROR "Performance failed: $($_.Exception.Message)" }
    } },

    # Souris : acceleration (Ameliorer la precision du pointeur) OFF, vitesse 1:1, appliquee en direct
    @{ Name = "Mouse Optimization (no acceleration, 1:1)"; Script = {
        param($tempDir)
        try {
            P 5 "Preparing mouse API"
            if (-not ('CleanWin.Mouse' -as [type])) {
                $msig = @(
                    '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, int[] c, uint d);',
                    '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);'
                ) -join "`n"
                Add-Type -Namespace CleanWin -Name Mouse -MemberDefinition $msig
            }

            # ---- 1) REGISTRE (utilisateur + ecran de connexion) ----
            P 15 "Writing mouse settings"
            $vals = @(
                @('MouseSpeed', '0'),            # Ameliorer la precision du pointeur : desactive
                @('MouseThreshold1', '0'),
                @('MouseThreshold2', '0'),
                @('MouseSensitivity', '10'),     # vitesse du pointeur 6/11 = 1:1 (aucun facteur d'echelle)
                @('MouseTrails', '0'),           # pas de traces du pointeur
                @('SnapToDefaultButton', '0'),   # pas de saut automatique vers le bouton par defaut
                @('MouseHoverTime', '400')
            )
            foreach ($root in 'HKCU:\Control Panel\Mouse', 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
                foreach ($v in $vals) {
                    try { Set-Reg $root $v[0] $v[1] 'String' } catch { L INFO "Skipped: $root $($v[0])" }
                }
            }
            L INFO "Mouse registry: MouseSpeed=0, Threshold1/2=0, MouseSensitivity=10 (1:1), trails off, snap-to-button off"

            # ---- 2) APPLICATION IMMEDIATE (sans redemarrage) ----
            P 50 "Applying live (SystemParametersInfo)"
            $ok = $true
            if (-not [CleanWin.Mouse]::SystemParametersInfo(0x0004, 0, [int[]]@(0, 0, 0), 3)) { $ok = $false }   # SPI_SETMOUSE : seuils 0/0, acceleration 0
            if (-not [CleanWin.Mouse]::SystemParametersInfo(0x0071, 0, [IntPtr]10, 3)) { $ok = $false }           # SPI_SETMOUSESPEED : 10
            [void][CleanWin.Mouse]::SystemParametersInfo(0x005D, 0, [IntPtr]::Zero, 3)                             # SPI_SETMOUSETRAILS : off
            [void][CleanWin.Mouse]::SystemParametersInfo(0x0060, 0, [IntPtr]::Zero, 3)                             # SPI_SETSNAPTODEFBUTTON : off
            if ($ok) { L INFO "Mouse acceleration disabled live" } else { L WARNING "Live apply failed - settings take effect after sign out / reboot" }

            # ---- 3) Courbe de souris : lineaire (neutralise les anciennes courbes personnalisees) ----
            P 75 "Resetting mouse curves"
            foreach ($root in 'HKCU:\Control Panel\Mouse', 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
                foreach ($c in 'SmoothMouseXCurve', 'SmoothMouseYCurve') {
                    try { Remove-ItemProperty -LiteralPath $root -Name $c -ErrorAction SilentlyContinue } catch { }
                }
            }

            P 100 "Done"
            L SUCCESS "Mouse optimized: pointer acceleration OFF, speed 1:1 (6/11), trails off. Games using raw input are unaffected by Windows settings anyway"
        } catch { L ERROR "Mouse optimization failed: $($_.Exception.Message)" }
    } },

    # Explorateur Windows : "Ce PC" + aucun historique
    @{ Name = "Explorer Optimization (This PC + no history)"; Script = {
        param($tempDir)
        try {
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $exp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
            $items = @(
                @($adv, 'LaunchTo', 1),                       # ouvre l'Explorateur sur "Ce PC"
                @($adv, 'HideFileExt', 0),                    # affiche les extensions de fichiers
                @($adv, 'ShowSyncProviderNotifications', 0),  # pas de pubs OneDrive/Office
                @($adv, 'Start_TrackDocs', 0),
                @($exp, 'ShowRecent', 0),                     # pas de fichiers recents dans l'acces rapide
                @($exp, 'ShowFrequent', 0),                   # pas de dossiers frequents
                @($exp, 'ShowCloudFilesInQuickAccess', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'NoRecentDocsHistory', 1),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'ClearRecentDocsOnExit', 1),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDeviceSearchHistoryEnabled', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDynamicSearchBoxEnabled', 0)
            )
            $i = 0
            foreach ($it in $items) {
                $i++
                try { Set-Reg $it[0] $it[1] $it[2] }
                catch { L INFO "Skipped (protected or unavailable): $($it[1])" }
                P ([int](50 * $i / $items.Count)) "Setting $i/$($items.Count)"
            }

            # Efface l'historique deja existant
            P 55 "Clearing recent files"
            foreach ($d in "$env:APPDATA\Microsoft\Windows\Recent") {
                if (Test-Path -LiteralPath $d) {
                    Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            P 75 "Clearing search / typed paths history"
            $keys = @(
                "$exp\TypedPaths", "$exp\WordWheelQuery", "$exp\RunMRU", "$exp\RecentDocs",
                "$exp\ComDlg32\OpenSavePidlMRU", "$exp\ComDlg32\LastVisitedPidlMRU"
            )
            $j = 0
            foreach ($k in $keys) { Remove-Key $k; $j++; P (75 + [int](25 * $j / $keys.Count)) "History $j/$($keys.Count)" }
            P 100 "Done"
            L SUCCESS "Explorer optimized: opens on This PC, history disabled and cleared"
        } catch { L ERROR "Explorer optimization failed: $($_.Exception.Message)" }
    } },

    # Edge + WebView2 : optimisation gaming
    @{ Name = "Edge / WebView2 - Gaming Optimization"; Script = {
        param($tempDir)
        try {
            $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            $items = @(
                # Edge : aucun process en arriere-plan, mode efficacite, pas de bloat
                @($edge, 'StartupBoostEnabled', 0),
                @($edge, 'BackgroundModeEnabled', 0),
                @($edge, 'EfficiencyModeEnabled', 1),
                @($edge, 'SleepingTabsEnabled', 1),
                @($edge, 'HubsSidebarEnabled', 0),
                @($edge, 'EdgeShoppingAssistantEnabled', 0),
                @($edge, 'ShowRecommendationsEnabled', 0),
                @($edge, 'SpotlightExperiencesAndRecommendationsEnabled', 0),
                @($edge, 'NewTabPageContentEnabled', 0),
                @($edge, 'EdgeFollowEnabled', 0),
                @($edge, 'PersonalizationReportingEnabled', 0),
                @($edge, 'MetricsReportingEnabled', 0),
                @($edge, 'HideFirstRunExperience', 1)
            )
            $i = 0
            foreach ($it in $items) {
                $i++
                try { Set-Reg $it[0] $it[1] $it[2] }
                catch { L INFO "Skipped: $($it[1])" }
                P ([int](70 * $i / $items.Count)) "Policy $i/$($items.Count)"
            }

            # Supprime le lancement automatique d'Edge au demarrage de Windows
            P 75 "Removing Edge autostart entries"
            foreach ($run in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
                try {
                    $props = (Get-ItemProperty -LiteralPath $run -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -like 'MicrosoftEdgeAutoLaunch*' }
                    foreach ($pr in $props) { Remove-ItemProperty -LiteralPath $run -Name $pr.Name -ErrorAction SilentlyContinue; L INFO "Removed autostart: $($pr.Name)" }
                } catch { }
            }
            # Empeche Edge de recreer son raccourci sur le bureau (mises a jour)
            try { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0 } catch { }

            # Unpin Edge du bureau
            P 80 "Unpinning Edge from desktop"
            $deskDirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
            if ($env:OneDrive) { $deskDirs += (Join-Path $env:OneDrive 'Desktop') }
            foreach ($dd in ($deskDirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
                foreach ($lnk in @(Get-ChildItem -LiteralPath $dd -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like '*Microsoft Edge*' -or $_.BaseName -eq 'Edge' })) {
                    try { Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction Stop; L INFO "Removed desktop shortcut: $($lnk.FullName)" }
                    catch { L INFO "Could not remove: $($lnk.FullName)" }
                }
            }

            # Unpin Edge de la barre des taches
            P 83 "Unpinning Edge from taskbar"
            $tbRemoved = $false
            try {
                $tbDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
                if (Test-Path -LiteralPath $tbDir) {
                    foreach ($lnk in @(Get-ChildItem -LiteralPath $tbDir -Filter '*.lnk' -Force -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like '*Edge*' })) {
                        Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue
                        $tbRemoved = $true
                        L INFO "Removed taskbar pin: $($lnk.Name)"
                    }
                }
                # Methode shell (verbe "Desepingler de la barre des taches") quand elle est disponible
                try {
                    $app = (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Name -eq 'Microsoft Edge' } | Select-Object -First 1
                    if ($app) {
                        $verb = $app.Verbs() | Where-Object { ($_.Name -replace '&','') -match 'Unpin from taskbar|taskbar.*(Unpin|Detach)|barre des t.ches.*(pingler)|pingler.*barre des t.ches' } | Select-Object -First 1
                        if ($verb) { $verb.DoIt(); $tbRemoved = $true }
                    }
                } catch { }
                if ($tbRemoved) {
                    # Redemarre l'explorateur pour appliquer le retrait de l'epingle
                    Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) { Start-Process 'explorer.exe' }
                    L SUCCESS "Edge unpinned from taskbar"
                } else { L INFO "Edge was not pinned to the taskbar" }
            } catch { L INFO "Taskbar unpin skipped: $($_.Exception.Message)" }

            P 85 "Stopping Edge"
            Stop-Process -Name 'msedge' -Force -ErrorAction SilentlyContinue
            L INFO "WebView2 Runtime kept on purpose (required by Steam, launchers and Store apps)"
            P 100 "Done"
            L SUCCESS "Edge optimized for gaming (WebView2 kept intact)"
        } catch { L ERROR "Edge optimization failed: $($_.Exception.Message)" }
    } },

    # Microsoft Store : optimisation gaming
    @{ Name = "Microsoft Store Optimization"; Script = {
        param($tempDir)
        try {
            P 0 "Closing Store"
            Stop-Process -Name 'WinStore.App' -Force -ErrorAction SilentlyContinue

            $store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
            $bg    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
            $items = @(
                @($store, 'AutoDownload', 2),                  # pas de mises a jour auto des apps Store (pas de telechargement pendant un jeu)
                @($store, 'DisableOSUpgrade', 1),              # pas d'offres de mise a niveau Windows
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization', 'DODownloadMode', 0),   # telechargements directs, pas de partage P2P
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', 1),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0),
                @("$bg\Microsoft.WindowsStore_8wekyb3d8bbwe", 'Disabled', 1),          # le Store ne tourne plus en arriere-plan
                @("$bg\Microsoft.WindowsStore_8wekyb3d8bbwe", 'DisabledByUser', 1),
                @("$bg\Microsoft.StorePurchaseApp_8wekyb3d8bbwe", 'Disabled', 1),
                @("$bg\Microsoft.StorePurchaseApp_8wekyb3d8bbwe", 'DisabledByUser', 1)
            )
            $i = 0
            foreach ($it in $items) {
                $i++
                try { Set-Reg $it[0] $it[1] $it[2] }
                catch { L INFO "Skipped: $($it[1])" }
                P (5 + [int](55 * $i / $items.Count)) "Setting $i/$($items.Count)"
            }

            # Vide le cache du Store (regenere automatiquement, evite lenteurs / echecs de telechargement)
            P 65 "Clearing Store cache"
            foreach ($d in "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache", "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\TempState") {
                if (Test-Path -LiteralPath $d) {
                    Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            L INFO "Store cache cleared"

            P 85 "Stopping idle Store services"
            Stop-Service -Name 'InstallService' -Force -ErrorAction SilentlyContinue
            P 100 "Done"
            L SUCCESS "Microsoft Store optimized (no auto-updates, no background activity, no P2P, cache cleared)"
        } catch { L ERROR "Store optimization failed: $($_.Exception.Message)" }
    } },

    # Windows Defender : performance gaming, protection antivirus uniquement
    @{ Name = "Windows Defender - Gaming Performance (antivirus only)"; Script = {
        param($tempDir)
        try {
            P 0 "Checking antivirus products"
            $others = @(Get-ThirdPartyAV)
            if ($others.Count -gt 0) { L WARNING "Other antivirus registered: $($others -join ', ') (Defender settings below still apply)" }

            # ---- 1) Moteur : analyses legeres, jamais en jeu ; protection en temps reel CONSERVEE ----
            $settings = @(
                @('ScanAvgCPULoadFactor', 10),            # analyses limitees a 10 % du CPU (defaut 50)
                @('EnableLowCpuPriority', $true),
                @('ScanOnlyIfIdleEnabled', $true),
                @('DisableCatchupFullScan', $true),
                @('DisableCatchupQuickScan', $true),
                @('ScanScheduleDay', 8),                  # 8 = jamais d'analyse planifiee (analyse manuelle possible)
                @('DisableRemovableDriveScanning', $true),
                @('DisableEmailScanning', $true),
                @('DisableScanningNetworkFiles', $true),
                @('SubmitSamplesConsent', 2),             # pas d'envoi automatique d'echantillons
                @('EnableControlledFolderAccess', 0),     # n'empeche pas les jeux d'ecrire dans Documents
                @('EnableNetworkProtection', 0)
            )
            $i = 0
            foreach ($s in $settings) {
                $i++
                try { $h = @{ $s[0] = $s[1] }; Set-MpPreference @h -ErrorAction Stop; L INFO "Defender: $($s[0]) = $($s[1])" }
                catch { L INFO "Defender setting not applied ($($s[0])) - Tamper Protection or unsupported" }
                P (5 + [int](40 * $i / $settings.Count)) "Defender setting $i/$($settings.Count)"
            }

            # ---- 2) Exclusions : bibliotheques de jeux (moins de micro-saccades a l'ecriture / au chargement) ----
            P 48 "Game folder exclusions"
            $gamePaths = @("${env:ProgramFiles(x86)}\Steam\steamapps", 'C:\Battlestate Games')
            Add-DefExclusion -Paths $gamePaths
            # SpotX n'est plus installe : on retire les anciennes exclusions Spotify si elles existent
            foreach ($old in "$env:APPDATA\Spotify", "$env:LOCALAPPDATA\Spotify", "$env:TEMP\SpotX_Temp") {
                try { Remove-MpPreference -ExclusionPath $old -ErrorAction Stop } catch { }
            }
            try { Remove-MpPreference -ExclusionProcess 'Spotify.exe' -ErrorAction Stop } catch { }

            # ---- 3) Fonctions de securite hors antivirus : coupees pour le gaming ----
            P 55 "Disabling non-antivirus protections"
            $items = @(
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableSmartScreen', 0),                                  # SmartScreen applications / fichiers
                @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer', 'SmartScreenEnabled', 'Off', 'String'),
                @('HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy', 'VerifiedAndReputablePolicyState', 0),                     # Smart App Control OFF
                @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity', 'Enabled', 0), # Integrite de la memoire (HVCI) OFF = + de FPS
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'EnableVirtualizationBasedSecurity', 0),             # VBS OFF
                @('HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications', 'DisableNotifications', 1),
                @('HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications', 'DisableEnhancedNotifications', 1),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications', 'DisableNotifications', 1)
            )
            $j = 0
            foreach ($it in $items) {
                $j++
                $type = if ($it.Count -gt 3) { $it[3] } else { 'DWord' }
                try { Set-Reg $it[0] $it[1] $it[2] $type }
                catch { L INFO "Skipped (protected): $($it[1])" }
                P (55 + [int](35 * $j / $items.Count)) "Setting $j/$($items.Count)"
            }

            # ---- 4) Verification : le temps reel doit rester actif ----
            P 92 "Verifying real-time protection"
            try {
                $st = Get-MpComputerStatus -ErrorAction Stop
                L INFO "Defender status: RealTimeProtection=$($st.RealTimeProtectionEnabled) AntivirusEnabled=$($st.AntivirusEnabled)"
            } catch { L INFO "Defender status unavailable" }
            P 100 "Done"
            L SUCCESS "Defender tuned for gaming (real-time antivirus kept, scans throttled, SmartScreen / Smart App Control / Memory Integrity off). Reboot required for VBS/HVCI"
        } catch { L ERROR "Defender config failed: $($_.Exception.Message)" }
    } },

    # Menu demarrer simple et propre
    @{ Name = "Start Menu - Simple & Clean"; Script = {
        param($tempDir)
        try {
            foreach ($pn in 'Widgets', 'WidgetService') { Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue }
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
            $pm  = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
            $emptyPins = '{"pinnedList":[]}'
            $items = @(
                # Liste des epingles vide (stocke par strategie : necessite Windows 11 Pro/Enterprise recent)
                @($pol, 'ConfigureStartPins', $emptyPins, 'String'),
                @($pol, 'ConfigureStartPins_ProviderSet', 1),
                @($pol, 'ConfigureStartPinsJSON', $emptyPins, 'String'),
                @($pm,  'ConfigureStartPins', $emptyPins, 'String'),
                @($pm,  'ConfigureStartPins_ProviderSet', 1),
                # Pas de "recemment ajoute", "plus utilises", ni de section Recommande
                @($pol, 'HideRecentlyAddedApps', 1),
                @($pol, 'ShowOrHideMostUsedApps', 2),
                @($pol, 'HideRecommendedSection', 1),
                @($adv, 'Start_Layout', 1),
                @($adv, 'Start_TrackProgs', 0),
                @($adv, 'Start_TrackDocs', 0),
                @($adv, 'Start_IrisRecommendations', 0),
                @($adv, 'Start_AccountNotifications', 0),
                # Pas de recherche web Bing dans le menu demarrer
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'SearchboxTaskbarMode', 0),
                @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1),
                # Barre des taches epuree : Vue des taches, Widgets, Chat
                @($adv, 'ShowTaskViewButton', 0),
                @($adv, 'TaskbarDa', 0),
                @($adv, 'TaskbarMn', 0),
                # Liste de toutes les applications : vue "Liste" (0 = Categorie, 1 = Grille, 2 = Liste)
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Start', 'AllAppsViewMode', 2),
                # Widgets + Meteo desactives (strategie + barre des taches)
                @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds', 'EnableFeeds', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds', 'ShellFeedsTaskbarViewMode', 2)
            )
            $i = 0
            foreach ($it in $items) {
                $i++
                $type = if ($it.Count -gt 3) { $it[3] } else { 'DWord' }
                try { Set-Reg $it[0] $it[1] $it[2] $type }
                catch { L INFO "Skipped (protected or unavailable): $($it[1])" }
                P ([int](30 * $i / $items.Count)) "Start menu setting $i/$($items.Count)"
            }

            # Desepingle TOUT : on supprime les fichiers d'epingles de l'utilisateur ; avec la strategie "liste vide"
            # ci-dessus, Windows les regenere VIDES (nouveaux utilisateurs inclus).
            P 35 "Closing Start menu process"
            Stop-Process -Name 'StartMenuExperienceHost' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $ls = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
            $removed = 0
            P 50 "Deleting pinned layout files"
            foreach ($bin in 'start.bin', 'start2.bin') {
                $f = Join-Path $ls $bin
                if (Test-Path -LiteralPath $f) {
                    try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $removed++; L INFO "Deleted $bin" }
                    catch { L WARNING "Could not delete $bin : $($_.Exception.Message.Split("`n")[0])" }
                }
            }
            P 75 "Restarting Start"
            Start-Sleep -Seconds 2
            Stop-Process -Name 'StartMenuExperienceHost' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            P 100 "Done"
            L SUCCESS "Start menu: all pins removed ($removed layout file(s) reset, empty pinned list enforced) - sign out / Explorer restart finalizes it"
        } catch { L ERROR "Start menu failed: $($_.Exception.Message)" }
    } },

    # Clic droit sur une appli de la barre des taches : option "Terminer la tache" (Windows 11 23H2+)
    @{ Name = "Taskbar - End Task in right-click menu"; Script = {
        param($tempDir)
        try {
            P 30 "Enabling End Task"
            Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 'DWord'
            P 100 "Done"
            L SUCCESS "End Task enabled in the taskbar right-click menu (Windows 11 23H2+) - applied after the Explorer restart"
        } catch { L ERROR "End Task failed: $($_.Exception.Message)" }
    } },

    # ================= INSTALLATION DES LOGICIELS (les unes apres les autres) =================
    # winget : les anciennes versions du script le supprimaient, on s'assure qu'il est present
    @{ Name = "Ensure winget (App Installer)"; Script = {
        param($tempDir)
        try {
            $w = Get-WingetPath
            if ($w) { P 100 "Present"; L SUCCESS "winget available: $w"; return }

            P 5 "Registering App Installer"
            try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop; Start-Sleep -Seconds 3 } catch { L INFO "App Installer is not staged for this user - downloading it" }
            $w = Get-WingetPath
            if ($w) { P 100 "Restored"; L SUCCESS "winget restored: $w"; return }

            # Telechargement depuis Microsoft (aka.ms/getwinget) + dependances officielles
            $vc    = Join-Path $tempDir 'VCLibs.x64.appx'
            $xaml  = Join-Path $tempDir 'UIXaml.x64.appx'
            $bundle = Join-Path $tempDir 'winget.msixbundle'
            P 10 "Downloading dependencies"
            Get-FileAny @('https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx') $vc 10 25
            Get-FileAny @('https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx') $xaml 25 40
            P 40 "Downloading App Installer"
            Get-FileAny @('https://aka.ms/getwinget') $bundle 40 75
            P 78 "Installing App Installer"
            Add-AppxPackage -Path $bundle -DependencyPath $vc, $xaml -ErrorAction Stop
            Start-Sleep -Seconds 3
            $w = Get-WingetPath
            if ($w) { P 100 "Done"; L SUCCESS "winget installed: $w" } else { throw "winget still not found after installation" }
        } catch { L ERROR "winget setup failed: $($_.Exception.Message)" }
    } },

    # Launcher Escape From Tarkov (BSG Launcher - source officielle)
    @{ Name = "Install Escape From Tarkov Launcher"; Script = {
        param($tempDir)
        try {
            $exe = 'C:\Battlestate Games\BsgLauncher\BsgLauncher.exe'
            if (Test-Path -LiteralPath $exe) { P 100 "Already installed"; L SUCCESS "BSG Launcher already installed - skipped"; return }
            $f = Join-Path $tempDir 'BsgLauncher_setup.exe'
            P 0 "Downloading"
            Get-FileAny @('https://launcher.escapefromtarkov.com/launcher/download') $f 0 45
            Invoke-Installer $f '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' 45 98
            Start-Sleep -Seconds 2
            Stop-Process -Name 'BsgLauncher' -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $exe) { L SUCCESS "BSG Launcher installed" }
            else { L WARNING "Installer finished but BsgLauncher.exe not found at the default path" }
        } catch { L ERROR "BSG Launcher failed: $($_.Exception.Message)" }
    } },

    # Steam (source officielle Valve)
    @{ Name = "Install Steam"; Script = {
        param($tempDir)
        try {
            $exe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
            if (Test-Path -LiteralPath $exe) { P 100 "Already installed"; L SUCCESS "Steam already installed - skipped"; return }
            $f = Join-Path $tempDir 'SteamSetup.exe'
            P 0 "Downloading"
            Get-FileAny @('https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe', 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe') $f 0 45
            Invoke-Installer $f '/S' 45 98
            if (Test-Path -LiteralPath $exe) { L SUCCESS "Steam installed" }
            else { L WARNING "Installer finished but steam.exe not found at the default path" }
        } catch { L ERROR "Steam failed: $($_.Exception.Message)" }
    } },

    # VLC : winget (source VideoLAN) en premier, installeur officiel VideoLAN (/S) en secours
    @{ Name = "Install VLC"; Script = {
        param($tempDir)
        try {
            $vlc = "$env:ProgramFiles\VideoLAN\VLC\vlc.exe"
            if (Test-Path -LiteralPath $vlc) { P 100 "Already installed"; L SUCCESS "VLC already installed - skipped"; return }
            $done = $false
            try { P 5 "Installing VLC (winget)"; Install-Winget 'VideoLAN.VLC' 'winget' 5 95; $done = $true }
            catch { L INFO "winget VLC install failed ($($_.Exception.Message)) - trying the official VideoLAN installer" }
            if (-not $done) {
                P 5 "Looking up latest VLC"
                $listing = 'https://get.videolan.org/vlc/last/win64/'
                $html = (Invoke-WebRequest -Uri $listing -UseBasicParsing -ErrorAction Stop).Content
                $m = [regex]::Match($html, 'vlc-[\d\.]+-win64\.exe')
                if (-not $m.Success) { throw "installer name not found in the VideoLAN listing" }
                $f = Join-Path $tempDir $m.Value
                Get-FileAny @(($listing + $m.Value)) $f 5 50
                Invoke-Installer $f '/S' 50 98
            }
            if (Test-Path -LiteralPath $vlc) { L SUCCESS "VLC installed" } else { L WARNING "VLC installer finished but vlc.exe not found at the default path" }
        } catch { L ERROR "VLC failed: $($_.Exception.Message)" }
    } },

    # Plex (application de bureau Plex, via winget). Pour Plex Media Server : remplacer l'id par Plex.PlexMediaServer
    @{ Name = "Install Plex"; Script = {
        param($tempDir)
        try {
            $plexId = 'Plex.Plex'
            P 5 "Installing $plexId"
            Install-Winget $plexId 'winget' 10 98
            P 100 "Done"
            L SUCCESS "Plex installed ($plexId)"
        } catch { L ERROR "Plex failed: $($_.Exception.Message)" }
    } },

    # Google Chrome (MSI entreprise officiel Google)
    @{ Name = "Install Google Chrome"; Script = {
        param($tempDir)
        try {
            $exes = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
            if (@($exes | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) { P 100 "Already installed"; L SUCCESS "Chrome already installed - skipped"; return }
            $f = Join-Path $tempDir 'googlechromestandaloneenterprise64.msi'
            P 0 "Downloading"
            Get-FileAny @('https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi') $f 0 45
            Test-InstallerFile $f
            Invoke-Installer 'msiexec.exe' ('/i "{0}" /qn /norestart' -f $f) 45 98
            L SUCCESS "Google Chrome installed"
        } catch { L ERROR "Chrome failed: $($_.Exception.Message)" }
    } },

    # Discord (installeur officiel, mode silencieux -s)
    @{ Name = "Install Discord"; Script = {
        param($tempDir)
        try {
            if (Test-Path -LiteralPath "$env:LOCALAPPDATA\Discord\Update.exe") { P 100 "Already installed"; L SUCCESS "Discord already installed - skipped"; return }
            $f = Join-Path $tempDir 'DiscordSetup.exe'
            P 0 "Downloading"
            Get-FileAny @('https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x64') $f 0 40
            Invoke-Installer $f '-s' 40 90
            # Discord se lance tout seul apres l'installation : on le ferme
            P 92 "Closing first launch"
            for ($k = 0; $k -lt 20; $k++) {
                if (Get-Process -Name 'Discord' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3; break }
                Start-Sleep -Seconds 1
            }
            Stop-Process -Name 'Discord' -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath "$env:LOCALAPPDATA\Discord\Update.exe") { L SUCCESS "Discord installed" }
            else { L WARNING "Installer finished but Discord was not found in %LOCALAPPDATA%" }
        } catch { L ERROR "Discord failed: $($_.Exception.Message)" }
    } },

    # NanaZip (archiveur moderne, fork de 7-Zip) : winget (Microsoft Store / MSIX)
    @{ Name = "Install NanaZip"; Script = {
        param($tempDir)
        try {
            if (Get-AppxPackage -Name '*NanaZip*' -ErrorAction SilentlyContinue) { P 100 "Already installed"; L SUCCESS "NanaZip already installed - skipped"; return }
            P 5 "Installing NanaZip"
            Install-Winget 'M2Team.NanaZip' 'winget' 8 98
            P 100 "Done"
            if (Get-AppxPackage -Name '*NanaZip*' -ErrorAction SilentlyContinue) { L SUCCESS "NanaZip installed" }
            else { L WARNING "winget finished but the NanaZip package was not found" }
        } catch { L ERROR "NanaZip failed: $($_.Exception.Message)" }
    } },

    # Notepad++ (installeur officiel via winget, mode silencieux)
    @{ Name = "Install Notepad++"; Script = {
        param($tempDir)
        try {
            $exes = @("$env:ProgramFiles\Notepad++\notepad++.exe", "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe")
            if (@($exes | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) { P 100 "Already installed"; L SUCCESS "Notepad++ already installed - skipped"; return }
            P 5 "Installing Notepad++"
            Install-Winget 'Notepad++.Notepad++' 'winget' 8 98
            P 100 "Done"
            if (@($exes | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) { L SUCCESS "Notepad++ installed" }
            else { L WARNING "winget finished but notepad++.exe was not found at the default path" }
        } catch { L ERROR "Notepad++ failed: $($_.Exception.Message)" }
    } },

    # MSI Afterburner + RivaTuner (RTSS) : installation silencieuse (winget, /S) + affichage du nombre de FPS uniquement
    @{ Name = "Install MSI Afterburner + RTSS (FPS only)"; Script = {
        param($tempDir)
        try {
            $abExe  = "${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe"
            $rtDir  = "${env:ProgramFiles(x86)}\RivaTuner Statistics Server"
            $rtExe  = Join-Path $rtDir 'RTSS.exe'

            if (-not (Test-Path -LiteralPath $abExe)) { P 3 "Installing MSI Afterburner"; Install-Winget 'Guru3D.Afterburner' 'winget' 5 60 }
            else { L INFO "MSI Afterburner already installed" }
            if (-not (Test-Path -LiteralPath $rtExe)) { P 60 "Installing RivaTuner Statistics Server"; Install-Winget 'Guru3D.RTSS' 'winget' 60 80 }
            else { L INFO "RTSS already installed" }
            if (-not (Test-Path -LiteralPath $rtExe)) { throw "RTSS.exe not found after installation" }

            # Les installeurs peuvent lancer les programmes : on les ferme avant de modifier la configuration
            P 82 "Closing Afterburner / RTSS"
            foreach ($pn in 'MSIAfterburner', 'RTSS', 'RTSSHooksLoader64', 'RTSSHooksLoader') { Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2

            # Profils RTSS : Global = rien ; EscapeFromTarkov.exe = OSD + "Show own statistics" (compteur de FPS RTSS) ; rien d'autre
            P 85 "Configuring RTSS (FPS counter for Tarkov only)"
            $global = Join-Path $rtDir 'Profiles\Global'
            if (-not (Test-Path -LiteralPath $global)) {
                $proc = Start-Process -FilePath $rtExe -PassThru -WindowStyle Hidden
                for ($k = 0; $k -lt 15; $k++) { if (Test-Path -LiteralPath $global) { break }; Start-Sleep -Seconds 1 }
                Start-Sleep -Seconds 1
                foreach ($pn in 'RTSS', 'RTSSHooksLoader64') { Stop-Process -Name $pn -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds 1
            }
            $enc = [Text.Encoding]::Default
            # Ecrit/MAJ des cles [Settings] dans un profil RTSS (cree le fichier si besoin)
            $setProfile = {
                param($path, $pairs)
                $lines = New-Object 'System.Collections.Generic.List[string]'
                if (Test-Path -LiteralPath $path) {
                    Copy-Item -LiteralPath $path -Destination "$path.cleanwindows.bak" -Force -ErrorAction SilentlyContinue
                    foreach ($ln in [IO.File]::ReadAllLines($path, $enc)) { $lines.Add($ln) }
                }
                foreach ($kv in $pairs) {
                    $idx = -1
                    for ($j = 0; $j -lt $lines.Count; $j++) { if ($lines[$j] -match ('^\s*' + [regex]::Escape($kv[0]) + '\s*=')) { $idx = $j; break } }
                    if ($idx -ge 0) { $lines[$idx] = "$($kv[0])=$($kv[1])" }
                    else {
                        $hdr = $lines.IndexOf('[Settings]')
                        if ($hdr -ge 0) { $lines.Insert($hdr + 1, "$($kv[0])=$($kv[1])") }
                        else { if ($lines.Count -eq 0) { $lines.Add('[Settings]') }; $lines.Add("$($kv[0])=$($kv[1])") }
                    }
                }
                if (-not (Test-Path -LiteralPath (Split-Path $path))) { New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null }
                [IO.File]::WriteAllLines($path, $lines, $enc)
            }

            # Profil Global : OSD et statistiques desactives (aucun affichage FPS dans les autres jeux)
            & $setProfile $global @(@('EnableOSD', '0'), @('EnableStat', '0'))
            L INFO "RTSS global profile: EnableOSD=0, EnableStat=0 (no overlay by default)"

            # Profil EscapeFromTarkov.exe : OSD actif + "Show own statistics" (compteur de FPS) uniquement ici
            $tarkov = Join-Path $rtDir 'Profiles\EscapeFromTarkov.exe'
            & $setProfile $tarkov @(@('EnableOSD', '1'), @('EnableStat', '1'))
            L INFO "RTSS profile EscapeFromTarkov.exe: EnableOSD=1, EnableStat=1 (FPS counter)"
            # MSI Afterburner : aucune sonde matérielle n'est cochee "Show in On-Screen Display" par defaut -> seul le FPS de RTSS s'affiche

            # RTSS doit tourner pour afficher le compteur : on le lance (il se relancera avec Windows)
            P 95 "Starting RTSS"
            Start-Process -FilePath $rtExe -WindowStyle Hidden -ErrorAction SilentlyContinue
            P 100 "Done"
            L SUCCESS "MSI Afterburner + RTSS installed - FPS counter shown only in EscapeFromTarkov.exe (if it is missing after a reboot: RTSS > 'Start with Windows')"
        } catch { L ERROR "Afterburner / RTSS failed: $($_.Exception.Message)" }
    } },

    # Runtimes utiles aux jeux (anciens VC++ + .NET) : evite les erreurs "DLL manquante" au lancement de vieux jeux
    @{ Name = "Gaming Runtimes (legacy VC++ + .NET)"; Timeout = 600; Script = {
        param($tempDir)
        try {
            if (-not (Get-WingetPath)) { P 100 "No winget"; L SKIP "winget not available - runtimes skipped"; return }
            $pkgs = @(
                'Microsoft.VCRedist.2005.x86', 'Microsoft.VCRedist.2005.x64',
                'Microsoft.VCRedist.2008.x86', 'Microsoft.VCRedist.2008.x64',
                'Microsoft.VCRedist.2010.x86', 'Microsoft.VCRedist.2010.x64',
                'Microsoft.VCRedist.2012.x86', 'Microsoft.VCRedist.2012.x64',
                'Microsoft.VCRedist.2013.x86', 'Microsoft.VCRedist.2013.x64',
                'Microsoft.DotNet.DesktopRuntime.8'
            )
            $ok = 0; $ko = 0; $i = 0
            foreach ($pkg in $pkgs) {
                $i++
                $from = [int](100 * ($i - 1) / $pkgs.Count); $to = [Math]::Max($from + 1, [int](100 * $i / $pkgs.Count) - 1)
                try { Install-Winget $pkg 'winget' $from $to; $ok++ }
                catch { $ko++; L INFO "Runtime not installed: $pkg ($($_.Exception.Message))" }
            }
            P 100 "Done"
            if ($ok -gt 0) { L SUCCESS "Gaming runtimes: $ok installed / up to date, $ko unavailable" }
            else { L WARNING "No gaming runtime could be installed (winget unavailable or offline)" }
        } catch { L ERROR "Gaming runtimes failed: $($_.Exception.Message)" }
    } },

    # ================= NVIDIA =================
    # NVCleanstall (TechPowerUp) : installe, mais il n'a AUCUNE ligne de commande pour installer un driver sans interface.
    # Le script reproduit donc son resultat (driver "debloat") avec l'installeur NVIDIA et la selection de composants.
    @{ Name = "NVIDIA - Install NVCleanstall (TechPowerUp)"; Script = {
        param($tempDir)
        try {
            if (@(Get-NvidiaGpu).Count -eq 0) { P 100 "No NVIDIA GPU"; L SKIP "No NVIDIA GPU detected - NVIDIA tasks skipped"; return }
            P 5 "Installing NVCleanstall"
            Install-Winget 'TechPowerUp.NVCleanstall' 'winget' 10 98
            P 100 "Done"
            L SUCCESS "NVCleanstall installed (manual use only - no unattended mode exists)"
        } catch { L ERROR "NVCleanstall install failed: $($_.Exception.Message)" }
    } },

    @{ Name = "NVIDIA - Download latest Game Ready driver"; Timeout = 900; Script = {
        param($tempDir)
        try {
            $gpu = @(Get-NvidiaGpu)
            if ($gpu.Count -eq 0) { P 100 "No NVIDIA GPU"; L SKIP "No NVIDIA GPU detected - skipped"; return }
            L INFO "NVIDIA GPU: $($gpu[0].Name) - installed driver $($gpu[0].DriverVersion)"

            P 2 "Querying NVIDIA for the latest driver"
            $uri  = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&pfid=929&osID=135&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1'
            $resp = Invoke-RestMethod -Uri $uri -ErrorAction Stop
            $info = @($resp.IDS.downloadInfo)[0]
            if (-not $info -or -not $info.DownloadURL) { throw "NVIDIA lookup returned no driver" }
            $url = [string]$info.DownloadURL
            $ver = [string]$info.Version
            L INFO "Latest Game Ready driver: $ver"

            # Version deja installee ? ("32.0.15.7680" -> "576.80")
            $digits = ($gpu[0].DriverVersion -replace '\.', '')
            $cur = if ($digits.Length -ge 5) { $digits.Substring($digits.Length - 5).Insert(3, '.') } else { '' }
            $out = Join-Path $tempDir "nvidia_driver_$ver.exe"
            $skip = ($cur -eq $ver)
            if ($skip) { L INFO "Driver $ver is already installed - download and install skipped" ; P 100 "Already up to date" }
            else {
                $alt = "https://international.download.nvidia.com/Windows/$ver/$ver-desktop-win10-win11-64bit-international-dch-whql.exe"
                Get-FileAny @($url, $alt) $out 5 98
            }
            @{ Url = $url; Version = $ver; File = $out; Skip = $skip } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tempDir 'nvidia_state.json') -Encoding UTF8
            P 100 "Done"
            L SUCCESS "NVIDIA driver $ver ready"
        } catch { L ERROR "NVIDIA driver download failed: $($_.Exception.Message)" }
    } },

    @{ Name = "NVIDIA - Debloated driver install (NVCleanstall-style)"; Timeout = 900; Script = {
        param($tempDir)
        try {
            $stateFile = Join-Path $tempDir 'nvidia_state.json'
            if (@(Get-NvidiaGpu).Count -eq 0 -or -not (Test-Path -LiteralPath $stateFile)) { P 100 "Skipped"; L SKIP "No NVIDIA GPU or no downloaded driver - skipped"; return }
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($state.Skip) { P 100 "Up to date"; L SUCCESS "NVIDIA driver already up to date - skipped"; return }
            if (-not (Test-Path -LiteralPath $state.File)) { throw "Driver package not found: $($state.File)" }
            Test-InstallerFile $state.File

            # --- Extraction (7-Zip : l'installeur NVIDIA est une archive 7z auto-extractible) ---
            $seven = Join-Path $tempDir '7zr.exe'
            if (-not (Test-Path -LiteralPath $seven)) { P 1 "Downloading 7-Zip (7zr)"; Get-FileAny @('https://www.7-zip.org/a/7zr.exe') $seven 1 5 }
            $dir = Join-Path $tempDir 'nvidia_extracted'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
            Invoke-Proc $seven ('x "{0}" -o"{1}" -y' -f $state.File, $dir) $tempDir 6 30 'Extracting driver package' 30
            if ($global:LastExitCode2 -ne 0 -or -not (Get-ChildItem -LiteralPath $dir -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue)) {
                L WARNING "7zr could not extract the package - trying full 7-Zip"
                Install-Winget '7zip.7zip' 'winget' 6 15
                $seven2 = "$env:ProgramFiles\7-Zip\7z.exe"
                if (-not (Test-Path -LiteralPath $seven2)) { throw "No tool available to extract the NVIDIA package" }
                Invoke-Proc $seven2 ('x "{0}" -o"{1}" -y' -f $state.File, $dir) $tempDir 15 30 'Extracting driver package' 30
            }
            $setup = (Get-ChildItem -LiteralPath $dir -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
            if (-not $setup) { throw "setup.exe not found in the extracted NVIDIA package" }
            $root = Split-Path $setup

            # --- Composants : pilote d'affichage (+ audio HDMI/DP + PhysX si presents). Pas de GeForce Experience / NVIDIA App / telemetrie ---
            P 31 "Selecting components"
            $names = @()
            foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Filter '*.nvi' -ErrorAction SilentlyContinue)) {
                $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
                if ($txt -match '<nvi[^>]*\sname="([^"]+)"') { $names += $Matches[1] }
            }
            L INFO ("NVIDIA package components found: " + ($names -join ', '))
            $comps = @('Display.Driver')
            foreach ($n in $names) { if ($n -match '^(HDAudio|Display\.PhysX|PhysX)' -and $comps -notcontains $n) { $comps += $n } }
            L INFO ("Installing components: " + ($comps -join ', '))

            # --- Installation silencieuse (installation propre) ---
            $flags = '-s -noreboot -noeula -nofinish -clean'
            Invoke-Proc $setup ($flags + ' ' + ($comps -join ' ')) $root 32 95 'Installing NVIDIA driver (screen may flicker)' 90
            $code = $global:LastExitCode2
            if ($code -notin 0, 1 -and $comps.Count -gt 1) {
                L WARNING "Install with $($comps.Count) components failed (code $code) - retrying with Display.Driver only"
                Invoke-Proc $setup ($flags + ' Display.Driver') $root 32 95 'Installing NVIDIA driver (display driver only)' 90
                $code = $global:LastExitCode2
            }
            if ($code -notin 0, 1) { throw "NVIDIA setup failed (exit code $code)" }
            if ($code -eq 1) { L INFO "NVIDIA driver installed - reboot required" }

            # --- Debloat post-installation : telemetrie NVIDIA ---
            P 96 "Removing NVIDIA telemetry"
            foreach ($svc in 'NvTelemetryContainer') {
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                if (Test-Path -LiteralPath $k) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; try { Set-Reg $k 'Start' 4; L INFO "Service disabled: $svc" } catch { } }
            }
            Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(NvTm|NvDriverUpdateCheck|NvProfileUpdater|NvNodeLauncher|NVIDIA GeForce Experience)' } | ForEach-Object {
                try { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop; L INFO "Scheduled task removed: $($_.TaskName)" } catch { }
            }
            foreach ($rid in 'EnableRID44231', 'EnableRID64640', 'EnableRID66610') {
                try { Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' $rid 0 } catch { }
            }
            try { Set-Reg 'HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0 } catch { }

            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            P 100 "Done"
            L SUCCESS "NVIDIA driver $($state.Version) installed (display driver + audio + PhysX, no GeForce Experience / NVIDIA App / telemetry)"
        } catch { L ERROR "NVIDIA driver install failed: $($_.Exception.Message)" }
    } },

    @{ Name = "NVIDIA - Control Panel"; Script = {
        param($tempDir)
        try {
            if (@(Get-NvidiaGpu).Count -eq 0) { P 100 "No NVIDIA GPU"; L SKIP "No NVIDIA GPU detected - skipped"; return }
            if (Get-AppxPackage -AllUsers -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue) { P 100 "Already installed"; L SUCCESS "NVIDIA Control Panel already installed - skipped"; return }
            P 5 "Installing NVIDIA Control Panel (Microsoft Store)"
            Install-Winget '9NF8H0H7WMLT' 'msstore' 10 98
            P 100 "Done"
            if (Get-AppxPackage -AllUsers -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue) { L SUCCESS "NVIDIA Control Panel installed" }
            else { L WARNING "winget finished but the Control Panel is not listed yet - open the Microsoft Store and search 'NVIDIA Control Panel' if it is missing" }
        } catch { L ERROR "NVIDIA Control Panel failed: $($_.Exception.Message)" }
    } },

    # Ecran : 2560x1440 a la frequence maximale proposee (jusqu'a 180 Hz) ; sans effet si l'ecran n'a pas ce mode
    @{ Name = "Display Mode (2560x1440 @ up to 180 Hz)"; Script = {
        param($tempDir)
        try {
            P 20 "Setting display mode 2560x1440 @ up to 180 Hz"
                if (-not ('CleanWin.Display' -as [type])) {
                    $cs = @(
                        'using System; using System.Runtime.InteropServices;',
                        'namespace CleanWin { public static class Display {',
                        '[StructLayout(LayoutKind.Sequential)] public struct DEVMODE {',
                        '[MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;',
                        'public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;',
                        'public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;',
                        'public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;',
                        '[MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;',
                        'public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;',
                        'public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight; }',
                        '[DllImport("user32.dll", CharSet=CharSet.Ansi)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);',
                        '[DllImport("user32.dll", CharSet=CharSet.Ansi)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lp);',
                        'public static string SetBest(int w, int h, int maxHz) {',
                        'DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); int best = 0; int i = 0;',
                        'while (EnumDisplaySettings(null, i, ref m)) { if (m.dmPelsWidth == w && m.dmPelsHeight == h && m.dmBitsPerPel >= 32 && m.dmDisplayFrequency <= maxHz && m.dmDisplayFrequency > best) best = m.dmDisplayFrequency; i++; }',
                        'if (best == 0) return "NOMODE";',
                        'DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));',
                        'if (!EnumDisplaySettings(null, -1, ref cur)) return "NOCURRENT";',
                        'if (cur.dmPelsWidth == w && cur.dmPelsHeight == h && cur.dmDisplayFrequency == best) return "ALREADY:" + best;',
                        'cur.dmPelsWidth = w; cur.dmPelsHeight = h; cur.dmDisplayFrequency = best; cur.dmFields = 0x80000 | 0x100000 | 0x400000;',
                        'int r = ChangeDisplaySettingsEx(null, ref cur, IntPtr.Zero, 1, IntPtr.Zero);',
                        'return r == 0 ? "OK:" + best : "ERR:" + r; } } }'
                    ) -join "`n"
                    Add-Type -TypeDefinition $cs -Language CSharp
                }
                $res = [CleanWin.Display]::SetBest(2560, 1440, 180)
                switch -Wildcard ($res) {
                    'OK:*'      { L INFO "Display set to 2560x1440 @ $($res.Substring(3)) Hz" }
                    'ALREADY:*' { L INFO "Display already at 2560x1440 @ $($res.Substring(8)) Hz" }
                    'NOMODE'    { P 100 "No 2K mode"; L SKIP "The display does not offer a 2560x1440 mode - resolution left unchanged"; return }
                    default     { L WARNING "Display mode not changed ($res)" }
                }
                if ($res -like 'OK:*' -or $res -like 'ALREADY:*') {
                    $hz = [int]($res.Split(':')[1])
                    if ($hz -lt 180) { L WARNING "Highest available refresh rate at 2560x1440 is $hz Hz (not 180 Hz) - check cable (DisplayPort recommended) / monitor OSD" }
                }
            P 100 "Done"
            L SUCCESS "Display mode checked (2560x1440, highest refresh rate up to 180 Hz)"
        } catch { L ERROR "Display mode failed: $($_.Exception.Message.Split("`n")[0])" }
    } },

    # Son : format audio spatial de Windows OFF + pas d'attenuation automatique pendant les appels
    @{ Name = "Sound - Disable Windows Spatial Audio"; Script = {
        param($tempDir)
        try {
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
            $name = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'      # format spatial de l'appareil (vide = Desactive)
            P 0 "Listing playback devices"
            $eps = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)
            $changed = 0; $denied = 0; $already = 0
            $i = 0
            foreach ($ep in $eps) {
                $i++
                $fx = "$($ep.PSPath)\FxProperties"
                $cur = $null
                try { $cur = (Get-ItemProperty -LiteralPath $fx -Name $name -ErrorAction Stop).$name } catch { }
                if ($cur) {
                    try { Set-ItemProperty -LiteralPath $fx -Name $name -Value '' -Type String -ErrorAction Stop; $changed++; L INFO "Spatial audio turned OFF for endpoint $($ep.PSChildName)" }
                    catch { $denied++ }
                } else { $already++ }
                P (5 + [int](70 * $i / [Math]::Max(1, $eps.Count))) "Device $i/$($eps.Count)"
            }
            L INFO "Spatial audio: $changed device(s) switched OFF, $already already OFF, $denied protected"
            if ($denied -gt 0) { L WARNING "Windows protects $denied audio device key(s): set Settings > System > Sound > (device) > Spatial audio = Off manually for those" }

            # Comportement des communications : "Ne rien faire" (Discord ne baisse plus le volume du jeu)
            P 85 "Communications ducking off"
            Set-Reg 'HKCU:\Software\Microsoft\Multimedia\Audio' 'UserDuckingPreference' 3
            P 100 "Done"
            L SUCCESS "Windows spatial sound disabled ($changed device(s) changed, $already already off)"
        } catch { L ERROR "Spatial audio step failed: $($_.Exception.Message)" }
    } },

    # Carte reseau : optimisation gaming (IPv4)
    @{ Name = "Network Optimization (Gaming IPv4)"; Script = {
        param($tempDir)
        try {
            P 0 "Detecting network adapters"
            $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
            if ($adapters.Count -eq 0) { L WARNING "No active physical network adapter found - per-adapter tweaks skipped" }
            foreach ($a in $adapters) { L INFO "Adapter: $($a.Name) | $($a.InterfaceDescription) | $($a.LinkSpeed)" }

            # ---- 1) Pile TCP/IP globale ----
            $netsh = @(
                'int tcp set global autotuninglevel=normal',
                'int tcp set global rss=enabled',
                'int tcp set global ecncapability=disabled',
                'int tcp set global timestamps=disabled',
                'int tcp set global rsc=disabled',
                'int tcp set global nonsackrttresiliency=disabled',
                'int tcp set heuristics disabled',
                'int teredo set state disabled',
                'int 6to4 set state disabled',
                'int isatap set state disabled'
            )
            $i = 0
            foreach ($cmd in $netsh) {
                $i++
                $r = Invoke-Native netsh.exe ($cmd -split ' ')
                if ($r.Code -eq 0) { L INFO "netsh $cmd" } else { L INFO "netsh not applied ($cmd): $($r.Out.Trim())" }
                P (2 + [int](23 * $i / $netsh.Count)) "TCP setting $i/$($netsh.Count)"
            }

            # ---- 2) Registre : connexions, priorite IPv4, QoS ----
            $items = @(
                @('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 'TcpTimedWaitDelay', 30),
                @('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters', 'DisabledComponents', 32),   # IPv4 prefere a IPv6 (IPv6 reste actif)
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched', 'NonBestEffortLimit', 0),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient', 'EnableMulticast', 0),                 # LLMNR OFF
                @('HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters', 'EnableMDNS', 0)                    # mDNS OFF
            )
            foreach ($it in $items) { try { Set-Reg $it[0] $it[1] $it[2] } catch { L INFO "Skipped: $($it[1])" } }
            P 30 "Registry tweaks done"

            # ---- 3) Par carte : algorithme de Nagle OFF, offloads / economies d'energie OFF ----
            $props = @(
                @('*FlowControl', 0), @('*InterruptModeration', 0), @('*EEE', 0), @('EEE', 0), @('EnableGreenEthernet', 0),
                @('GreenEthernet', 0), @('PowerSavingMode', 0), @('AutoPowerSaveModeEnabled', 0), @('ULPMode', 0),
                @('AdvancedEEE', 0), @('EEELinkAdvertisement', 0), @('*LsoV2IPv4', 0), @('*RscIPv4', 0), @('*SelectiveSuspend', 0),
                @('*WakeOnMagicPacket', 0), @('*WakeOnPattern', 0), @('*PMARPOffload', 0), @('*PMNSOffload', 0), @('*PriorityVLANTag', 0)
            )
            $n = 0
            foreach ($a in $adapters) {
                $n++
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
                foreach ($kv in @(@('TcpAckFrequency', 1), @('TCPNoDelay', 1), @('TcpDelAckTicks', 0))) {
                    try { Set-Reg $k $kv[0] $kv[1] } catch { L INFO "Skipped Nagle setting $($kv[0]) on $($a.Name)" }
                }
                L INFO "Nagle algorithm disabled on $($a.Name)"
                foreach ($pr in $props) {
                    try {
                        if (Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $pr[0] -ErrorAction SilentlyContinue) {
                            Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $pr[0] -RegistryValue ([string]$pr[1]) -NoRestart -ErrorAction Stop
                            L INFO "$($a.Name): $($pr[0]) = $($pr[1])"
                        }
                    } catch { L INFO "$($a.Name): $($pr[0]) not changed" }
                }
                try { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; L INFO "$($a.Name): power-off to save energy disabled" } catch { }
                P (30 + [int](45 * $n / [Math]::Max(1, $adapters.Count))) "Adapter $n/$($adapters.Count)"
            }

            # ---- 3b) Liaisons / protocoles inutiles (la liste "Cette connexion utilise les elements suivants") ----
            P 75 "Unbinding unused protocols"
            $disableIPv6 = $true     # $false pour conserver IPv6 sur la carte
            $bindings = @('ms_msclient', 'ms_server', 'ms_pacer', 'ms_lldp', 'ms_lltdio', 'ms_rspndr')
            #   ms_msclient = Client pour les reseaux Microsoft | ms_server = Partage de fichiers et imprimantes
            #   ms_pacer = Planificateur de paquets QoS | ms_lldp / ms_lltdio / ms_rspndr = LLDP, detection de topologie reseau
            if ($disableIPv6) { $bindings += 'ms_tcpip6' }
            foreach ($a in $adapters) {
                foreach ($comp in $bindings) {
                    try { Disable-NetAdapterBinding -Name $a.Name -ComponentID $comp -ErrorAction Stop; L INFO "$($a.Name): binding $comp disabled" }
                    catch { L INFO "$($a.Name): binding $comp unchanged" }
                }
                try { Set-DnsClient -InterfaceIndex $a.ifIndex -RegisterThisConnectionsAddress $false -ErrorAction Stop; L INFO "$($a.Name): DNS self-registration off" } catch { }
                try { Set-NetAdapterPowerManagement -Name $a.Name -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -ErrorAction Stop; L INFO "$($a.Name): Wake-on-LAN off" } catch { }
            }
            # NetBIOS sur TCP/IP desactive
            foreach ($c in @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled -and ($adapters.ifIndex -contains $_.InterfaceIndex) })) {
                try { Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop | Out-Null; L INFO "NetBIOS over TCP/IP disabled on $($c.Description)" } catch { }
            }
            P 77 "Protocols unbound"

            # ---- 4) Redemarrage des cartes pour appliquer (coupure de quelques secondes) ----
            P 78 "Restarting adapters"
            foreach ($a in $adapters) {
                try {
                    Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
                    for ($w = 0; $w -lt 40; $w++) { if ((Get-NetAdapter -Name $a.Name -ErrorAction SilentlyContinue).Status -eq 'Up') { break }; Start-Sleep -Seconds 1 }
                } catch { L INFO "Adapter $($a.Name) will apply the changes at next reboot" }
            }
            P 100 "Done"
            L SUCCESS "Network optimized for gaming (IPv4): unused protocols unbound, Nagle off, RSC/LSO off, no power saving, TCP stack tuned"
        } catch { L ERROR "Network optimization failed: $($_.Exception.Message)" }
    } },

    # Services Windows inutiles pour le gaming : arretes + desactives (REVERSIBLE : un script de restauration est genere)
    @{ Name = "Services Optimization (Gaming)"; Script = {
        param($tempDir)
        try {
            P 0 "Preparing service list"
            # Services desactives (Start = 4). Rien n'est supprime : tout se restaure avec le script genere dans Documents.
            $services = @(
                # Telemetrie / diagnostics / rapports
                'DiagTrack', 'dmwappushservice', 'WerSvc', 'wercplsupport', 'PcaSvc', 'DPS', 'WdiServiceHost', 'WdiSystemHost',
                'diagnosticshub.standardcollector.service', 'GraphicsPerfSvc', 'webthreatdefsvc',
                # Impression / fax / scanner
                'Spooler', 'PrintNotify', 'Fax', 'stisvc',
                # Cartes, localisation, capteurs, telephone, realite mixte
                'MapsBroker', 'lfsvc', 'PhoneSvc', 'SensorDataService', 'SensrSvc', 'SensorService', 'tzautoupdate', 'SmsRouter',
                'MixedRealityOpenXRSvc', 'perceptionsimulation', 'spectrum', 'SharedRealitySvc', 'WalletService', 'SEMgrSvc',
                # Reseau / partage / acces distant
                'LanmanServer', 'lmhosts', 'lltdsvc', 'upnphost', 'SharedAccess', 'icssvc', 'WinRM', 'WebClient', 'RpcLocator',
                'SessionEnv', 'TermService', 'UmRdpService', 'RemoteRegistry', 'WMPNetworkSvc', 'WFDSConMgrSvc', 'TapiSrv',
                'PNRPsvc', 'p2psvc', 'p2pimsvc', 'PNRPAutoReg', 'CscService', 'workfolderssvc',
                # Cartes a puce / entreprise / divers
                'SCardSvr', 'ScDeviceEnum', 'SCPolicySvc', 'CertPropSvc', 'EntAppSvc', 'AppVClient', 'UevAgentService', 'embeddedmode',
                'WpcMonSvc', 'Wecsvc', 'wisvc', 'RetailDemo', 'TrkWks', 'CDPSvc', 'AJRouter', 'ALG', 'SDRSVC',
                # Xbox (deja desinstalles par la tache Xbox, on s'assure qu'ils restent coupes)
                'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc'
            )
            # Services "par utilisateur" : on desactive le modele (effectif a la prochaine ouverture de session)
            $perUser = @('OneSyncSvc', 'UserDataSvc', 'UnistoreSvc', 'PimIndexMaintenanceSvc', 'MessagingService', 'CDPUserSvc',
                         'DevicesFlowUserSvc', 'PrintWorkflowUserSvc', 'BcastDVRUserService', 'AarSvc', 'webthreatdefusersvc')

            # SysMain (Superfetch) : inutile sur SSD, conserve sur disque dur
            $ssd = $false
            try {
                $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
                $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [int]$_.DeviceId -eq $disk.Number }
                if ($pd.MediaType -eq 'SSD') { $ssd = $true }
            } catch { }
            if ($ssd) { $services += 'SysMain'; L INFO "System drive is an SSD: SysMain (Superfetch) disabled" } else { L INFO "System drive type not SSD/unknown: SysMain left as is" }

            $backup = New-Object 'System.Collections.Generic.List[string]'
            $backup.Add('# Restaure les services modifies par All-In-One Clean Windows (lancer en administrateur, puis redemarrer)')
            $changed = 0; $absent = 0; $already = 0; $failed = 0
            $all = @($services) + @($perUser)
            $i = 0
            foreach ($s in $all) {
                $i++
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
                if (-not (Test-Path -LiteralPath $k)) { $absent++ }
                else {
                    $orig = $null
                    try { $orig = (Get-ItemProperty -LiteralPath $k -Name 'Start' -ErrorAction Stop).Start } catch { }
                    if ($orig -eq 4 -or $null -eq $orig) { $already++ }
                    else {
                        if ($perUser -notcontains $s) { Invoke-Native sc.exe @('stop', $s) | Out-Null }
                        $ok = $false
                        try { Set-Reg $k 'Start' 4; $ok = $true } catch { }
                        if (-not $ok) { $r = Invoke-Native sc.exe @('config', $s, 'start=', 'disabled'); if ($r.Code -eq 0) { $ok = $true } }
                        if ($ok) { $changed++; $backup.Add("Set-ItemProperty -LiteralPath '$k' -Name 'Start' -Value $orig"); L INFO "Service disabled: $s (was Start=$orig)" }
                        else { $failed++; L INFO "Service protected, not changed: $s" }
                    }
                }
                P (3 + [int](85 * $i / $all.Count)) "Service $i/$($all.Count)"
            }

            # Windows Search : en demarrage manuel (le menu Demarrer garde sa recherche, mais l'indexeur ne tourne plus en permanence)
            P 90 "Windows Search -> manual"
            $ws = 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch'
            if (Test-Path -LiteralPath $ws) {
                try {
                    $o = (Get-ItemProperty -LiteralPath $ws -Name 'Start').Start
                    if ($o -eq 2) { Set-Reg $ws 'Start' 3; Set-Reg $ws 'DelayedAutostart' 0; $backup.Add("Set-ItemProperty -LiteralPath '$ws' -Name 'Start' -Value 2"); L INFO "WSearch set to manual" }
                } catch { }
            }

            # Script de restauration
            $restore = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CleanWindows-RestoreServices.ps1'
            try { Set-Content -LiteralPath $restore -Value $backup -Encoding UTF8; L INFO "Restore script written: $restore" } catch { L WARNING "Could not write the restore script" }

            P 100 "Done"
            L SUCCESS "Services: $changed disabled, $already already off, $absent not present, $failed protected. Restore script: Documents\CleanWindows-RestoreServices.ps1. Reboot to apply fully"
        } catch { L ERROR "Services optimization failed: $($_.Exception.Message)" }
    } },

    # Programmes au demarrage : tout est desactive sauf peripheriques / audio / RTSS (reversible via Gestionnaire des taches > Demarrage)
    @{ Name = "Startup Programs + Scheduled Tasks (Minimal)"; Script = {
        param($tempDir)
        try {
            # A garder : logiciels de peripheriques (souris/clavier/casque), audio Realtek, RTSS (compteur de FPS)
            $keep = 'Logitech|LGHUB|Razer|Synapse|Corsair|iCUE|SteelSeries|Wooting|Realtek|RtkAud|RTHDVCPL|RTSS'
            $disabledBytes = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)    # meme valeur que le Gestionnaire des taches ("Desactive")
            $approved = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
            $targets = @(
                @{ Run = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                      Ap = "HKCU:\$approved\Run" },
                @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                      Ap = "HKLM:\$approved\Run" },
                @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';          Ap = "HKLM:\$approved\Run32" }
            )
            $count = 0; $kept = 0
            P 0 "Scanning startup entries"
            foreach ($tg in $targets) {
                $props = @()
                try { $props = @((Get-ItemProperty -LiteralPath $tg.Run -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }) } catch { }
                foreach ($pr in $props) {
                    if ($pr.Name -match $keep -or [string]$pr.Value -match $keep) { $kept++; L INFO "Startup kept: $($pr.Name)"; continue }
                    try { Set-Reg $tg.Ap $pr.Name $disabledBytes 'Binary'; $count++; L INFO "Startup disabled: $($pr.Name)" } catch { L INFO "Startup entry protected: $($pr.Name)" }
                }
            }
            P 30 "Startup folders"
            $folders = @(
                @{ Dir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";           Ap = "HKCU:\$approved\StartupFolder" },
                @{ Dir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp";       Ap = "HKLM:\$approved\StartupFolder" }
            )
            foreach ($fd in $folders) {
                foreach ($f in @(Get-ChildItem -LiteralPath $fd.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                    if ($f.Name -match $keep) { $kept++; continue }
                    try { Set-Reg $fd.Ap $f.Name $disabledBytes 'Binary'; $count++; L INFO "Startup folder item disabled: $($f.Name)" } catch { }
                }
            }
            L INFO "Startup entries disabled: $count (kept: $kept)"

            # Taches planifiees de telemetrie / diagnostic / sync inutiles (certaines sont protegees par Windows : ignorees)
            P 45 "Scheduled tasks"
            $tasks = @(
                @('\Microsoft\Windows\Application Experience\', '*'),
                @('\Microsoft\Windows\Customer Experience Improvement Program\', '*'),
                @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
                @('\Microsoft\Windows\Feedback\Siuf\', '*'),
                @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
                @('\Microsoft\Windows\Maps\', '*'),
                @('\Microsoft\Windows\Autochk\', 'Proxy'),
                @('\Microsoft\Windows\Device Information\', '*'),
                @('\Microsoft\Windows\Power Efficiency Diagnostics\', 'AnalyzeSystem'),
                @('\Microsoft\Windows\Shell\', 'FamilySafetyMonitor'),
                @('\Microsoft\Windows\Shell\', 'FamilySafetyRefreshTask'),
                @('\Microsoft\Windows\Windows Media Sharing\', '*'),
                @('\Microsoft\Windows\SettingSync\', '*'),
                @('\Microsoft\Windows\UNP\', '*'),
                @('\Microsoft\Windows\Work Folders\', '*'),
                @('\Microsoft\Windows\RetailDemo\', '*'),
                @('\Microsoft\Windows\WDI\', 'ResolutionHost'),
                @('\Microsoft\Windows\Diagnosis\', 'Scheduled'),
                @('\Microsoft\XblGameSave\', '*')
            )
            $tc = 0; $n = 0
            foreach ($tk in $tasks) {
                $n++
                foreach ($x in @(Get-ScheduledTask -TaskPath $tk[0] -TaskName $tk[1] -ErrorAction SilentlyContinue)) {
                    if ($x.State -eq 'Disabled') { continue }
                    try { Disable-ScheduledTask -TaskPath $x.TaskPath -TaskName $x.TaskName -ErrorAction Stop | Out-Null; $tc++; L INFO "Scheduled task disabled: $($x.TaskPath)$($x.TaskName)" } catch { }
                }
                P (45 + [int](50 * $n / $tasks.Count)) "Scheduled tasks $n/$($tasks.Count)"
            }
            P 100 "Done"
            L SUCCESS "Startup minimized: $count startup entries disabled ($kept kept: peripherals / audio / RTSS), $tc scheduled tasks disabled. Re-enable any entry in Task Manager > Startup"
        } catch { L ERROR "Startup cleanup failed: $($_.Exception.Message)" }
    } },

    # Moins de processus : svchost regroupe + etat avant/apres
    @{ Name = "Process Reduction (svchost grouping)"; Script = {
        param($tempDir)
        try {
            P 0 "Counting processes"
            $before = @(Get-Process -ErrorAction SilentlyContinue).Count
            $svch   = @(Get-Process -Name svchost -ErrorAction SilentlyContinue).Count
            L INFO "Processes now: $before (svchost: $svch)"

            # Windows eclate les services en un svchost par service quand la RAM est > 3,5 Go.
            # Un seuil superieur a la RAM installee les regroupe : beaucoup moins de processus svchost.
            P 40 "Grouping services into fewer svchost processes"
            $ramKB = [uint64]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1KB)
            $thr = [int][Math]::Min($ramKB + 1048576, 2147483647)
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' $thr
            L INFO "SvcHostSplitThresholdInKB = $thr (RAM: $ramKB KB)"

            P 100 "Done"
            L SUCCESS "svchost grouping enabled (process count drops after reboot: $before processes now, $svch svchost). Disabled services also stop at next boot"
        } catch { L ERROR "Process reduction failed: $($_.Exception.Message)" }
    } },

    # PC haut de gamme (ex. i7-13700K + RTX 4080) : memoire, disque, pilotes Windows Update
    @{ Name = "High-End PC Tweaks (i7-13700K / RTX 4080 class)"; Script = {
        param($tempDir)
        try {
            P 0 "Detecting hardware"
            $cpu   = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
            $build = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber
            $gpu   = @(Get-NvidiaGpu | Select-Object -First 1)
            L INFO ("CPU: {0} ({1} cores / {2} threads) | RAM: {3} GB | GPU: {4}" -f $cpu.Name, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $ramGB, $gpu.Name)
            if ($build -lt 22000) { L WARNING "Windows 10 detected: Windows 11 is recommended for Intel hybrid CPUs (Thread Director P/E-core scheduling)" }
            if ($cpu.Name -match '1[34]\d{3}K') { L INFO "13th/14th gen Intel Core K CPU: keep the BIOS up to date (latest Intel microcode, 0x12B or newer) to avoid Vmin-shift instability" }

            # Memoire : compression et fusion de pages inutiles avec beaucoup de RAM (moins de CPU / latence)
            P 20 "Memory management"
            if ($ramGB -ge 24) {
                foreach ($opt in 'MemoryCompression', 'PageCombining') {
                    try { $h = @{}; $h[$opt] = $true; Disable-MMAgent @h -ErrorAction Stop; L INFO "MMAgent: $opt disabled" } catch { L INFO "MMAgent: $opt unchanged" }
                }
            } else { L INFO "RAM below 24 GB: memory compression left enabled" }

            # Disque : TRIM actif
            P 45 "Disk"
            $r = Invoke-Native fsutil.exe @('behavior', 'set', 'DisableDeleteNotify', '0')
            if ($r.Code -eq 0) { L INFO "TRIM enabled (DisableDeleteNotify = 0)" }

            # Windows Update : ne remplace plus le pilote NVIDIA, pas de redemarrage force pendant une session
            P 60 "Windows Update policy"
            $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            $items = @(
                @($wu, 'ExcludeWUDriversInQualityUpdate', 1),
                @("$wu\AU", 'NoAutoRebootWithLoggedOnUsers', 1),
                @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching', 'SearchOrderConfig', 0)
            )
            foreach ($it in $items) { try { Set-Reg $it[0] $it[1] $it[2] } catch { L INFO "Skipped: $($it[1])" } }
            L INFO "Windows Update will no longer install graphics drivers automatically"

            P 100 "Done"
            L SUCCESS "High-end tweaks applied (memory, TRIM, driver updates locked). Reboot recommended"
        } catch { L ERROR "High-end tweaks failed: $($_.Exception.Message)" }
    } },

    # Demarrage : hyperviseur desactive (moins de surcout, anti-cheats plus sereins) + horloge systeme par defaut
    @{ Name = "Boot Tweaks (hypervisor off, default system timer)"; Script = {
        param($tempDir)
        try {
            P 0 "Reading boot configuration"
            $cur = (Invoke-Native bcdedit.exe @('/enum', '{current}')).Out
            $hv = ($cur -split "`n" | Where-Object { $_ -match 'hypervisorlaunchtype' } | Select-Object -First 1)
            L INFO ("Boot configuration before: " + $(if ($hv) { $hv.Trim() -replace '\s+', ' ' } else { 'hypervisorlaunchtype not set (Windows default)' }))

            P 30 "Disabling hypervisor launch"
            $r = Invoke-Native bcdedit.exe @('/set', '{current}', 'hypervisorlaunchtype', 'off')
            if ($r.Code -eq 0) { L INFO "hypervisorlaunchtype = off (WSL2 / Docker / Windows Sandbox / Android apps stop working; revert: bcdedit /set hypervisorlaunchtype auto)" }
            else { L WARNING "bcdedit hypervisorlaunchtype failed: $($r.Out.Trim())" }

            # Horloge : on s'assure qu'aucun HPET force n'est configure (valeur absente = comportement Windows par defaut, le plus rapide)
            P 65 "Default system timer"
            foreach ($v in 'useplatformclock', 'useplatformtick') {
                $d = Invoke-Native bcdedit.exe @('/deletevalue', $v)
                if ($d.Code -eq 0) { L INFO "bcdedit: forced value '$v' removed" }
            }
            P 100 "Done"
            L SUCCESS "Boot tweaks applied (effective after reboot)"
        } catch { L ERROR "Boot tweaks failed: $($_.Exception.Message)" }
    } },

    # Fonctionnalites Windows optionnelles inutiles pour le gaming (virtualisation, WSL, Sandbox, anciens composants)
    @{ Name = "Optional Windows Features Cleanup (Hyper-V / WSL / Sandbox / legacy)"; Timeout = 600; Script = {
        param($tempDir)
        try {
            $candidates = @('Microsoft-Hyper-V-All', 'HypervisorPlatform', 'VirtualMachinePlatform', 'Containers-DisposableClientVM',
                            'Microsoft-Windows-Subsystem-Linux', 'WorkFolders-Client', 'Printing-XPSServices-Features',
                            'SMB1Protocol', 'MicrosoftWindowsPowerShellV2Root', 'Internet-Explorer-Optional-amd64')
            P 0 "Reading optional features (DISM, can take a minute)"
            $feats = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)
            $todo  = @($feats | Where-Object { $_.State -eq 'Enabled' -and ($candidates -contains $_.FeatureName) })
            L INFO "Optional features currently enabled among the candidates: $($todo.Count)"
            $i = 0; $ok = 0; $reboot = $false
            foreach ($f in $todo) {
                $i++
                P (10 + [int](85 * $i / $todo.Count)) "Disabling $($f.FeatureName)"
                try {
                    $r = Disable-WindowsOptionalFeature -Online -FeatureName $f.FeatureName -NoRestart -ErrorAction Stop
                    $ok++
                    if ($r.RestartNeeded) { $reboot = $true }
                    L INFO "Feature disabled: $($f.FeatureName)"
                } catch { L WARNING "Could not disable $($f.FeatureName): $($_.Exception.Message.Split("`n")[0])" }
            }
            P 100 "Done"
            L SUCCESS "Optional features: $ok disabled$(if ($reboot) { ' (reboot required)' })"
        } catch { L ERROR "Optional features cleanup failed: $($_.Exception.Message)" }
    } },

    # Peripheriques : Windows ne coupe plus l'alimentation des ports USB / souris / clavier / carte reseau (micro-coupures en jeu)
    @{ Name = "Device Power Management Off (USB / HID / Network)"; Script = {
        param($tempDir)
        try {
            if (Test-Laptop) { P 100 "Laptop"; L SKIP "Laptop detected - device power saving left enabled (battery life)"; return }
            P 0 "Reading devices"
            $devs = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop)
            $changed = 0; $i = 0
            foreach ($d in $devs) {
                $i++
                if ($d.Enable) {
                    try { Set-CimInstance -InputObject $d -Property @{ Enable = $false } -ErrorAction Stop; $changed++ } catch { }
                }
                if ($i % 5 -eq 0) { P ([int](95 * $i / [Math]::Max(1, $devs.Count))) "Device $i/$($devs.Count)" }
            }
            P 100 "Done"
            L SUCCESS "'Allow the computer to turn off this device' disabled on $changed of $($devs.Count) device(s)"
        } catch { L ERROR "Device power management failed: $($_.Exception.Message)" }
    } },

    # Peripheriques non utilises : entrees "fantomes" du Gestionnaire de peripheriques + anciennes versions de pilotes inutilisees
    @{ Name = "Device Cleanup (ghost devices + old driver packages)"; Timeout = 600; Script = {
        param($tempDir)
        try {
            # ---- 1) Peripheriques fantomes : installes un jour, plus branches ----
            P 0 "Listing devices"
            $present = @{}
            foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) { $present[[string]$d.InstanceId] = $true }
            $allDevs = @(Get-PnpDevice -ErrorAction Stop)
            # Types de peripheriques concernes (USB, manettes/souris/claviers, Bluetooth, anciennes cartes PCI, anciens ecrans, anciens peripheriques audio...)
            $prefixes    = @('USB\', 'USBSTOR\', 'HID\', 'BTHENUM\', 'BTH\', 'PCI\', 'SCSI\', 'DISPLAY\', 'WPDBUSENUM\', 'SWD\MMDEVAPI\', 'USBPRINT\', 'IMAGE\')
            $keepClasses = @('Volume', 'VolumeSnapshot', 'Computer', 'Processor', 'System', 'SecurityDevices', 'Firmware')
            $ghosts = New-Object 'System.Collections.Generic.List[object]'
            foreach ($d in $allDevs) {
                $id = [string]$d.InstanceId
                if ($present.ContainsKey($id) -or ($keepClasses -contains $d.Class)) { continue }
                foreach ($px in $prefixes) { if ($id.StartsWith($px, [StringComparison]::OrdinalIgnoreCase)) { $ghosts.Add($d); break } }
            }
            L INFO "Disconnected (ghost) devices found: $($ghosts.Count) (out of $($allDevs.Count) known devices)"

            $removed = 0; $failed = 0
            if ($ghosts.Count -gt 0) {
                # Liste conservee : un peripherique retire se reinstalle tout seul au prochain branchement
                $csv = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CleanWindows-RemovedGhostDevices.csv'
                try { $ghosts | Select-Object Class, FriendlyName, InstanceId | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8; L INFO "Removed-device list saved: $csv" } catch { }
                $i = 0
                foreach ($d in $ghosts) {
                    $i++
                    $r = Invoke-Native pnputil.exe @('/remove-device', [string]$d.InstanceId)
                    if ($r.Code -in 0, 3010) { $removed++; if ($removed -le 40) { L INFO "Ghost device removed: [$($d.Class)] $($d.FriendlyName)" } } else { $failed++ }
                    P (3 + [int](42 * $i / $ghosts.Count)) "Ghost device $i/$($ghosts.Count)"
                }
            }

            # ---- 2) Anciennes versions de pilotes tiers (ex. anciens pilotes graphiques) : on garde la plus recente ----
            P 50 "Reading third-party driver packages (can take a minute)"
            $drivers = @(Get-WindowsDriver -Online -All -ErrorAction Stop)
            $groups = $drivers | Group-Object -Property { '{0}|{1}|{2}' -f (Split-Path ([string]$_.OriginalFileName) -Leaf), $_.ProviderName, $_.ClassName }
            $targets = New-Object 'System.Collections.Generic.List[object]'
            foreach ($g in $groups) {
                if ($g.Count -lt 2) { continue }
                $sorted = @($g.Group | Sort-Object -Property Date, Version -Descending)
                foreach ($o in ($sorted | Select-Object -Skip 1)) { if (-not $o.BootCritical) { $targets.Add($o) } }
            }
            L INFO "Old third-party driver packages found: $($targets.Count) (of $($drivers.Count) packages)"
            $oldRemoved = 0; $oldInUse = 0; $j = 0
            foreach ($o in $targets) {
                $j++
                # Sans /force : Windows refuse de supprimer un pilote encore utilise par un peripherique
                $r = Invoke-Native pnputil.exe @('/delete-driver', [string]$o.Driver)
                if ($r.Code -in 0, 3010) { $oldRemoved++; L INFO "Old driver removed: $($o.Driver) [$($o.ProviderName) / $($o.ClassName) $($o.Version)]" } else { $oldInUse++ }
                P (52 + [int](46 * $j / [Math]::Max(1, $targets.Count))) "Old driver $j/$($targets.Count)"
            }
            P 100 "Done"
            L SUCCESS "Device cleanup: $removed ghost device(s) removed ($failed not removable), $oldRemoved old driver package(s) removed ($oldInUse kept: still in use)"
        } catch { L ERROR "Device cleanup failed: $($_.Exception.Message)" }
    } },

    # Magasin de composants Windows : supprime les anciennes versions de composants (libere souvent plusieurs Go ; peut durer plusieurs minutes)
    @{ Name = "Component Store Cleanup (DISM)"; Timeout = 900; Script = {
        param($tempDir, $selfPath, $cleanDownloads, $runCleanup)
        try {
            if (-not $runCleanup) { P 100 "Disabled"; L SKIP "Component store cleanup disabled (RunComponentCleanup = false)"; return }
            P 0 "Running DISM StartComponentCleanup"
            Invoke-Proc 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup /NoRestart' '' 3 95 'Cleaning the component store' 150
            $code = $global:LastExitCode2
            P 100 "Done"
            if ($code -in 0, 3010) { L SUCCESS "Component store cleaned (DISM exit code $code)" }
            else { L WARNING "DISM finished with exit code $code" }
        } catch { L ERROR "Component store cleanup failed: $($_.Exception.Message)" }
    } },

    # Controle materiel : RAM (XMP / EXPO), liaison PCIe et Resizable BAR de la carte NVIDIA, DirectStorage (BypassIO)
    @{ Name = "Hardware Health Check (RAM speed, PCIe, Resizable BAR, DirectStorage)"; Script = {
        param($tempDir)
        function Note { param([string]$Text) L INFO ("CHECK " + $Text) }
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and $cs.Model -match 'Virtual|VMware|KVM|HVM') { Note "Virtual machine detected ($($cs.Model)): hardware checks may not be meaningful" }

            P 5 "Memory"
            try {
                $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
                if ($mem.Count -gt 0) {
                    $type = switch ([int]$mem[0].SMBIOSMemoryType) { 34 { 'DDR5' } 26 { 'DDR4' } 24 { 'DDR3' } default { 'unknown type' } }
                    $cfg  = [int](($mem | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum)
                    $gb   = [math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
                    Note "RAM: $gb GB in $($mem.Count) module(s), $type at $cfg MT/s"
                    if (($type -eq 'DDR5' -and $cfg -le 4800) -or ($type -eq 'DDR4' -and $cfg -le 2666)) { Note "HINT RAM: it runs at the standard JEDEC speed - if your kit is rated faster, enable XMP / EXPO in the BIOS" }
                    if ($mem.Count -eq 1) { Note "HINT RAM: a single module = single channel; two identical modules double the memory bandwidth" }
                }
            } catch { Note "RAM: unavailable" }

            P 30 "NVIDIA GPU link"
            try {
                $smi = $null
                foreach ($c in "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") { if (Test-Path -LiteralPath $c) { $smi = $c; break } }
                if (-not $smi) { $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($cmd) { $smi = $cmd.Source } }
                if ($smi) {
                    $q = Invoke-Native $smi @('--query-gpu=name,driver_version,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max', '--format=csv,noheader')
                    if ($q.Code -eq 0 -and $q.Out.Trim()) {
                        $f = @($q.Out.Trim().Split("`n")[0].Split(',') | ForEach-Object { $_.Trim() })
                        Note "GPU: $($f[0]) | driver $($f[1]) | PCIe gen $($f[2]) (max $($f[3])), x$($f[4]) (max x$($f[5]))"
                        if ([int]$f[5] -lt 16) { Note "HINT GPU: the card negotiates only x$($f[5]) - check it sits in the main x16 slot" }
                        elseif ([int]$f[4] -lt [int]$f[5]) { Note "HINT GPU: the link is currently x$($f[4]) instead of x$($f[5]) (can be normal at idle - re-check under load)" }
                    }
                    $m  = Invoke-Native $smi @('-q', '-d', 'MEMORY')
                    $bm = [regex]::Match($m.Out, '(?s)BAR1 Memory Usage\s+Total\s*:\s*(\d+)\s*MiB')
                    if ($bm.Success) {
                        $bar = [int]$bm.Groups[1].Value
                        if ($bar -ge 8192) { Note "Resizable BAR: ON (BAR1 = $bar MiB)" }
                        else { Note "Resizable BAR: OFF (BAR1 = $bar MiB) - HINT: enable 'Above 4G Decoding' and 'Re-Size BAR' in the BIOS" }
                    }
                } else { Note "NVIDIA tools (nvidia-smi) not found: PCIe / Resizable BAR checks skipped" }
            } catch { Note "GPU link: unavailable" }

            P 70 "DirectStorage / BypassIO"
            try {
                $by  = Invoke-Native fsutil.exe @('bypassIo', 'state', "$env:SystemDrive\")
                $txt = (($by.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 3) -join ' / ')
                Note "BypassIO (DirectStorage) on ${env:SystemDrive}: $txt"
            } catch { Note "BypassIO: unavailable" }

            P 100 "Done"
            L SUCCESS "Hardware check completed (see the CHECK / HINT lines in the summary file)"
        } catch { L ERROR "Hardware check failed: $($_.Exception.Message)" }
    } },

    # Verification finale : relit l'etat reel du PC (apparait dans CLEANWINDOWS-RESUME.TXT)
    @{ Name = "Final Check (read-back report)"; Script = {
        param($tempDir)
        function Chk { param($Label, [scriptblock]$Get) try { $v = & $Get; L INFO ("CHECK {0}: {1}" -f $Label, $v) } catch { L INFO ("CHECK {0}: unavailable" -f $Label) } }
        try {
            P 5 "Reading system state"
            Chk 'Active power plan' { ((Invoke-Native powercfg.exe @('/getactivescheme')).Out.Trim() -replace '\s+', ' ') }
            Chk 'Game Mode' { (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\GameBar' -ErrorAction Stop).AutoGameModeEnabled }
            Chk 'GPU scheduling (HwSchMode, 2 = on)' { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode }
            Chk 'Theme apps / system (0 = dark)' { $k = Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop; "$($k.AppsUseLightTheme) / $($k.SystemUsesLightTheme)" }
            Chk 'Window animations (MinAnimate, 0 = off)' { (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction Stop).MinAnimate }
            Chk 'Mouse acceleration (MouseSpeed / Threshold1 / Threshold2, 0 = off) + sensitivity' { $m = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Mouse' -ErrorAction Stop; "$($m.MouseSpeed) / $($m.MouseThreshold1) / $($m.MouseThreshold2) + $($m.MouseSensitivity)" }
            P 30 "Security / virtualization"
            Chk 'Defender real-time protection' { (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled }
            Chk 'Virtualization-based security (0 off, 1 configured, 2 running)' { (Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus }
            Chk 'Hypervisor launch type' { $o = (Invoke-Native bcdedit.exe @('/enum', '{current}')).Out -split "`n" | Where-Object { $_ -match 'hypervisorlaunchtype' } | Select-Object -First 1; if ($o) { $o.Trim() -replace '\s+', ' ' } else { 'not set' } }
            P 55 "Processes / services"
            Chk 'Running processes (svchost)' { "$(@(Get-Process).Count) ($(@(Get-Process -Name svchost -ErrorAction SilentlyContinue).Count))" }
            Chk 'Services running / automatic' { "$(@(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count) / $(@(Get-Service | Where-Object { $_.StartType -eq 'Automatic' }).Count)" }
            P 75 "Network / display / disk"
            Chk 'Active network bindings' { foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) { "$($a.Name): " + ((Get-NetAdapterBinding -Name $a.Name | Where-Object { $_.Enabled } | ForEach-Object { $_.ComponentID }) -join ', ') } }
            Chk 'Display mode' { (Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { "$($_.Name) $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) @ $($_.CurrentRefreshRate) Hz" }) -join ' | ' }
            Chk 'Free space on C:' { "{0:N1} GB" -f ((Get-PSDrive -Name C -ErrorAction Stop).Free / 1GB) }
            P 100 "Done"
            L SUCCESS "Final check completed (see 'VERIFICATION DE L ETAT FINAL' in the summary file)"
        } catch { L ERROR "Final check failed: $($_.Exception.Message)" }
    } },

    # Redemarrage de l'Explorateur (applique menu contextuel, theme, menu demarrer)
    @{ Name = "Restart Explorer (apply changes)"; Script = {
        param($tempDir)
        try {
            P 0 "Restarting Explorer"
            Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            P 60 "Waiting for the shell"
            if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) { Start-Process 'explorer.exe' }
            Start-Sleep -Seconds 2
            P 100 "Done"
            L SUCCESS "Explorer restarted"
        } catch { L ERROR "Explorer restart failed: $($_.Exception.Message)" }
    } },

    # Nettoyage final : Telechargements + disque C:
    @{ Name = "Final Cleanup (Downloads / Disk C:)"; Script = {
        param($tempDir, $selfPath, $cleanDownloads)
        try {
            function Clear-Folder {
                param($Path)
                if (-not (Test-Path -LiteralPath $Path)) { return }
                Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            $free0 = (Get-PSDrive -Name C).Free

            P 0 "User temp files"
            Clear-Folder $env:TEMP
            P 10 "Windows temp files"
            Clear-Folder "$env:SystemRoot\Temp"

            P 20 "Windows Update download cache"
            $wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
            $wasRunning = ($wu -and $wu.Status -eq 'Running')
            Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
            Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download"
            if ($wasRunning) { Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue }

            P 35 "Delivery Optimization cache"
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }

            P 45 "Crash dumps / error reports / thumbnails"
            Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
            Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
            Clear-Folder "$env:SystemRoot\Minidump"
            Clear-Folder "$env:LOCALAPPDATA\CrashDumps"
            Remove-Item -LiteralPath "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            P 60 "Recycle Bin"
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue

            P 70 "Downloads folder"
            if ($cleanDownloads) {
                $dl = $null
                try { $dl = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-6711B66C4B6D}') } catch { }
                if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
                $n = 0
                if (Test-Path -LiteralPath $dl) {
                    foreach ($item in @(Get-ChildItem -LiteralPath $dl -Force -ErrorAction SilentlyContinue)) {
                        # On ne supprime jamais le script lui-meme ni son lanceur
                        if ($item.FullName -eq $selfPath -or $item.Name -like 'AllInOne*' -or $item.Name -like 'Lancer-AllInOne*') { continue }
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        $n++
                    }
                    L INFO "Downloads cleaned: $n item(s) removed from $dl"
                }
            } else { L INFO "Downloads folder cleanup disabled (CleanUserDownloads = false)" }

            P 95 "Computing freed space"
            $freed = [math]::Round(((Get-PSDrive -Name C).Free - $free0) / 1MB)
            P 100 "Done"
            L SUCCESS "Final cleanup completed - about $freed MB freed on C:"
        } catch { L ERROR "Final cleanup failed: $($_.Exception.Message)" }
    } }

    # Edge / WebView2 : optimises (pas supprimes) par la tache "Edge / WebView2 - Gaming Optimization".
)

# =============================================================================
# MAIN EXECUTION
# =============================================================================
# Selection des taches : -Only / -Skip (mots contenus dans le nom, separes par des virgules) et -List
$onlyList = @($Only -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$skipList = @($Skip -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$selected = @($Tasks)
if ($onlyList.Count -gt 0) { $selected = @($selected | Where-Object { $n = $_.Name; @($onlyList | Where-Object { $n -like "*$_*" }).Count -gt 0 }) }
if ($skipList.Count -gt 0) { $selected = @($selected | Where-Object { $n = $_.Name; @($skipList | Where-Object { $n -like "*$_*" }).Count -eq 0 }) }
if ($List) {
    Write-Host ""
    $k = 0
    foreach ($t in $Tasks) { $k++; $mark = if ($selected -contains $t) { '*' } else { ' ' }; Write-Host ("{0} {1,2}. {2}" -f $mark, $k, $t.Name) }
    Write-Host ""
    Write-Host "(* = task that would run with the current -Only / -Skip)" -ForegroundColor Gray
    Read-Host "Press Enter to close"
    Exit
}
if ($selected.Count -eq 0) {
    Write-Host "No task matches -Only / -Skip. Run with -List to see the task names." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    Exit
}
if ($selected.Count -ne $Tasks.Count) { Write-Log "Task selection: $($selected.Count) of $($Tasks.Count) (Only='$Only' Skip='$Skip')" }


Write-Host ""
Write-Host "All-In-One Clean Windows - $($selected.Count) tasks (timeout ${TaskTimeoutSeconds}s each, silent mode)" -ForegroundColor Cyan
Write-Host "Log: $script:ActiveLog" -ForegroundColor Gray
Write-Host ""

$i = 0
foreach ($t in $selected) {
    $i++
    Invoke-Task -Name $t.Name -Script $t.Script -Index $i -Total $selected.Count -Timeout $t.Timeout
}

Write-Progress -Id 1 -Activity "All-In-One Clean Windows" -Completed
Write-Log "=== All-In-One Clean Windows finished ===" "SUCCESS"

$bad = @($script:Summary | Where-Object { $_.Status -like 'TIMEOUT*' -or $_.Status -like 'ERROR*' })
Write-Host ""
if ($bad.Count -eq 0) {
    Write-Host "Done! All tasks completed." -ForegroundColor Green
} else {
    Write-Host "Done with $($bad.Count) problem(s):" -ForegroundColor Yellow
    $bad | ForEach-Object { Write-Host "  - $($_.Name): $($_.Status)" -ForegroundColor Yellow }
}
# Resume pret a envoyer (taches, durees, avertissements / erreurs)
$resumePath = $null
try {
    $desk = [Environment]::GetFolderPath('Desktop')
    $resumePath = Join-Path $desk 'CLEANWINDOWS-RESUME.TXT'
    $out = New-Object 'System.Collections.Generic.List[string]'
    $out.Add("All-In-One Clean Windows - resume - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $out.Add("Duree totale: $([int]((Get-Date) - $script:RunStart).TotalMinutes) min | Log complet: $script:ActiveLog")
    $out.Add('')
    $out.Add('TACHES')
    foreach ($s in $script:Summary) { $out.Add(("  {0,-62} {1,-20} {2,5}s" -f $s.Name, $s.Status, $s.Seconds)) }
    $out.Add('')
    $out.Add('VERIFICATION DE L''ETAT FINAL')
    foreach ($ck in $script:Checks) { $out.Add("  $ck") }
    $out.Add('')
    # Mesures avant -> maintenant (l'effet complet des services / processus n'apparait qu'apres redemarrage)
    try {
        $after = Get-SystemMetrics
        $ref   = $script:BaselineRef
        $out.Add('MESURES (avant -> maintenant ; l''effet complet arrive apres redemarrage)')
        foreach ($mk in $after.Keys) { $out.Add(("  {0,-18} {1,8} -> {2,8}" -f $mk, $(if ($ref) { $ref.$mk } else { 'n/a' }), $after[$mk])) }
        $out.Add('')
    } catch { }
    $out.Add("AVERTISSEMENTS / ERREURS ($($script:Problems.Count))")
    foreach ($pl in $script:Problems) { $out.Add("  $pl") }
    Set-Content -LiteralPath $resumePath -Value $out -Encoding UTF8
} catch { $resumePath = $null }

# --- Rapport "apres redemarrage" : un petit script s'execute UNE fois a la prochaine ouverture de session ---
$postTemplate = @'
Start-Sleep -Seconds 150
$ErrorActionPreference = 'SilentlyContinue'
$baseFile = '__BASE__'
$outFile  = '__OUT__'
$os  = Get-CimInstance Win32_OperatingSystem
$svc = @(Get-Service)
$now = [ordered]@{
    Processes       = @(Get-Process).Count
    Svchost         = @(Get-Process -Name svchost).Count
    ServicesRunning = @($svc | Where-Object { $_.Status -eq 'Running' }).Count
    ServicesAuto    = @($svc | Where-Object { $_.StartType -eq 'Automatic' }).Count
    RamUsedGB       = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
    FreeDiskGB      = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
}
$base = $null
if (Test-Path -LiteralPath $baseFile) { $base = (Get-Content -LiteralPath $baseFile -Raw | ConvertFrom-Json).Metrics }
$o = New-Object 'System.Collections.Generic.List[string]'
$o.Add('All-In-One Clean Windows - apres redemarrage - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$o.Add('(mesure environ 2 min 30 apres l''ouverture de session ; "avant" = mesure prise avant le premier passage du script)')
$o.Add('')
foreach ($k in $now.Keys) { $b = if ($base) { $base.$k } else { 'n/a' }; $o.Add(('  {0,-18} {1,8} -> {2,8}' -f $k, $b, $now[$k])) }
try {
    $e  = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1
    $x  = [xml]$e.ToXml()
    $bt = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
    if ($bt) { $o.Add(''); $o.Add(('  Boot time reported by Windows: {0:N1} s' -f ([double]$bt / 1000))) }
} catch { }
Set-Content -LiteralPath $outFile -Value $o -Encoding UTF8
'@
try {
    $postFile = Join-Path $docs 'CleanWindows-PostReboot.ps1'
    $deskDir  = [Environment]::GetFolderPath('Desktop')
    $postText = $postTemplate.Replace('__BASE__', $script:BaselineFile.Replace("'", "''")).Replace('__OUT__', (Join-Path $deskDir 'CLEANWINDOWS-APRES-REBOOT.TXT').Replace("'", "''"))
    Set-Content -LiteralPath $postFile -Value $postText -Encoding UTF8
    $ro = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $ro)) { New-Item -Path $ro -Force | Out-Null }
    Set-ItemProperty -LiteralPath $ro -Name 'CleanWindowsPostReboot' -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $postFile)
    Write-Log "Post-reboot comparison scheduled (runs once at next sign-in): Desktop\CLEANWINDOWS-APRES-REBOOT.TXT"
} catch { Write-Log "Could not schedule the post-reboot report: $($_.Exception.Message)" "WARNING" }
Write-Host "Full log: $script:ActiveLog" -ForegroundColor Gray
if ($resumePath) { Write-Host "Summary (send me this file if something failed): $resumePath" -ForegroundColor White }
Write-Host "After the next reboot, a before/after comparison appears on your Desktop (CLEANWINDOWS-APRES-REBOOT.TXT)." -ForegroundColor Gray
Write-Host ""
Read-Host "Press Enter to close"

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
