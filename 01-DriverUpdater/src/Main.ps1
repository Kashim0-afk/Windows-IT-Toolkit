# Main.ps1 — 01-DriverUpdater
# Tool diagnostico read-only. Nessuna modifica al sistema.

$ErrorActionPreference = 'Stop'

try {

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$RootDir    = Split-Path -Parent $ProjectDir
$SharedDir  = Join-Path $RootDir "_shared"

Import-Module (Join-Path $SharedDir "modules\Logging.psm1") -Force
Import-Module (Join-Path $SharedDir "modules\GUI.psm1")     -Force
Import-Module (Join-Path $SharedDir "modules\Common.psm1")  -Force
Import-Module (Join-Path $SharedDir "modules\Audit.psm1")   -Force
Import-Module (Join-Path $ScriptDir "modules\DriverDiscovery.psm1") -Force

$logPath   = Join-Path $ProjectDir "data\logs\driver-updater.log"
$auditDir  = Join-Path $ProjectDir "data\audit"
Initialize-AppLog   -Path $logPath
Initialize-AppAudit -AuditDir $auditDir -AppName "01-DriverUpdater"

$xamlPath  = Join-Path $ScriptDir "MainWindow.xaml"
$themePath = Join-Path $SharedDir "assets\Theme.xaml"

$ui = Import-XamlWindow -XamlPath $xamlPath -ThemePath $themePath
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito (file: $xamlPath)" }
$w  = $ui.Window
$c  = $ui.Controls

$oem = Get-OEMVendor
$c.lblSubtitle.Text = "Trova driver mancanti o guasti e apre i canali ufficiali per aggiornarli. Non installa nulla da solo. | " +
                      "PC: $env:COMPUTERNAME | Vendor: $($oem.Vendor) | Modello: $($oem.Model)"
Set-ReadOnlyBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                   -Detail "scansione PnP, nessuna installazione driver"
Write-AppLog -Level Info -Message "Avvio Driver Updater su $env:COMPUTERNAME ($($oem.Vendor) $($oem.Model))"

function Invoke-Scan {
    $c.btnScan.IsEnabled = $false
    $c.lblStatus.Text   = "Scansione dispositivi in corso..."
    $c.lblCounter.Text  = ""
    $includeAll = [bool]$c.chkPnpAll.IsChecked
    Write-AuditEntry -Action 'scan.start' -Target 'PnP devices' -Result 'Info' -Reason ("IncludeAll=$includeAll")
    try {
        $devices = if ($includeAll) { Get-ProblemDevices -IncludeAll } else { Get-ProblemDevices }
        $c.lvDevices.ItemsSource = $devices
        Set-EmptyState -Placeholder $c.lblEmptyDevices -ListControl $c.lvDevices -Count @($devices).Count `
                       -Text "Nessun dispositivo con driver mancante o non funzionante. Tutti i device presenti risultano a posto."
        $tabs = $c.tabs
        if ($tabs) { $tabs.SelectedIndex = 0 }
        $modeLabel = if ($includeAll) { 'modalità debug: tutti gli anomali' } else { 'solo driver mancanti o rotti' }
        $msg = "Trovati $($devices.Count) dispositivi ($modeLabel)."
        $c.lblStatus.Text  = $msg
        $c.lblCounter.Text = "Device problematici: $($devices.Count)"
        Write-AppLog -Level Success -Message "Scansione completata: $($devices.Count) device ($modeLabel)"
        Write-AuditEntry -Action 'scan.complete' -Target 'PnP devices' -Result 'Success' -Reason $msg
    } catch {
        $err = $_.Exception.Message
        $c.lblStatus.Text = "Errore scansione: $err"
        Show-MessageBox -Message "Errore durante scansione:`n$err" -Title "Errore" -Icon Error
        Write-AppLog -Level Error -Message $err
        Write-AuditEntry -Action 'scan.error' -Target 'PnP devices' -Result 'Failure' -Reason $err
    } finally {
        $c.btnScan.IsEnabled = $true
    }
}

# Stato runspace per winget upgrade (operazione lenta 5-30s, non deve bloccare UI).
# Synchronized hashtable è usata solo per scambio dati non-WPF (lista risultati,
# flag completion). I controlli UI sono toccati SOLO dal Tick timer (UI thread).
$script:WingetState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Result = $null; ExitCode = $null
})

