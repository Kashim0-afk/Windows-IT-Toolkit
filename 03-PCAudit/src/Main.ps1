# Main.ps1 — 03-PCAudit
# Audit completo del PC. Read-only. Output HTML stilizzato.

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
Import-Module (Join-Path $ScriptDir "modules\AuditCollectors.psm1") -Force
Import-Module (Join-Path $ScriptDir "modules\ReportRenderer.psm1")  -Force

$logPath  = Join-Path $ProjectDir "data\logs\pc-audit.log"
$auditDir = Join-Path $ProjectDir "data\audit"
Initialize-AppLog   -Path $logPath
Initialize-AppAudit -AuditDir $auditDir -AppName "03-PCAudit"

# Elevazione richiesta all'AVVIO, prima di caricare la UI: così il tecnico
# decide subito invece di scoprire a metà lavoro che l'azione principale è
# disabilitata. Se accetta, questa istanza esce e riparte quella elevata.
if (Request-AdminElevation -ScriptPath (Join-Path $ScriptDir 'Main.ps1') `
                           -ToolName "03-PCAudit" -Required $false `
                           -Reason "la chiave di ripristino BitLocker, lo stato del TPM e i profili WiFi di tutti gli utenti") {
    Write-AppLog -Level Info -Message "Riavvio come amministratore richiesto dall'utente"
    exit
}
$xamlPath  = Join-Path $ScriptDir "MainWindow.xaml"
$themePath = Join-Path $SharedDir "assets\Theme.xaml"

$ui = Import-XamlWindow -XamlPath $xamlPath -ThemePath $themePath
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito (file: $xamlPath)" }
$w  = $ui.Window
$c  = $ui.Controls

