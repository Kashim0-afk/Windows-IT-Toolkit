# Main.ps1 — 10-GDPRScanner
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
Import-Module (Join-Path $ScriptDir "modules\Validators.psm1")  -Force
Import-Module (Join-Path $ScriptDir "modules\FileParsers.psm1") -Force
Import-Module (Join-Path $ScriptDir "modules\GdprScan.psm1")    -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\gdpr-scanner.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "10-GDPRScanner"

$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

Set-ReadOnlyBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                   -Detail "scan filesystem read-only, nessuna modifica ai file. Output con esempi mascherati"

$c.txtPath.Text = [Environment]::GetFolderPath('MyDocuments')

$script:LastScanPath = $null
$script:Results = New-Object System.Collections.ObjectModel.ObservableCollection[psobject]
$c.lvHits.ItemsSource = $script:Results
Set-EmptyState -Placeholder $c.lblEmptyHits -ListControl $c.lvHits -Count 0 `
               -Text "Premi 'Avvia scansione' per analizzare la cartella scelta."

# Runspace: Invoke-FolderScan ricorre su filesystem grandi (50k+ file) e fa
# parsing di DOCX/XLSX (zip+xml). Tempi: 60-300s. Senza runspace freeze totale.
$script:ScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:ScanState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Cancel = $false; Stopwatch = $null
})

function Get-SelectedTypes {
    $t = @()
    if ($c.chkCF.IsChecked)    { $t += 'CF' }
    if ($c.chkPIVA.IsChecked)  { $t += 'PIVA' }
    if ($c.chkIBAN.IsChecked)  { $t += 'IBAN' }
    if ($c.chkCARTA.IsChecked) { $t += 'CARTA' }
    if ($c.chkEMAIL.IsChecked) { $t += 'EMAIL' }
    return $t
}

$c.btnBrowse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $c.txtPath.Text
    if ($dlg.ShowDialog() -eq 'OK') { $c.txtPath.Text = $dlg.SelectedPath }
})

$c.btnScan.Add_Click({
    if ($script:ScanState.PS) { return }
    $path = $c.txtPath.Text.Trim()
    if (-not (Test-Path $path)) { Show-MessageBox -Message "Cartella non esiste: $path" -Icon Warning; return }
    $types = Get-SelectedTypes
    if ($types.Count -eq 0) { Show-MessageBox -Message "Seleziona almeno un tipo." -Icon Warning; return }

    $script:ScanState.Cancel = $false
    $script:LastScanPath = $path
    $script:Results.Clear()
    $c.btnScan.IsEnabled = $false
    $c.btnStop.IsEnabled = $true
    $c.prgScan.Value = 0
    Write-AuditEntry -Action 'scan.start' -Target $path -Result 'Info' -Reason ($types -join ',')

    $script:ScanState.Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $junk = $null; while ($script:ScanQueue.TryDequeue([ref]$junk)) {}

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ValidatorsPath',  (Join-Path $ScriptDir 'modules\Validators.psm1'))
    $rs.SessionStateProxy.SetVariable('FileParsersPath', (Join-Path $ScriptDir 'modules\FileParsers.psm1'))
    $rs.SessionStateProxy.SetVariable('GdprScanPath',    (Join-Path $ScriptDir 'modules\GdprScan.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:ScanQueue)
    $rs.SessionStateProxy.SetVariable('State', $script:ScanState)
    $rs.SessionStateProxy.SetVariable('ScanPath', $path)
    $rs.SessionStateProxy.SetVariable('Types', $types)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ValidatorsPath  -Force
        Import-Module $FileParsersPath -Force
        Import-Module $GdprScanPath    -Force
        $progressCb = { param($cnt,$tot,$file) $Queue.Enqueue([pscustomobject]@{ Type='Progress'; Count=$cnt; Total=$tot; File=$file }) }
        $foundCb    = { param($entry) $Queue.Enqueue([pscustomobject]@{ Type='Found'; Entry=$entry }) }
        $cancelCb   = { return $State.Cancel }
        # Log e statistiche viaggiano per callback/hashtable: nel runspace
        # Write-AppLog non esiste, quindi i messaggi sugli scarti erano finora
        # codice morto e la UI dichiarava all'utente un log che non veniva scritto.
        $logCb = { param($lvl,$msg) $Queue.Enqueue([pscustomobject]@{ Type='Log'; Level=$lvl; Message=$msg }) }
        $stats = @{}
        try {
            $null = Invoke-FolderScan -Path $ScanPath -Types $Types -Progress $progressCb -ItemFound $foundCb `
                                      -CancelCheck $cancelCb -Log $logCb -Stats $stats
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; Stats=$stats })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })
    $script:ScanState.PS    = $ps
    $script:ScanState.RS    = $rs
    $script:ScanState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:ScanState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null
        $redrained = $false
        while ($script:ScanQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Progress' {
                    if ($msg.Total -gt 0) {
                        # Fase di analisi: percentuale reale.
                        $c.prgScan.IsIndeterminate = $false
                        $c.prgScan.Value = [math]::Round(($msg.Count / $msg.Total) * 100)
                        $c.lblStatus.Text = "Analisi $($msg.Count) / $($msg.Total) - $([IO.Path]::GetFileName($msg.File))"
                    } else {
                        # Fase di enumerazione: il totale non è ancora noto, quindi
                        # barra indeterminata invece di una barra ferma a 0 che
                        # sembra un blocco.
                        $c.prgScan.IsIndeterminate = $true
                        $c.lblStatus.Text = [string]$msg.File
                    }
                    $c.lblCounter.Text = "Hit: $($script:Results.Count)"
                }
                'Found' { $script:Results.Add($msg.Entry) | Out-Null }
                'Log'   { Write-AppLog -Level $msg.Level -Message $msg.Message }
                'Done'  { $done = $true; $script:LastStats = $msg.Stats }
                'Error' { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        if (-not $done) {
            if ($script:ScanState.Async -and $script:ScanState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:ScanQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }
        $st = $script:ScanState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null
        $st.Stopwatch.Stop()
        $secs = [math]::Round($st.Stopwatch.Elapsed.TotalSeconds, 1)

        # Reset della barra PRIMA di distinguere esito: sul ramo di errore
        # restava indeterminata e continuava ad animarsi sotto il messaggio.
        $c.prgScan.IsIndeterminate = $false
        if ($errMsg) {
            $c.lblStatus.Text = "Errore: $errMsg"
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'scan.error' -Result 'Failure' -Reason $errMsg
            Show-MessageBox -Message "Errore: $errMsg" -Icon Error
        } else {
            # I "non verificati" devono stare nella BARRA DI STATO, non solo nel
            # log: in uno strumento di compliance "nessun risultato" senza il
            # numero di file non analizzati è una mezza verità.
            $stats = $script:LastStats
            $nv = if ($stats) { [int]$stats['NotVerified'] } else { 0 }
            $nvText = if ($nv -gt 0) { "  |  NON verificati: $nv (vedi log)" } else { '' }
            $msg2 = if ($st.Cancel) {
                "Scan interrotto in ${secs}s. File con dati personali: $($script:Results.Count).$nvText"
            } else {
                "Scan completato in ${secs}s. Analizzati: $(if ($stats) { $stats['Analyzed'] } else { '?' }) | File con dati personali: $($script:Results.Count).$nvText"
            }
            $c.lblStatus.Text = $msg2
            $c.prgScan.IsIndeterminate = $false
            $c.prgScan.Value = 100
            $emptyText = "Nessun dato personale trovato nei file analizzati."
            if ($nv -gt 0) {
                $emptyText += "`n`nATTENZIONE: $nv elementi NON sono stati verificati " +
                              "($($stats['Unreadable']) protetti da password o danneggiati, " +
                              "$($stats['TooBig']) oltre il limite di dimensione, " +
                              "$($stats['DirSkipped']) cartelle inaccessibili, " +
                              "$($stats['Skipped']) errori di lettura). " +
                              "L'esito NON copre quei file: il dettaglio è nel log del tool."
            } else {
                $emptyText += " Vengono esaminati solo i formati supportati."
            }
            Set-EmptyState -Placeholder $c.lblEmptyHits -ListControl $c.lvHits -Count $script:Results.Count -Text $emptyText
            Write-AppLog -Level Success -Message $msg2
            Write-AuditEntry -Action 'scan.complete' -Target $script:LastScanPath `
                -Result $(if($st.Cancel){'Warning'}else{'Success'}) `
                -Reason "$($script:Results.Count) file con hit, ${secs}s"
        }
        $c.btnScan.IsEnabled = $true
        $c.btnStop.IsEnabled = $false
    })
    $timer.Start()
})

