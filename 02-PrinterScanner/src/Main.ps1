# Main.ps1 — 02-PrinterScanner
# Discovery stampanti via probe TCP. Read-only sulla rete.

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
Import-Module (Join-Path $ScriptDir "modules\PrinterDiscovery.psm1") -Force

$logPath  = Join-Path $ProjectDir "data\logs\printer-scanner.log"
$auditDir = Join-Path $ProjectDir "data\audit"
Initialize-AppLog   -Path $logPath
Initialize-AppAudit -AuditDir $auditDir -AppName "02-PrinterScanner"

$xamlPath  = Join-Path $ScriptDir "MainWindow.xaml"
$themePath = Join-Path $SharedDir "assets\Theme.xaml"

$ui = Import-XamlWindow -XamlPath $xamlPath -ThemePath $themePath
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito (file: $xamlPath)" }
$w  = $ui.Window
$c  = $ui.Controls

Set-ReadOnlyBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                   -Detail "probe TCP read-only, niente install driver, niente SNMP attivo"

# Auto-rilevamento subnet locale
$subnet = Get-LocalSubnet
$c.txtBaseIP.Text = $subnet.BaseIP
$c.txtStart.Text  = $subnet.Start
$c.txtEnd.Text    = $subnet.End
$c.lblStatus.Text = "Subnet rilevata: $($subnet.BaseIP).0/24 su $($subnet.InterfaceAlias)"
Write-AppLog -Level Info -Message "Subnet auto: $($subnet.BaseIP).$($subnet.Start)-$($subnet.End) iface=$($subnet.InterfaceAlias)"