function Invoke-WingetScan {
    if (-not (Test-WingetAvailable)) {
        Show-MessageBox -Message "winget non è disponibile su questo PC.`n`nInstalla 'App Installer' dal Microsoft Store oppure aggiorna Windows." -Title "winget mancante" -Icon Warning
        return
    }

    $c.btnWinget.IsEnabled = $false
    $c.btnScan.IsEnabled   = $false
    # Azzera il risultato precedente: se questa esecuzione fallisce senza
    # sovrascriverlo, la UI mostrerebbe la lista della ricerca precedente
    # spacciandola per aggiornata.
    $script:WingetState.Result = $null
    $includeUnknown = [bool]$c.chkIncludeUnknown.IsChecked
    $c.lblStatus.Text = "Cerco aggiornamenti con winget (può richiedere 10-30s)..."
    Write-AuditEntry -Action 'winget.start' -Target 'winget upgrade' -Result 'Info' -Reason ("IncludeUnknown=$includeUnknown")

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\DriverDiscovery.psm1'))
    $rs.SessionStateProxy.SetVariable('State', $script:WingetState)
    $rs.SessionStateProxy.SetVariable('IncludeUnknown', $includeUnknown)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ModulePath -Force
        if ($IncludeUnknown) {
            $State.Result = @(Get-WingetUpgrades -IncludeUnknown)
        } else {
            $State.Result = @(Get-WingetUpgrades)
        }
        # Esito di winget riportato al thread UI: una lista vuota può voler dire
        # "tutto aggiornato" oppure "winget ha fallito", e per il tecnico sono
        # due situazioni opposte.
        $State.ExitCode = Get-LastWingetExitCode
    })
    $script:WingetState.PS = $ps
    $script:WingetState.RS = $rs
    $script:WingetState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:WingetState.Timer = $timer
    $timer.Add_Tick({
        $st = $script:WingetState
        if (-not $st.Async.IsCompleted) { return }
        $st.Timer.Stop()
        try {
            $errs = @($st.PS.Streams.Error)
            $st.PS.EndInvoke($st.Async) | Out-Null
            foreach ($e in $errs) { Write-AppLog -Level Error -Message ([string]$e) }
        } catch {
            Write-AppLog -Level Error -Message ("winget runspace: " + $_.Exception.Message)
        } finally {
            try { $st.PS.Dispose() } catch {}
            try { $st.RS.Close()   } catch {}
            $st.PS=$null; $st.RS=$null; $st.Async=$null
        }
        $list = @($st.Result)
        $wgFailed = ($st.ExitCode -ne $null -and [int]$st.ExitCode -ne 0)
        $c.lvUpgrades.ItemsSource = $list
        $emptyTxt = if ($wgFailed) {
            "winget ha restituito un errore (codice $($st.ExitCode)) e non ha prodotto risultati. " +
            "L'elenco NON significa che il software sia aggiornato: verifica che 'App Installer' sia installato e aggiornato dal Microsoft Store."
        } else {
            "Nessun aggiornamento disponibile secondo winget. Il software installato è aggiornato."
        }
        Set-EmptyState -Placeholder $c.lblEmptyUpgrades -ListControl $c.lvUpgrades -Count @($list).Count -Text $emptyTxt
        if ($c.tabs) { $c.tabs.SelectedIndex = 1 }
        $msg = if ($wgFailed) {
            "winget ha restituito il codice di errore $($st.ExitCode): risultato non attendibile."
        } else {
            "winget: $($list.Count) aggiornamenti disponibili."
        }
        $c.lblStatus.Text  = $msg
        $c.lblCounter.Text = "Aggiornamenti: $($list.Count)"
        Write-AppLog -Level $(if ($wgFailed) { 'Warning' } else { 'Success' }) -Message $msg
        Write-AuditEntry -Action 'winget.complete' -Target 'winget upgrade' -Result 'Success' -Reason "$($list.Count) upgrades"
        $c.btnWinget.IsEnabled = $true
        $c.btnScan.IsEnabled   = $true
    })
    $timer.Start()
}