$c.btnStop.Add_Click({
    $script:ScanState.Cancel = $true
    $c.lblStatus.Text = "Interruzione (attesa fine file corrente)..."
    Write-AuditEntry -Action 'scan.cancel' -Result 'Warning'
})

$c.btnExportCsv.Add_Click({
    if ($script:Results.Count -eq 0) { Show-MessageBox -Message "Nessun risultato." -Icon Information; return }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $outDir "gdpr-$stamp.csv"
    # Il report elenca il percorso esatto di ogni file contenente dati personali:
    # per un altro utente del PC è una mappa di cosa esfiltrare, più utile dei
    # dati stessi. Va protetto almeno quanto i report di 03 e 04.
    $protected = New-ProtectedFile -Path $out
    $script:Results | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-AuditEntry -Action 'export.csv' -Target $out -Result 'Success'
    if (-not $protected) {
        Write-AppLog -Level Error -Message "ACL non applicata su $out"
        Show-MessageBox -Icon Warning -Title "Permessi non ristretti" -Message (
            "Report salvato ma senza permessi ristretti:`n$out`n`n" +
            "Elenca i file che contengono dati personali ed è leggibile da altri utenti del PC.")
    } else {
        Show-MessageBox -Message "Salvato: $out"
    }
})

$c.btnExportHtml.Add_Click({
    if ($script:Results.Count -eq 0) { Show-MessageBox -Message "Nessun risultato." -Icon Information; return }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $outDir "gdpr-$stamp.html"

    $totalCF=0;$totalPIVA=0;$totalIBAN=0;$totalCARTA=0;$totalEMAIL=0
    foreach ($r in $script:Results) {
        $totalCF+=$r.CF; $totalPIVA+=$r.PIVA; $totalIBAN+=$r.IBAN; $totalCARTA+=$r.CARTA; $totalEMAIL+=$r.EMAIL
    }

    $rowsHtml = New-Object System.Text.StringBuilder
    # ConvertTo-HtmlSafe (da _shared/Common.psm1) escapa anche & e ": la versione
    # precedente sostituiva solo < e >, quindi un path come C:\R&D\clienti.xlsx
    # produceva HTML malformato e una sequenza già escapata poteva ricomporsi in
    # tag. Anche Extension deriva da un nome di file reale, quindi va escapata.
    foreach ($r in $script:Results) {
        $f  = ConvertTo-HtmlSafe $r.File
        $ex = ConvertTo-HtmlSafe $r.ExamplesMasked
        $xt = ConvertTo-HtmlSafe $r.Extension
        $null = $rowsHtml.AppendLine("<tr><td>$f</td><td>$xt</td><td>$($r.SizeKB)</td><td>$($r.CF)</td><td>$($r.PIVA)</td><td>$($r.IBAN)</td><td>$($r.CARTA)</td><td>$($r.EMAIL)</td><td><strong>$($r.Total)</strong></td><td>$ex</td></tr>")
    }

    $scanPathDisplay = if ($script:LastScanPath) { $script:LastScanPath } else { $c.txtPath.Text }

    $html = @"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><title>GDPR Scan Report</title>
<style>
body{font-family:'Segoe UI',sans-serif;background:#F3F3F3;padding:32px;color:#1A1A1A}
.container{max-width:1200px;margin:0 auto}
h1{color:#0078D4;margin:0 0 4px 0}
.subtitle{color:#6B6B6B;margin-bottom:24px}
.card{background:#FFF;border:1px solid #E5E5E5;border-radius:8px;padding:24px;margin-bottom:20px}
.summary{display:grid;grid-template-columns:repeat(5,1fr);gap:16px}
.metric{text-align:center;padding:12px;background:#F9F9F9;border-radius:6px}
.metric .v{font-size:24px;font-weight:600;color:#0078D4}
.metric .l{font-size:12px;color:#6B6B6B;margin-top:4px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;background:#FAFAFA;padding:8px 10px;border-bottom:1px solid #E5E5E5;font-weight:600;color:#6B6B6B}
td{padding:6px 10px;border-bottom:1px solid #F0F0F0;vertical-align:top}
tr:hover td{background:#F9F9F9}
</style></head><body><div class="container">
<h1>GDPR Scan Report</h1>
<div class="subtitle">$(ConvertTo-HtmlSafe $scanPathDisplay) &middot; eseguito $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
<div style="background:#FFF4CE;border:1px solid #C19C00;border-radius:6px;padding:12px 16px;margin-bottom:20px;color:#8A6D00">
<strong>Questo documento contiene dati personali.</strong> Elenca i percorsi dei file in cui sono stati trovati
codici fiscali, IBAN, carte e indirizzi email. Anche con i valori mascherati, l'accostamento fra percorso e tipo di
dato pu&ograve; rendere le persone identificabili: trattalo come il materiale che descrive e cancellalo a fine intervento.
</div>
<div class="card"><h2>Sintesi</h2>
<div class="summary">
<div class="metric"><div class="v">$totalCF</div><div class="l">Codici Fiscali</div></div>
<div class="metric"><div class="v">$totalPIVA</div><div class="l">Partite IVA</div></div>
<div class="metric"><div class="v">$totalIBAN</div><div class="l">IBAN</div></div>
<div class="metric"><div class="v">$totalCARTA</div><div class="l">Carte (Luhn)</div></div>
<div class="metric"><div class="v">$totalEMAIL</div><div class="l">Email</div></div>
</div></div>
<div class="card"><h2>File con dati personali ($($script:Results.Count))</h2>
<table><thead><tr><th>File</th><th>Ext</th><th>KB</th><th>CF</th><th>PIVA</th><th>IBAN</th><th>Carta</th><th>Email</th><th>Tot</th><th>Esempi (mascherati)</th></tr></thead>
<tbody>$($rowsHtml.ToString())</tbody></table></div>
</div></body></html>
"@
    $protected = New-ProtectedFile -Path $out
    $html | Out-File $out -Encoding UTF8
    Write-AuditEntry -Action 'export.html' -Target $out -Result 'Success'
    if (-not $protected) {
        Write-AppLog -Level Error -Message "ACL non applicata su $out"
        Show-MessageBox -Icon Warning -Title "Permessi non ristretti" -Message (
            "Report salvato ma senza permessi ristretti:`n$out`n`n" +
            "Elenca i file che contengono dati personali ed è leggibile da altri utenti del PC.")
    }
    $r = Show-MessageBox -Message "Salvato: $out`n`nAprire?" -Buttons YesNo
    if ($r -eq 'Yes') { Start-Process $out }
})

$w.Add_Closing({
    $script:ScanState.Cancel = $true
    if ($script:ScanState.Timer) { try { $script:ScanState.Timer.Stop() } catch {} }
    if ($script:ScanState.PS)    { try { $script:ScanState.PS.Stop() } catch {}; try { $script:ScanState.PS.Dispose() } catch {} }
    if ($script:ScanState.RS)    { try { $script:ScanState.RS.Close() } catch {} }
    Close-AppAudit; Write-AppLog -Level Info -Message "Chiusura applicazione"
})
[void]$w.ShowDialog()

} catch {
    $errMsg = "Errore fatale all'avvio:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)"
    try {
        $errDir = Join-Path (Split-Path -Parent $PSScriptRoot) "data\logs"
        if (-not (Test-Path $errDir)) { New-Item -ItemType Directory -Path $errDir -Force | Out-Null }
        Add-Content -Path (Join-Path $errDir "fatal-error.log") -Value "[$(Get-Date -Format o)] $errMsg`n$($_.ScriptStackTrace)`n---" -Encoding UTF8
    } catch { }
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 10-GDPRScanner", 'OK', 'Error') | Out-Null
}
