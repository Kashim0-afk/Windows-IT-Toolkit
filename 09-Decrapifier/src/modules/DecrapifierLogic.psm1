# DecrapifierLogic.psm1 — logica detection + dry-run + apply (con backup)

# Common.psm1 va importato QUI, non solo in Main.ps1: Invoke-Decrapifier e
# Restore-AppxFromBackup chiamano Test-IsAdmin (e Protect-FileOwnerOnly) ma
# girano dentro un runspace isolato, dove i moduli caricati dal thread UI non
# sono visibili e _shared non è in PSModulePath (niente autoload).
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_shared\modules\Common.psm1') -DisableNameChecking

# Blacklist hardcoded di package AppX critici per il funzionamento di Windows.
# Anche se l'utente li mette nel profilo JSON, questo modulo li FILTRA via prima
# di Remove-AppxPackage. La blacklist è deliberatamente ampia: È meglio non
# rimuovere qualcosa di rimovibile che rompere features core di sistema.
$script:CriticalAppxPrefixes = @(
    'Microsoft.WindowsStore',                  # Microsoft Store
    'Microsoft.MicrosoftEdge',                 # Edge
    'Microsoft.Edge',                          # Edge variants
    'Microsoft.WindowsTerminal',
    'Microsoft.Windows.Terminal',
    'Microsoft.WindowsCalculator',
    'Microsoft.WindowsAppRuntime',             # runtime AppX framework
    'Microsoft.UI.Xaml',                       # framework
    'Microsoft.VCLibs',                        # framework C++
    'Microsoft.NET',                           # framework .NET
    'Microsoft.Services.Store',
    'Microsoft.DesktopAppInstaller',           # winget
    'Microsoft.WindowsNotepad',
    'Microsoft.SecHealthUI',                   # Windows Security UI
    'Microsoft.AAD.BrokerPlugin',              # Azure AD broker (login aziendale)
    'Microsoft.AccountsControl',               # account login
    'Microsoft.Win32WebViewHost',
    'Microsoft.WebMediaExtensions',
    'Microsoft.HEIFImageExtension',
    'Microsoft.HEVCVideoExtension',
    'Microsoft.RawImageExtension',
    'Microsoft.WebpImageExtension',
    'Microsoft.VP9VideoExtensions',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.ScreenSketch',                  # Snipping Tool
    'Microsoft.Windows.Photos',
    'Microsoft.Paint',
    'Microsoft.Windows.SecHealthUI',
    'Windows.CBSPreview',
    'Windows.PrintDialog',
    'Microsoft.LockApp',                       # lock screen
    'Microsoft.Windows.ContentDeliveryManager',
    'Microsoft.Windows.ParentalControls',
    'Microsoft.Windows.PeopleExperienceHost',
    'Microsoft.Windows.PinningConfirmationDialog',
    'Microsoft.Windows.SecureAssessmentBrowser',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.Windows.AssignedAccessLockApp',
    'Microsoft.Windows.CapturePicker',
    'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.Windows.NarratorQuickStart',
    'Microsoft.Windows.OOBENetworkConnectionFlow',
    'Microsoft.Windows.OOBENetworkCaptivePortal',
    'Microsoft.MicrosoftEdgeDevToolsClient',
    'Microsoft.UI.Xaml.CBS'
)

function Test-IsCriticalAppx {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($prefix in $script:CriticalAppxPrefixes) {
        # OrdinalIgnoreCase obbligatorio: String.StartsWith(string) è
        # case-sensitive mentre -eq non lo è. Un profilo JSON che scrivesse
        # 'microsoft.windowsstore' in minuscolo aggirava la blacklist di
        # sicurezza e l'app critica compariva fra quelle "da rimuovere".
        $cmp = [StringComparison]::OrdinalIgnoreCase
        if ($Name -eq $prefix -or $Name.StartsWith("$prefix.", $cmp) -or $Name.StartsWith("$prefix-", $cmp)) {
            return $true
        }
    }
    return $false
}

