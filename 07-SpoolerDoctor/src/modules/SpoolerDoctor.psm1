# SpoolerDoctor.psm1 — diagnosi e fix problemi spooler di stampa

# Common.psm1 va importato QUI, non solo in Main.ps1: Repair-Spooler chiama
# Test-IsAdmin ma gira dentro un runspace isolato, dove i moduli caricati dal
# thread UI non sono visibili e _shared non è in PSModulePath (niente autoload).
# Senza questo import Repair-Spooler falliva sempre con CommandNotFoundException.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_shared\modules\Common.psm1') -DisableNameChecking

function Get-SpoolerStatus {
    [CmdletBinding()] param()
    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if (-not $svc) { return [pscustomobject]@{ Status='Servizio non trovato'; StartType='?' } }
    return [pscustomobject]@{
        Status    = $svc.Status
        StartType = $svc.StartType
    }
}

function Get-SpoolerInventory {
    # -Log: callback verso la UI. Write-AppLog NON è risolvibile qui, perché
    # questa funzione gira in un runspace che importa solo SpoolerDoctor.psm1:
    # la guardia `if (Get-Command Write-AppLog)` era sempre falsa e un
    # Get-PrintJob fallito (tipico con stampanti di rete offline) spariva
    # senza lasciare traccia.
    [CmdletBinding()] param([scriptblock]$Log = $null)
    $printers   = @(Get-Printer       -ErrorAction SilentlyContinue | Select-Object Name, DriverName, PortName, Type, Shared, Published, PrinterStatus)
    $drivers    = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object Name, Manufacturer, DriverVersion, ConfigFile)
    $ports      = @(Get-PrinterPort   -ErrorAction SilentlyContinue | Select-Object Name, Description, PortMonitor)
    $jobs       = @()
    foreach ($p in $printers) {
        try {
            $jobs += @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue |
                Select-Object @{n='Printer';e={$p.Name}}, Id, DocumentName, UserName, JobStatus, Size, SubmittedTime)
        } catch {
            if ($Log) { & $Log 'Warning' ("Coda non leggibile per '{0}': {1}" -f $p.Name, $_.Exception.Message) }
        }
    }

    # Driver orfani: driver installati ma non usati da nessuna stampante.
    # IMPORTANTE: forzare array vuoto se nessuna stampante, altrimenti
    # "$_.Name -notin $null" ritorna sempre TRUE -> tutti i driver risulterebbero orfani!
    $usedDriverNames = @()
    if ($printers.Count -gt 0) {
        $usedDriverNames = @($printers | ForEach-Object { $_.DriverName } | Where-Object { $_ } | Sort-Object -Unique)
    }
    $orphanDrivers = @()
    $removableOrphanDrivers = @()
    if ($usedDriverNames.Count -gt 0) {
        $orphanDrivers = @($drivers | Where-Object { $_.Name -notin $usedDriverNames })
        # Sottoinsieme REALMENTE rimovibile (blacklist driver di sistema esclusa):
        # è quello che Repair-Spooler cancellera'. Va calcolato qui, nel worker,
        # così la finestra di conferma può mostrarlo senza ricalcolarlo sul
        # thread UI (e senza mentire elencando driver che non tocchera').
        $removableOrphanDrivers = @($orphanDrivers | Where-Object { $_.Name -notin $script:DriverBlacklist })
    }
    # Se nessuna stampante è installata, NESSUN driver è "orfano" (potrebbero essere driver di sistema o riservati)

    return [pscustomobject]@{
        Printers       = $printers
        Drivers        = $drivers
        Ports          = $ports
        Jobs           = $jobs
        OrphanDrivers  = $orphanDrivers
        RemovableOrphanDrivers = $removableOrphanDrivers
        SpoolDir       = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
        SpoolDirItems  = if (Test-Path (Join-Path $env:SystemRoot 'System32\spool\PRINTERS')) {
                            @(Get-ChildItem (Join-Path $env:SystemRoot 'System32\spool\PRINTERS') -Force -ErrorAction SilentlyContinue).Count
                         } else { 0 }
    }
}

function Backup-SpoolerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    # printers.xml e ports.xml contengono nomi dei print server, share UNC e IP
    # delle porte TCP/IP: mappa della rete del cliente, scritta da un processo
    # admin. 09 proteggeva già la propria cartella di backup, qui mancava.
    $null = Protect-FileOwnerOnly -Path $BackupDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path $BackupDir "spooler-state-$stamp"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Get-Printer       -ErrorAction SilentlyContinue | Export-Clixml -Path (Join-Path $dest 'printers.xml')
    Get-PrinterDriver -ErrorAction SilentlyContinue | Export-Clixml -Path (Join-Path $dest 'drivers.xml')
    Get-PrinterPort   -ErrorAction SilentlyContinue | Export-Clixml -Path (Join-Path $dest 'ports.xml')

    return $dest
}

# Blacklist driver "di sistema": non rimuovibili anche se appaiono come orfani.
# Questi vengono mantenuti da Windows anche senza stampante associata e la loro
# rimozione può rompere print-to-PDF, fax, scan-to-file ecc.
$script:DriverBlacklist = @(
    'Microsoft Print To PDF',
    'Microsoft XPS Document Writer',
    'Microsoft XPS Document Writer v4',
    'Microsoft Shared Fax Driver',
    'Microsoft enhanced Point and Print compatibility driver',
    'OneNote',
    'OneNote (Desktop)',
    'OneNote for Windows 10',
    'Send To OneNote 2010',
    'Send To OneNote 2013',
    'Send To OneNote 2016',
    'Fax',
    'Generic / Text Only',
    'Remote Desktop Easy Print'
)