$c.btnScan.Add_Click({ Invoke-Scan })
$c.btnWinget.Add_Click({ Invoke-WingetScan })

# Aggiorna TUTTO con winget: apre una nuova finestra terminale (elevata se serve)
# e lancia "winget upgrade --all --include-unknown". L'utente vede output live
# e può interrompere con Ctrl+C. NON eseguito silenziosamente.
$c.btnWingetAll.Add_Click({
    if (-not (Test-WingetAvailable)) {
        Show-MessageBox -Message "winget non disponibile su questo PC." -Icon Warning
        return
    }
    $count = if ($c.lvUpgrades.ItemsSource) { @($c.lvUpgrades.ItemsSource).Count } else { 0 }
    $preamble = if ($count -gt 0) { "Saranno aggiornati i $count pacchetti elencati nella tab 'Aggiornamenti disponibili'." } else { "winget cerchera' e installera' tutti gli aggiornamenti disponibili (puoi premere prima 'Cerca aggiornamenti' per vedere la lista)." }
    $msg = "$preamble`n`n" +
           "Verrà aperta una finestra TERMINALE in modalita' AMMINISTRATORE che esegue:`n`n" +
           "    winget upgrade --all --include-unknown --silent`n`n" +
           "Procedere?`n`n" +
           "Suggerimento: se vuoi più controllo, usa la lista 'Aggiornamenti disponibili'`n" +
           "e fai doppio click su una singola riga per copiare il comando."
    $r = Show-MessageBox -Message $msg -Title "Conferma 'winget upgrade --all'" -Buttons YesNo -Icon Warning
    if ($r -ne 'Yes') { return }
    try {
        Write-AuditEntry -Action 'winget.all.start' -Target 'winget upgrade --all' -Result 'Info' -Reason "elevation requested"
        # Apre cmd elevato che esegue winget e poi attende input prima di chiudere
        $cmdLine = '/k echo Aggiornamento winget in corso... & echo. & winget upgrade --all --include-unknown --silent & echo. & echo === Completato. Premi un tasto per chiudere. === & pause >nul'
        Start-Process cmd.exe -ArgumentList $cmdLine -Verb RunAs
        $c.lblStatus.Text = "Aggiornamento winget --all avviato in finestra separata (terminale admin)."
        Write-AppLog -Level Info -Message "Avviato winget upgrade --all (terminale esterno admin)"
    } catch {
        $err = $_.Exception.Message
        if ($err -match 'L.operazione e. stata annullata|operation was canceled') {
            $c.lblStatus.Text = "Elevazione UAC annullata dall'utente."
            Write-AuditEntry -Action 'winget.all.cancelled' -Result 'Warning' -Reason 'UAC declined'
        } else {
            Show-MessageBox -Message "Errore avvio winget: $err" -Icon Error
            Write-AuditEntry -Action 'winget.all.error' -Result 'Failure' -Reason $err
        }
    }
})

# Doppio click su un upgrade: copia "winget upgrade <Id>" negli appunti
$c.lvUpgrades.Add_MouseDoubleClick({
    $sel = $c.lvUpgrades.SelectedItem
    if (-not $sel -or -not $sel.Id) { return }
    $cmd = "winget upgrade --id $($sel.Id)"
    try {
        [System.Windows.Clipboard]::SetText($cmd)
        $c.lblStatus.Text = "Comando copiato: $cmd"
        Write-AuditEntry -Action 'winget.clipboard' -Target $sel.Id -Result 'Info' -Reason $cmd
    } catch {
        $c.lblStatus.Text = "Copia clipboard fallita: $($_.Exception.Message)"
    }
})