function Get-AppxPresent {
    [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Names)
    $all = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    $hits = @()
    foreach ($n in $Names) {
        # NON $matches: e' la variabile automatica riempita da -match.
        # Qui non c'e' ancora un -match a valle che ne dipenda, ma basta
        # aggiungerne uno per avere un bug non diagnosticabile.
        $found = @($all | Where-Object { $_.Name -eq $n })
        foreach ($m in $found) {
            $hits += [pscustomobject]@{
                Name           = $m.Name
                FullName       = $m.PackageFullName
                Publisher      = $m.Publisher
                Version        = $m.Version
                InstallLocation= $m.InstallLocation
            }
        }
    }
    return $hits
}

function Get-DecrapifierPlan {
    # NOTA: parametro nominato $ProfileObject (non $Profile) perché $Profile è
    # variabile automatica di PowerShell (path al profile script PS).
    [CmdletBinding()] param([Parameter(Mandatory)][object]$ProfileObject)
    $appxList = if ($ProfileObject.appxRemove) { @($ProfileObject.appxRemove) } else { @() }

    # FILTRO SICUREZZA: rimuovi dalla lista qualsiasi pacchetto critico di sistema,
    # anche se l'utente lo ha messo nel profilo. La blacklist sovrascrive sempre
    # la whitelist del profilo per do-no-harm.
    $blocked = @($appxList | Where-Object { Test-IsCriticalAppx $_ })
    $allowed = @($appxList | Where-Object { -not (Test-IsCriticalAppx $_) })

    $present  = @(Get-AppxPresent -Names $allowed)

    $presentNames = @()
    if ($present.Count -gt 0) { $presentNames = @($present | ForEach-Object { $_.Name } | Sort-Object -Unique) }

    return [pscustomobject]@{
        ProfileName       = $ProfileObject.name
        AppxToRemove      = $present
        AppxNotInstalled  = @($allowed | Where-Object { $_ -notin $presentNames })
        AppxBlockedSafety = $blocked
    }
}