function Get-RemovableOrphanDrivers {
    [CmdletBinding()] param()
    $printers = @(Get-Printer -ErrorAction SilentlyContinue)
    $drivers  = @(Get-PrinterDriver -ErrorAction SilentlyContinue)
    $used = @()
    if ($printers.Count -gt 0) {
        $used = @($printers | ForEach-Object { $_.DriverName } | Where-Object { $_ } | Sort-Object -Unique)
    }
    if ($used.Count -eq 0) { return @() }
    return @($drivers | Where-Object { $_.Name -notin $used -and $_.Name -notin $script:DriverBlacklist })
}

function Repair-Spooler {
    [CmdletBinding()]
    param(
        [bool]$ClearQueue       = $true,
        [bool]$RemoveOrphanDrv  = $false,
        # Lista ESATTA dei driver mostrati all'utente nella finestra di conferma.
        # Senza, Repair-Spooler ricalcolava sul momento: fra la diagnosi e la
        # riparazione può passare tempo, e un driver diventato orfano nel
        # frattempo (stampante rimossa) veniva cancellato SENZA essere mai
        # comparso nella conferma. Consenso informato su dati non attuali.
        [string[]]$ApprovedOrphanNames = $null,
        [Parameter(Mandatory)][string]$BackupDir,
        [scriptblock]$Log = $null,
        [scriptblock]$CancelCheck = $null
    )
    if (-not (Test-IsAdmin)) {
        throw "Operazione richiede privilegi amministratore. Lancia 'Esegui come amministratore'."
    }

    function _log($lvl, $msg) { if ($Log) { & $Log $lvl $msg } }

    # 1. Backup
    _log 'Info' 'Backup stato spooler...'
    $backupPath = Backup-SpoolerState -BackupDir $BackupDir
    _log 'Success' "Backup: $backupPath"

    $spoolerStopped = $false
    try {
        # 2. Stop service
        _log 'Info' 'Stop servizio Spooler...'
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 1
        $spoolerStopped = $true
        _log 'Success' 'Spooler stoppato'

        # 3. Svuota PRINTERS
        if ($ClearQueue) {
            $spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            if (Test-Path $spoolDir) {
                $items = @(Get-ChildItem $spoolDir -Force -ErrorAction SilentlyContinue)
                foreach ($it in $items) {
                    try { Remove-Item $it.FullName -Force -ErrorAction Stop }
                    catch { _log 'Warning' "Non rimosso: $($it.Name) ($($_.Exception.Message))" }
                }
                _log 'Success' "PRINTERS svuotato: $($items.Count) file rimossi"
            }
        }

        # 4. Driver orfani (opt-in). Filtra blacklist driver di sistema.
        if ($RemoveOrphanDrv) {
            # Si rimuove solo l'INTERSEZIONE fra ciò che è orfano ADESSO e ciò
            # che l'utente ha visto e approvato: né più (driver diventati orfani
            # dopo la conferma) né meno (driver che nel frattempo sono tornati in
            # uso non vanno toccati).
            $orphans = @(Get-RemovableOrphanDrivers)
            if ($null -ne $ApprovedOrphanNames) {
                $before = $orphans.Count
                $orphans = @($orphans | Where-Object { $ApprovedOrphanNames -contains $_.Name })
                $diff = $before - $orphans.Count
                if ($diff -gt 0) {
                    _log 'Info' "$diff driver diventati orfani dopo la conferma NON verranno rimossi: rilancia la diagnosi per includerli."
                }
            }
            if ($orphans.Count -eq 0) {
                _log 'Info' 'Nessun driver orfano rimovibile (esclusi driver di sistema in blacklist).'
            }
            foreach ($od in $orphans) {
                # Annullamento consentito SOLO qui, fra la rimozione di un driver
                # e la successiva. Le fasi stop/svuota-coda/restart NON sono
                # interrompibili di proposito: fermarsi a spooler fermo
                # lascerebbe il sistema di stampa inutilizzabile.
                if ($CancelCheck -and (& $CancelCheck)) {
                    _log 'Warning' "Rimozione driver interrotta dall'utente. Lo spooler verra' comunque riavviato."
                    break
                }
                try {
                    Remove-PrinterDriver -Name $od.Name -ErrorAction Stop
                    _log 'Success' "Rimosso driver orfano: $($od.Name)"
                } catch {
                    _log 'Warning' "Non rimosso driver $($od.Name): $($_.Exception.Message)"
                }
            }
        }
    } finally {
        # 5. Restart service - SEMPRE eseguito anche se step precedenti hanno fallito,
        # così il PC non resta senza spooler.
        if ($spoolerStopped) {
            _log 'Info' 'Riavvio Spooler...'
            try {
                Start-Service -Name Spooler -ErrorAction Stop
                Start-Sleep -Seconds 1
                $svc = Get-Service Spooler
                if ($svc.Status -ne 'Running') {
                    _log 'Error' "Spooler non riparte: $($svc.Status). Avvio manuale: services.msc -> Print Spooler -> Avvia."
                } else {
                    _log 'Success' 'Spooler in esecuzione'
                }
            } catch {
                _log 'Error' "Restart Spooler fallito: $($_.Exception.Message). Avvio manuale: services.msc -> Print Spooler -> Avvia."
            }
        }
    }

    return [pscustomobject]@{
        BackupPath = $backupPath
        Success    = $true
    }
}

Export-ModuleMember -Function Get-SpoolerStatus, Get-SpoolerInventory, Backup-SpoolerState, Repair-Spooler, Get-RemovableOrphanDrivers