$script:Results = New-Object System.Collections.ObjectModel.ObservableCollection[psobject]
$c.lvPrinters.ItemsSource = $script:Results
Set-EmptyState -Placeholder $c.lblEmptyPrinters -ListControl $c.lvPrinters -Count 0 `
               -Text "Premi 'Avvia scansione' per cercare stampanti di rete nella subnet indicata."

# Coda thread-safe per messaggi worker -> UI thread.
# NON usare Dispatcher.BeginInvoke con scriptblock PowerShell: PS re-marshalla
# l'esecuzione del scriptblock al runspace di origine (worker), generando cross-
# thread access exception su controlli WPF.
$script:ScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'

# Stato condiviso tra runspace worker e UI thread (synchronized hashtable).
$script:ScanState = [hashtable]::Synchronized(@{
    Cancel = $false
    Done   = $false
    PS     = $null
    RS     = $null
    Async  = $null
    Timer  = $null
    Stopwatch = $null
    BaseRange = ''
})

function Start-Scan {
    $base  = $c.txtBaseIP.Text.Trim()

    # TryParse PRIMA del cast: [int]'10a' lancia un'eccezione dentro Add_Click
    # (con $ErrorActionPreference='Stop') e la scansione moriva senza messaggio,
    # rendendo irraggiungibile la validazione di range più sotto.
    $start = 0; $end = 0
    if (-not [int]::TryParse($c.txtStart.Text.Trim(), [ref]$start) -or
        -not [int]::TryParse($c.txtEnd.Text.Trim(),   [ref]$end)) {
        Show-MessageBox -Message "Da / A devono essere numeri interi (esempio: 1 e 254)." -Title "Input non valido" -Icon Warning
        return
    }

    if ($base -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Show-MessageBox -Message "Subnet base non valida. Esempio: 192.168.1" -Title "Input non valido" -Icon Warning
        return
    }
    $octBad = @($base.Split('.') | Where-Object { [int]$_ -gt 255 })
    if ($octBad.Count -gt 0) {
        Show-MessageBox -Message "Ottetto fuori range (0-255). Esempio: 192.168.1" -Title "Input non valido" -Icon Warning
        return
    }
    if ($start -lt 1 -or $end -gt 254 -or $start -gt $end) {
        Show-MessageBox -Message "Range host non valido (1-254, start <= end)." -Title "Input non valido" -Icon Warning
        return
    }

    $script:ScanState.Cancel = $false
    $script:ScanState.Done   = $false
    $script:ScanState.BaseRange = "$base.$start-$end"
    $script:Results.Clear()
    # Svuota residui in queue (se Start-Scan è chiamato dopo Stop precedente)
    $junk = $null; while ($script:ScanQueue.TryDequeue([ref]$junk)) {}
    $c.btnScan.IsEnabled = $false
    $c.btnStop.IsEnabled = $true
    $c.prgScan.Value = 0
    $c.lblStatus.Text = "Avvio scansione..."

    Write-AppLog -Level Info -Message "Avvio scansione $base.$start-$end"
    Write-AuditEntry -Action 'scan.start' -Target "$base.$start-$end" -Result 'Info'

    $script:ScanState.Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Crea runspace separato per non bloccare la UI.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\PrinterDiscovery.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:ScanQueue)
    $rs.SessionStateProxy.SetVariable('State', $script:ScanState)
    $rs.SessionStateProxy.SetVariable('BaseIP', $base)
    $rs.SessionStateProxy.SetVariable('StartHost', $start)
    $rs.SessionStateProxy.SetVariable('EndHost', $end)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ModulePath -Force
        $progressCb = {
            param($cnt,$tot,$ip)
            $Queue.Enqueue([pscustomobject]@{ Type='Progress'; Count=$cnt; Total=$tot; IP=$ip })
        }
        $foundCb = {
            param($entry)
            $Queue.Enqueue([pscustomobject]@{ Type='Found'; Entry=$entry })
        }
        $cancelCb = { return $State.Cancel }
        try {
            Invoke-PrinterScan -BaseIP $BaseIP -Start $StartHost -End $EndHost -TimeoutMs 250 `
                -Progress $progressCb -ItemFound $foundCb -CancelCheck $cancelCb | Out-Null
        } finally {
            $State.Done = $true
        }
    })

    $script:ScanState.PS    = $ps
    $script:ScanState.RS    = $rs
    $script:ScanState.Async = $ps.BeginInvoke()

    # DispatcherTimer su UI thread: drena la coda di messaggi e controlla completion.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:ScanState.Timer = $timer
    $timer.Add_Tick({
        # 1. Drena messaggi dal worker (sempre sul UI thread, no cross-thread)
        $msg = $null
        while ($script:ScanQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Progress' {
                    $pct = if ($msg.Total -gt 0) { [math]::Round(($msg.Count/$msg.Total)*100) } else { 0 }
                    $c.prgScan.Value   = $pct
                    $c.lblStatus.Text  = "Analisi $($msg.IP) ($($msg.Count) / $($msg.Total))"
                    $c.lblCounter.Text = "Trovate: $($script:Results.Count)"
                }
                'Found' {
                    $script:Results.Add($msg.Entry) | Out-Null
                    $c.lblCounter.Text = "Trovate: $($script:Results.Count)"
                }
            }
        }

        # 2. Check completion
        $st = $script:ScanState
        if (-not $st.Async -or -not $st.Async.IsCompleted) { return }
        $st.Timer.Stop()
        try {
            $errs = @($st.PS.Streams.Error)
            $st.PS.EndInvoke($st.Async) | Out-Null
            foreach ($e in $errs) { Write-AppLog -Level Error -Message ([string]$e) }
        } catch {
            Write-AppLog -Level Error -Message ("Scan runspace: " + $_.Exception.Message)
        } finally {
            try { $st.PS.Dispose() } catch {}
            try { $st.RS.Close()   } catch {}
            $st.PS = $null; $st.RS = $null; $st.Async = $null
        }
        $st.Stopwatch.Stop()
        $secs = [math]::Round($st.Stopwatch.Elapsed.TotalSeconds, 1)
        $msg2 = if ($st.Cancel) {
            "Scansione interrotta. Trovate $($script:Results.Count) stampanti in ${secs}s."
        } else {
            "Scansione completata in ${secs}s. Trovate $($script:Results.Count) stampanti."
        }
        $c.lblStatus.Text = $msg2
        $c.prgScan.Value  = 100
        Set-EmptyState -Placeholder $c.lblEmptyPrinters -ListControl $c.lvPrinters -Count $script:Results.Count `
                       -Text "Nessuna stampante di rete trovata nell'intervallo $($st.BaseRange). Verifica la subnet indicata e che le stampanti siano accese e sulla stessa rete."
        $c.btnScan.IsEnabled = $true
        $c.btnStop.IsEnabled = $false
        Write-AppLog -Level Success -Message $msg2
        Write-AuditEntry -Action 'scan.complete' -Target $st.BaseRange `
            -Result $(if($st.Cancel){'Warning'}else{'Success'}) `
            -Reason "$($script:Results.Count) stampanti, ${secs}s"
    })
    $timer.Start()
}

$c.btnScan.Add_Click({ Start-Scan })

$c.btnStop.Add_Click({
    $script:ScanState.Cancel = $true
    $c.lblStatus.Text = "Interruzione richiesta (attesa fine porta corrente)..."
    Write-AppLog -Level Warning -Message "Scansione interrotta dall'utente"
    Write-AuditEntry -Action 'scan.cancel' -Result 'Warning' -Reason 'Interruzione utente'
})

$c.btnExport.Add_Click({
    if ($script:Results.Count -eq 0) {
        Show-MessageBox -Message "Esegui prima una scansione." -Title "Nessun dato" -Icon Information
        return
    }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $outDir "printers-$stamp.csv"
    # Il CSV elenca hostname e IP dei print server della rete del cliente:
    # ricognizione utile a malware già presente sul PC. Stessa policy di 03/04/10.
    $null = New-ProtectedFile -Path $outFile
    $script:Results | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-AppLog -Level Success -Message "Report CSV: $outFile"
    Write-AuditEntry -Action 'export.csv' -Target $outFile -Result 'Success' -Reason "$($script:Results.Count) record"
    Show-MessageBox -Message "Report salvato:`n$outFile" -Title "Esportato" -Icon Information
})

# Doppio click su una stampante: apre interfaccia web admin (read-only)
$c.lvPrinters.Add_MouseDoubleClick({
    $sel = $c.lvPrinters.SelectedItem
    if (-not $sel) { return }
    $ports = $sel.Ports
    $proto = if ($ports -match 'HTTPS') { 'https' } else { 'http' }
    $url = "${proto}://$($sel.IP)/"
    Start-Process $url
    Write-AppLog -Level Info -Message "Aperto admin web: $url"
    Write-AuditEntry -Action 'admin.open' -Target $url -Result 'Info'
})

$w.Add_Closing({
    # Termina runspace scan se attivo (evita worker orfani in background)
    $script:ScanState.Cancel = $true
    if ($script:ScanState.Timer) { try { $script:ScanState.Timer.Stop() } catch {} }
    if ($script:ScanState.PS)    { try { $script:ScanState.PS.Stop() } catch {}; try { $script:ScanState.PS.Dispose() } catch {} }
    if ($script:ScanState.RS)    { try { $script:ScanState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 02-PrinterScanner", 'OK', 'Error') | Out-Null
}