$c.btnExport.Add_Click({
    $items = @($c.lvDevices.ItemsSource)
    if ($items.Count -eq 0) {
        Show-MessageBox -Message "Esegui prima una scansione." -Title "Nessun dato" -Icon Information
        return
    }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $outDir "driver-report-$stamp.csv"
    # Stessa policy di 03/04/10: l'inventario hardware e i device ID sono meno
    # sensibili di una chiave BitLocker, ma non c'è ragione per cui la stessa
    # suite applichi tre livelli di protezione diversi ai propri report.
    $null = New-ProtectedFile -Path $outFile
    $items | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-AppLog -Level Success -Message "Report CSV: $outFile"
    Write-AuditEntry -Action 'export.csv' -Target $outFile -Result 'Success' -Reason "$($items.Count) record"
    Show-MessageBox -Message "Report salvato:`n$outFile" -Title "Esportato" -Icon Information
})

$c.btnOEM.Add_Click({
    $url = Get-OEMUpdateToolUrl -Vendor $oem.Vendor
    if ($url) {
        Start-Process $url
        Write-AppLog -Level Info -Message "Aperto OEM tool URL ($($oem.Vendor)): $url"
        Write-AuditEntry -Action 'oem.open' -Target $url -Result 'Info' -Reason $oem.Vendor
    } else {
        Show-MessageBox -Message "Vendor '$($oem.Vendor)' non in elenco. Cerca manualmente il tool OEM ufficiale." -Title "Vendor sconosciuto" -Icon Warning
        Write-AppLog -Level Warning -Message "OEM vendor sconosciuto: $($oem.Vendor)"
    }
})

$c.btnWU.Add_Click({
    Start-Process "ms-settings:windowsupdate"
    Write-AppLog -Level Info -Message "Aperto Windows Update Settings"
    Write-AuditEntry -Action 'wu.open' -Target 'Windows Update' -Result 'Info'
})

$c.btnDevMgr.Add_Click({
    Start-Process "devmgmt.msc"
    Write-AppLog -Level Info -Message "Aperto Device Manager"
    Write-AuditEntry -Action 'devmgr.open' -Target 'Device Manager' -Result 'Info'
})

# Doppio click sul device: copia Hardware ID negli appunti (utile per cercare driver online)
# e apre Device Manager.
$c.lvDevices.Add_MouseDoubleClick({
    $sel = $c.lvDevices.SelectedItem
    if (-not $sel) { return }
    if ($sel.HardwareID) {
        try {
            [System.Windows.Clipboard]::SetText([string]$sel.HardwareID)
            $c.lblStatus.Text = "Hardware ID copiato negli appunti: $($sel.HardwareID)"
            Write-AuditEntry -Action 'hwid.clipboard' -Target $sel.HardwareID -Result 'Info'
        } catch {
            $c.lblStatus.Text = "Copia HWID fallita: $($_.Exception.Message)"
            Write-AppLog -Level Warning -Message "Clipboard SetText fallito: $($_.Exception.Message)"
        }
    }
    Start-Process "devmgmt.msc"
})

$w.Add_Loaded({ Invoke-Scan })

$w.Add_Closing({
    if ($script:WingetState.Timer) { try { $script:WingetState.Timer.Stop() } catch {} }
    if ($script:WingetState.PS)    { try { $script:WingetState.PS.Stop() } catch {}; try { $script:WingetState.PS.Dispose() } catch {} }
    if ($script:WingetState.RS)    { try { $script:WingetState.RS.Close() } catch {} }
    Close-AppAudit
    Write-AppLog -Level Info -Message "Chiusura applicazione"
})

[void]$w.ShowDialog()

} catch {
    $errMsg = "Errore fatale all'avvio:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)"
    try {
        $errDir = Join-Path (Split-Path -Parent $PSScriptRoot) "data\logs"
        if (-not (Test-Path $errDir)) { New-Item -ItemType Directory -Path $errDir -Force | Out-Null }
        $errLog = Join-Path $errDir "fatal-error.log"
        Add-Content -Path $errLog -Value "[$(Get-Date -Format o)] $errMsg`n$($_.ScriptStackTrace)`n---" -Encoding UTF8
    } catch { }
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 01-DriverUpdater", 'OK', 'Error') | Out-Null
}