$c.lblSubtitle.Text = "Genera un report completo di hardware, sistema, sicurezza e rete in 30-90 secondi. Non modifica nulla. | PC: $env:COMPUTERNAME | Utente: $env:USERNAME"
$script:IsAdmin = Test-IsAdmin
# Banner blu informativo, non giallo: il tool è read-only puro, da admin
# raccoglie solo qualche dato in più. Un giallo d'avviso qui allarmerebbe a vuoto.
Set-ReadOnlyExtrasBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                         -IsAdmin $script:IsAdmin `
                         -Extras "chiave di ripristino BitLocker, stato TPM e profili WiFi di tutti gli utenti"

# Mostra il bottone "Esegui come amministratore" solo se non lo siamo già.
# Necessario per leggere BitLocker recovery key e profili WiFi 'tutti gli utenti'.
if (-not $script:IsAdmin) {
    $c.btnElevate.Visibility = 'Visible'
    $c.btnElevate.Add_Click({
        $scriptPath = Join-Path $ScriptDir 'Main.ps1'
        if (Restart-AsAdmin -ScriptPath $scriptPath) {
            $w.Close()
        }
    })
}

Write-AppLog -Level Info -Message "Avvio PC Audit"

$script:LastAudit = $null

# Coda thread-safe per messaggi worker -> UI thread (vedi memoria WPF+PS runspace:
# NON usare Dispatcher.BeginInvoke con scriptblock PS).
$script:AuditQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:AuditState = [hashtable]::Synchronized(@{
    PS    = $null
    RS    = $null
    Async = $null
    Timer = $null
    Stopwatch = $null
})

function Start-Audit {
    if ($script:AuditState.PS) { return }  # già in corso

    $c.btnAudit.IsEnabled = $false
    $c.prgScan.Value = 0
    $c.lblStatus.Text = "Audit in corso..."
    foreach ($t in 'txtHW','txtOS','txtSec','txtNet','txtUsr','txtSw') { $c.$t.Text = '' }
    Write-AuditEntry -Action 'audit.start' -Result 'Info'

    $script:AuditState.Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Svuota residui da run precedenti
    $junk = $null; while ($script:AuditQueue.TryDequeue([ref]$junk)) {}

    # Runspace separato: le chiamate CIM/Get-BitLocker/Get-Tpm/registry possono
    # impiegare 20-60s e bloccherebbero la UI se eseguite sul thread Dispatcher.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\AuditCollectors.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:AuditQueue)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ModulePath -Force
        $progressCb = {
            param($s,$t,$n)
            $Queue.Enqueue([pscustomobject]@{ Type='Progress'; Step=$s; Total=$t; Name=$n })
        }
        try {
            $audit = Invoke-FullAudit -Progress $progressCb
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; Audit=$audit })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })

    $script:AuditState.PS    = $ps
    $script:AuditState.RS    = $rs
    $script:AuditState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:AuditState.Timer = $timer
    $timer.Add_Tick({
        # 1. Drena messaggi (UI thread, no cross-thread)
        $msg = $null
        $done = $false
        $redrained = $false
        $errMsg = $null
        $audit = $null
        while ($script:AuditQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Progress' {
                    $pct = if ($msg.Total -gt 0) { [math]::Round(($msg.Step / $msg.Total) * 100) } else { 0 }
                    $c.prgScan.Value  = $pct
                    $c.lblStatus.Text = "Raccolta: $($msg.Name) ($($msg.Step) / $($msg.Total))"
                }
                'Done'  { $audit = $msg.Audit; $done = $true }
                'Error' { $errMsg = $msg.Message; $done = $true }
            }
        }

        # Watchdog: il completamento non può dipendere SOLO da un messaggio in
        # coda. Se il worker muore prima di accodare (modulo mancante, errore
        # fuori dal try interno) non arriva né Done né Error: senza questo
        # controllo il timer gira all'infinito, il pulsante resta disabilitato e
        # la status bar resta su "in corso" per sempre.
        if (-not $done) {
            if ($script:AuditState.Async -and $script:AuditState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:AuditQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }

        # 2. Cleanup runspace
        $st = $script:AuditState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null
        $st.Stopwatch.Stop()
        $secs = [math]::Round($st.Stopwatch.Elapsed.TotalSeconds, 1)

        # 3. Esito
        if ($errMsg) {
            $c.lblStatus.Text = "Errore: $errMsg"
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'audit.error' -Result 'Failure' -Reason $errMsg
            Show-ErrorBox -Message $errMsg -Context "L'audit non è stato completato." -Title "Errore audit"
        } else {
            $script:LastAudit = $audit
            $c.txtHW.Text  = Format-AuditAsText $audit.Hardware
            $c.txtOS.Text  = Format-AuditAsText $audit.Sistema
            $c.txtSec.Text = Format-AuditAsText $audit.Sicurezza
            $c.txtNet.Text = Format-AuditAsText $audit.Rete
            $c.txtUsr.Text = Format-AuditAsText $audit.Utenti
            $c.txtSw.Text  = if ($audit.Software -and $audit.Software.Apps) {
                "Totale: $($audit.Software.Count) applicazioni`n`n" +
                (($audit.Software.Apps | Select-Object Name, Version, Publisher | Format-Table -AutoSize | Out-String).TrimEnd())
            } else { '(nessun dato)' }
            $c.prgScan.Value = 100
            $msg2 = "Audit completato in ${secs}s. Premi 'Esporta HTML' per salvare il report."
            $c.lblStatus.Text  = $msg2
            $c.lblCounter.Text = "Software: $($audit.Software.Count) | Adapter UP: $($audit.Hardware.NetAdapters.Count)"
            Write-AppLog -Level Success -Message $msg2
            Write-AuditEntry -Action 'audit.complete' -Result 'Success' -Reason $msg2
        }
        $c.btnAudit.IsEnabled = $true
    })
    $timer.Start()
}

function Export-Html {
    if (-not $script:LastAudit) {
        Show-MessageBox -Message "Esegui prima l'audit." -Title "Nessun dato" -Icon Information
        return
    }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $outDir ("audit-{0}-{1}.html" -f $env:COMPUTERNAME, $stamp)

    # Il report può contenere la chiave di ripristino BitLocker in chiaro.
    # New-ProtectedFile irrigidisce cartella E file PRIMA della scrittura: con il
    # pattern precedente (scrivi poi proteggi) il contenuto restava leggibile
    # secondo le ACL ereditate per tutta la durata della scrittura, e la cartella
    # veniva protetta solo alla prima creazione, mai più dopo.
    # Conferma PRIMA di scrivere, come in 04-KeyRecovery: il report può contenere
    # la chiave di ripristino BitLocker in chiaro. Avvisare dopo l'Out-File
    # significherebbe constatare il danno invece di lasciar decidere il tecnico.
    $protected = New-ProtectedFile -Path $outFile
    if (-not $protected) {
        $go = Show-MessageBox -Buttons YesNo -Icon Warning -Title "Permessi non ristretti" -Message (
            "NON è stato possibile limitare i permessi del file:`n$outFile`n`n" +
            "Il report può contenere la chiave di ripristino BitLocker in chiaro e sarebbe " +
            "leggibile da altri utenti di questo PC.`n`nSalvare comunque?")
        if ($go -ne 'Yes') {
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            Write-AppLog -Level Warning -Message "Export annullato: ACL non applicabile su $outFile"
            Write-AuditEntry -Action 'export.html' -Target $outFile -Result 'Warning' -Reason 'Annullato: ACL non applicabile'
            return
        }
        Write-AppLog -Level Error -Message "ACL non applicata su $outFile (export forzato dall'utente)"
        Write-AuditEntry -Action 'export.acl_failed' -Target $outFile -Result 'Warning'
    }
    $html = Format-AuditAsHtml -Audit $script:LastAudit
    $html | Out-File -FilePath $outFile -Encoding UTF8
    Write-AppLog -Level Success -Message "Report HTML: $outFile"
    Write-AuditEntry -Action 'export.html' -Target $outFile -Result 'Success'

    $r = Show-MessageBox -Message "Report salvato:`n$outFile`n`nAprire ora?" -Title "Esportato" -Buttons YesNo -Icon Information
    if ($r -eq 'Yes') { Start-Process $outFile }
}

function Open-LastReport {
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { Show-MessageBox -Message "Nessun report finora. Genera con 'Esporta HTML'." -Icon Information; return }
    $last = Get-ChildItem $outDir -Filter "audit-*.html" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last) { Start-Process $last.FullName }
    else { Show-MessageBox -Message "Nessun report finora." -Icon Information }
}

function Open-ReportFolder {
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    # Anche qui: se la cartella nasce da questo pulsante resterebbe con ACL
    # ereditate, e i report successivi la troverebbero già esistente.
    $null = Protect-FileOwnerOnly -Path $outDir
    Start-Process explorer.exe $outDir
}

$c.btnAudit.Add_Click(     { Start-Audit })
$c.btnExportHtml.Add_Click({ Export-Html })
$c.btnOpenReport.Add_Click({ Open-LastReport })
$c.btnOpenFolder.Add_Click({ Open-ReportFolder })

# Audit non parte automaticamente (richiede ~30s e gira in runspace separato).
# L'utente preme 'Esegui audit' quando è pronto.
$w.Add_Closing({
    # Termina worker se ancora attivo (evita runspace orfani in background)
    if ($script:AuditState.Timer) { try { $script:AuditState.Timer.Stop() } catch {} }
    if ($script:AuditState.PS)    { try { $script:AuditState.PS.Stop() } catch {}; try { $script:AuditState.PS.Dispose() } catch {} }
    if ($script:AuditState.RS)    { try { $script:AuditState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 03-PCAudit", 'OK', 'Error') | Out-Null
}