function Backup-AppxState {
    param([Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    # Il backup viene riletto DA ADMIN durante il restore: se un utente standard
    # può scriverci, può pilotare cosa viene reinstallato con privilegi elevati.
    $null = Protect-FileOwnerOnly -Path $BackupDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "appx-state-$stamp"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-AppxPackage -ErrorAction SilentlyContinue | Export-Clixml -Path (Join-Path $dest 'appx-installed.xml')
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Export-Clixml -Path (Join-Path $dest 'appx-provisioned.xml')
    return $dest
}

function Read-DecrapifierProfile {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Profilo non trovato: $Path" }
    $raw = Get-Content $Path -Raw -Encoding UTF8
    try {
        $obj = $raw | ConvertFrom-Json
    } catch {
        throw ("Profilo JSON non valido ({0}): {1}" -f $Path, $_.Exception.Message)
    }
    if (-not $obj.PSObject.Properties.Match('name').Count -or [string]::IsNullOrWhiteSpace($obj.name)) {
        throw ("Profilo {0}: campo 'name' mancante." -f $Path)
    }
    if (-not $obj.PSObject.Properties.Match('appxRemove').Count) {
        throw ("Profilo {0}: campo 'appxRemove' mancante (anche se vuoto, dichiararlo come array)." -f $Path)
    }
    # Sanity: niente wildcard nei nomi (whitelist esatta)
    $bad = @($obj.appxRemove | Where-Object { $_ -match '[\*\?]' })
    if ($bad.Count -gt 0) {
        throw ("Profilo {0}: wildcard rilevati nei nomi (vietato per sicurezza): {1}" -f $Path, ($bad -join ', '))
    }
    return $obj
}

function Restore-AppxFromBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [scriptblock]$Log = $null
    )
    if (-not (Test-IsAdmin)) {
        throw "Restore richiede privilegi amministratore."
    }
    $provFile = Join-Path $BackupPath 'appx-provisioned.xml'
    if (-not (Test-Path $provFile)) { throw "Backup incompleto: $provFile non trovato." }

    # Limite di dimensione sui file di backup: stanno in una cartella che un
    # utente standard può aver creato per primo, quindi sono input non fidato.
    # Import-Clixml non è un deserializzatore RCE (produce property bag), ma un
    # XML gonfiato può esaurire la memoria del runspace. Un backup reale sta
    # ampiamente sotto i 20 MB.
    foreach ($bf in @($provFile, (Join-Path $BackupPath 'appx-installed.xml'))) {
        if ((Test-Path $bf) -and ((Get-Item $bf).Length -gt 20MB)) {
            throw "File di backup anomalo (oltre 20 MB): $bf. Ripristino annullato."
        }
    }

    function _log($lvl, $msg) { if ($Log) { & $Log $lvl $msg } }

    _log 'Info' "Carico backup: $provFile"
    $provisioned = Import-Clixml -Path $provFile

    # Il file di backup sta in una cartella scrivibile dall'utente: il suo
    # contenuto NON è fidato. InstallLocation viene usato per costruire il
    # percorso di un AppxManifest.xml che poi installiamo online DA ADMIN, quindi
    # un utente standard potrebbe farci provisionare un pacchetto arbitrario
    # (persistenza su ogni nuovo profilo). Vincoliamo la provenienza alle sole
    # radici di sistema dove vivono davvero i pacchetti provisioned e dove un
    # utente standard non può scrivere.
    $allowedRoots = @(
        # ProgramW6432 incluso: sotto un host PowerShell a 32 bit
        # $env:ProgramFiles vale 'Program Files (x86)', WindowsApps non
        # combaciava e OGNI ripristino veniva rifiutato come manomesso.
        (Join-Path $env:ProgramFiles 'WindowsApps')
        (Join-Path $env:ProgramW6432 'WindowsApps')
        (Join-Path $env:SystemRoot   'SystemApps')
        (Join-Path $env:SystemRoot   'InfusedApps')
    ) | ForEach-Object { try { [IO.Path]::GetFullPath($_).TrimEnd('\') } catch { $null } } | Where-Object { $_ }

    function _isTrustedInstallLocation($loc) {
        if ([string]::IsNullOrWhiteSpace($loc)) { return $false }
        $full = try { [IO.Path]::GetFullPath($loc) } catch { return $false }
        foreach ($root in $allowedRoots) {
            if ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    # Stato corrente: che AppxProvisionedPackage sono ancora online?
    $current = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageName })
    $missing = @($provisioned | Where-Object { $_.PackageName -and ($current -notcontains $_.PackageName) })

    $ok = 0; $ko = 0

    # --- Ripristino dei pacchetti PER-UTENTE ---
    # Invoke-Decrapifier usa Remove-AppxPackage, che rimuove il pacchetto per
    # l'utente corrente e NON tocca gli AppxProvisionedPackage. Ripristinare
    # solo i provisioned significava quindi non ripristinare NULLA di ciò che il
    # tool aveva effettivamente rimosso: "Reinstallati: 0" dopo ogni Applica,
    # mentre la finestra di conferma prometteva che l'operazione era reversibile.
    $installedFile = Join-Path $BackupPath 'appx-installed.xml'
    if (Test-Path $installedFile) {
        try {
            $backedUp = Import-Clixml -Path $installedFile
            $nowInstalled = @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFullName })
            $userMissing = @($backedUp | Where-Object {
                $_.PackageFullName -and ($nowInstalled -notcontains $_.PackageFullName) -and -not $_.IsFramework
            })
            foreach ($p in $userMissing) {
                # Stessa validazione di provenienza usata per i provisioned: il
                # file di backup non è fidato.
                if (-not (_isTrustedInstallLocation $p.InstallLocation)) {
                    _log 'Warning' "IGNORATO $($p.Name): percorso fuori dalle radici di sistema."
                    $ko++; continue
                }
                $man = Join-Path $p.InstallLocation 'AppxManifest.xml'
                if (-not (Test-Path $man)) {
                    _log 'Warning' "$($p.Name): file dell'app non più presenti sul disco, va reinstallata dallo Store."
                    $ko++; continue
                }
                try {
                    Add-AppxPackage -Register $man -DisableDevelopmentMode -ErrorAction Stop
                    _log 'Success' "Ripristinata (utente): $($p.Name)"
                    $ok++
                } catch {
                    _log 'Warning' "Ripristino fallito per $($p.Name): $($_.Exception.Message)"
                    $ko++
                }
            }
        } catch {
            _log 'Warning' "Backup per-utente non leggibile: $($_.Exception.Message)"
        }
    }

    if ($missing.Count -eq 0) {
        if ($ok -eq 0 -and $ko -eq 0) {
            _log 'Info' 'Nessuna app da ripristinare: tutte quelle presenti nel backup risultano già installate.'
        }
        return [pscustomobject]@{ Restored = $ok; Failed = $ko }
    }

    foreach ($p in $missing) {
        try {
            if ($p.InstallLocation -and -not (_isTrustedInstallLocation $p.InstallLocation)) {
                _log 'Warning' "IGNORATO $($p.DisplayName): percorso fuori dalle radici di sistema ($($p.InstallLocation)). Backup possibilmente manomesso."
                $ko++
                continue
            }
            if ($p.InstallLocation -and (Test-Path $p.InstallLocation)) {
                $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
                if (Test-Path $manifest) {
                    Add-AppxProvisionedPackage -Online -PackagePath $manifest -SkipLicense -ErrorAction Stop | Out-Null
                    _log 'Success' "Ripristinato: $($p.DisplayName)"
                    $ok++
                    continue
                }
            }
            _log 'Warning' "Manifest non trovato per $($p.DisplayName) - può richiedere reinstall manuale dallo Store."
            $ko++
        } catch {
            _log 'Warning' "Restore fallito per $($p.DisplayName): $($_.Exception.Message)"
            $ko++
        }
    }
    return [pscustomobject]@{ Restored = $ok; Failed = $ko }
}

function Invoke-Decrapifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$BackupDir,
        [scriptblock]$Log = $null,
        [scriptblock]$CancelCheck = $null
    )
    if (-not (Test-IsAdmin)) {
        throw "Operazione richiede privilegi amministratore."
    }

    function _log($lvl, $msg) { if ($Log) { & $Log $lvl $msg } }

    _log 'Info' 'Backup stato AppX...'
    $bk = Backup-AppxState -BackupDir $BackupDir
    _log 'Success' "Backup: $bk"

    $removedOk = 0; $removedKo = 0
    $cancelled = $false
    foreach ($app in $Plan.AppxToRemove) {
        # Annullamento fra una rimozione e l'altra: l'operazione puo' durare
        # 60-120s su 20+ AppX e finora non c'era modo di fermarla. Il controllo
        # sta fra un pacchetto e il successivo, mai a meta' di una rimozione:
        # interrompere Remove-AppxPackage lascerebbe l'app in stato incoerente.
        if ($CancelCheck -and (& $CancelCheck)) {
            _log 'Warning' "Operazione interrotta dall'utente. Rimossi finora: $removedOk."
            $cancelled = $true
            break
        }
        # Doppio check di sicurezza: anche se Get-DecrapifierPlan ha già filtrato,
        # verifichiamo nuovamente che il pacchetto non sia critico prima di rimuoverlo.
        if (Test-IsCriticalAppx $app.Name) {
            _log 'Warning' "SKIP (critico): $($app.Name) - protezione blacklist."
            continue
        }
        try {
            Remove-AppxPackage -Package $app.FullName -ErrorAction Stop
            _log 'Success' "Rimosso: $($app.Name)"
            $removedOk++
        } catch {
            _log 'Warning' "Non rimosso $($app.Name): $($_.Exception.Message)"
            $removedKo++
        }
    }

    return [pscustomobject]@{
        BackupPath = $bk
        RemovedOk  = $removedOk
        RemovedKo  = $removedKo
        Cancelled  = $cancelled
    }
}

Export-ModuleMember -Function Get-AppxPresent, Get-DecrapifierPlan, Backup-AppxState, Read-DecrapifierProfile, Restore-AppxFromBackup, Invoke-Decrapifier, Test-IsCriticalAppx
