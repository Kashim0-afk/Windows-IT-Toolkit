# Main.ps1 — 06-NetworkTriage. Read-only diagnosi rete.
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
Import-Module (Join-Path $ScriptDir "modules\NetworkTriage.psm1") -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\network-triage.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "06-NetworkTriage"

$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

Set-ReadOnlyBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                   -Detail "ping/DNS/HTTP test, nessuna modifica configurazione di rete"

$script:Results  = New-Object System.Collections.ObjectModel.ObservableCollection[psobject]
$c.lvSteps.ItemsSource = $script:Results
Set-EmptyState -Placeholder $c.lblEmptySteps -ListControl $c.lvSteps -Count 0 `
               -Text "Premi 'Avvia diagnosi' per eseguire i controlli di rete."

# Runspace state: Invoke-FullTriage ha 8 step con timeout 1-5s ciascuno
# (Test-NetConnection, Resolve-DnsName, ping target esterni); senza
# runspace freeze UI fino a ~18s.
$script:TriageQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:TriageState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Cancel = $false
})

function Start-Triage {
    if ($script:TriageState.PS) { return }
    $script:TriageState.Cancel = $false
    $c.btnRun.IsEnabled = $false
    if ($c.btnStop) { $c.btnStop.IsEnabled = $true }
    $script:Results.Clear()
    $c.lblVerdict.Text = "Diagnosi in corso..."
    Write-AuditEntry -Action 'triage.start' -Result 'Info'

    $junk = $null; while ($script:TriageQueue.TryDequeue([ref]$junk)) {}

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\NetworkTriage.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:TriageQueue)
    $rs.SessionStateProxy.SetVariable('State', $script:TriageState)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ModulePath -Force
        $stepCb = { param($r) $Queue.Enqueue([pscustomobject]@{ Type='Step'; Result=$r }) }
        $cancelCb = { return $State.Cancel }
        try {
            $all = Invoke-FullTriage -Step $stepCb -CancelCheck $cancelCb
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; All=$all })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })
    $script:TriageState.PS    = $ps
    $script:TriageState.RS    = $rs
    $script:TriageState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:TriageState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null; $all = $null
        $redrained = $false
        while ($script:TriageQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Step' {
                    $r = $msg.Result
                    $statusLabel = if ($r.Ok) { "OK" } else { "FAIL" }
                    $script:Results.Add([pscustomobject]@{
                        Status = $statusLabel
                        Step   = $r.Step
                        Detail = $r.Detail
                        Advice = $r.Advice
                    }) | Out-Null
                }
                'Done'  { $all = $msg.All; $done = $true }
                'Error' { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        if (-not $done) {
            if ($script:TriageState.Async -and $script:TriageState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:TriageQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }
        $st = $script:TriageState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null

        if ($errMsg) {
            $c.lblVerdict.Text = "Errore: $errMsg"
            # Contatore e stato vuoto vanno azzerati anche qui: restavano quelli
            # della diagnosi precedente ("Test: 8 | Falliti: 0") accanto a un
            # messaggio d'errore, come se il risultato fosse ancora valido.
            $c.lblCounter.Text = ''
            $vsErr = $w.TryFindResource('StatusErr')
            if ($vsErr) { $c.lblVerdict.Style = $vsErr }
            Set-EmptyState -Placeholder $c.lblEmptySteps -ListControl $c.lvSteps -Count 0 `
                           -Text "Diagnosi non riuscita. Il dettaglio tecnico è nel log del tool."
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'triage.error' -Result 'Failure' -Reason $errMsg
        } else {
            $verdict = if ($st.Cancel) { "Diagnosi interrotta dall'utente ($($all.Count) test eseguiti)." } else { Get-Verdict -Results $all }
            $c.lblVerdict.Text = $verdict
            Set-EmptyState -Placeholder $c.lblEmptySteps -ListControl $c.lvSteps -Count @($all).Count `
                           -Text "Nessun controllo eseguito."
            # Colore del verdetto: verde se tutto OK, rosso se almeno un test e'
            # fallito. Prima StatusOk/StatusErr erano definiti nel tema ma non
            # applicati da nessuno, e un esito "tutto a posto" era graficamente
            # identico a uno con problemi critici.
            # Gli oggetti di Invoke-FullTriage espongono Ok (booleano), NON Status:
            # 'Status' esiste solo sugli item della collezione UI. Il filtro
            # precedente non matchava mai nulla, quindi Falliti risultava sempre 0
            # e il verdetto restava verde anche con gateway e DNS irraggiungibili.
            $failed = @($all | Where-Object { -not $_.Ok }).Count
            $styleKey = if ($st.Cancel) { 'StatusWarn' } elseif ($failed -gt 0) { 'StatusErr' } else { 'StatusOk' }
            $c.lblCounter.Text = "Test: $(@($all).Count) | Falliti: $failed"
            $vs = $w.TryFindResource($styleKey)
            if ($vs) { $c.lblVerdict.Style = $vs }
            $script:LastVerdict = $verdict
            $script:LastResults = $all
            $okCount = @($all | Where-Object { $_.Ok }).Count
            Write-AppLog -Level Success -Message "Triage: $okCount/$($all.Count) OK. $verdict"
            Write-AuditEntry -Action 'triage.complete' -Result $(if ($st.Cancel) {'Warning'} else {'Success'}) -Reason "$okCount/$($all.Count) test OK"
        }
        $c.btnRun.IsEnabled = $true
        if ($c.btnStop) { $c.btnStop.IsEnabled = $false }
    })
    $timer.Start()
}

$c.btnRun.Add_Click({ Start-Triage })
if ($c.btnStop) {
    $c.btnStop.IsEnabled = $false
    $c.btnStop.Add_Click({
        $script:TriageState.Cancel = $true
        $c.lblVerdict.Text = "Interruzione richiesta..."
        Write-AuditEntry -Action 'triage.cancel' -Result 'Warning'
    })
}

$c.btnExportTxt.Add_Click({
    if (-not $script:LastResults) { Show-MessageBox -Message "Esegui prima la diagnosi." -Icon Information; return }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $outDir "triage-$stamp.txt"
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("Network Triage Report - $(Get-Date)")
    $null = $sb.AppendLine("PC: $env:COMPUTERNAME / Utente: $env:USERNAME")
    $null = $sb.AppendLine("")
    foreach ($r in $script:LastResults) {
        $tag = if ($r.Ok) { "[OK  ]" } else { "[FAIL]" }
        $null = $sb.AppendLine("$tag $($r.Step)")
        $null = $sb.AppendLine("       $($r.Detail)")
        if ($r.Advice) { $null = $sb.AppendLine("       Suggerimento: $($r.Advice)") }
        $null = $sb.AppendLine("")
    }
    $null = $sb.AppendLine("=== VERDETTO ===")
    $null = $sb.AppendLine($script:LastVerdict)
    # Il report contiene IP interno, gateway, server DNS, proxy WinINET, utente
    # e nome PC: mappa della rete interna. Stessa policy degli altri tool.
    $null = New-ProtectedFile -Path $out
    $sb.ToString() | Out-File $out -Encoding UTF8
    Write-AuditEntry -Action 'export.txt' -Target $out -Result 'Success'
    Show-MessageBox -Message "Report salvato:`n$out"
})

$c.btnIpconfig.Add_Click({
    Start-Process powershell.exe -ArgumentList '-NoProfile','-NoExit','-Command','ipconfig /all; Write-Host "(premi Invio per chiudere)"; [void](Read-Host)'
    Write-AuditEntry -Action 'tool.ipconfig' -Result 'Info'
})

$c.btnFlushDns.Add_Click({
    Start-Process "ms-settings:network"
    Write-AuditEntry -Action 'tool.netsettings' -Result 'Info'
})

$w.Add_Closing({
    $script:TriageState.Cancel = $true
    if ($script:TriageState.Timer) { try { $script:TriageState.Timer.Stop() } catch {} }
    if ($script:TriageState.PS)    { try { $script:TriageState.PS.Stop() } catch {}; try { $script:TriageState.PS.Dispose() } catch {} }
    if ($script:TriageState.RS)    { try { $script:TriageState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 06-NetworkTriage", 'OK', 'Error') | Out-Null
}
