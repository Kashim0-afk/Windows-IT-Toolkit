# Main.ps1 — 08-BackupVerifier
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
Import-Module (Join-Path $ScriptDir "modules\BackupParsers.psm1") -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\backup-verifier.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "08-BackupVerifier"

$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

Set-ReadOnlyBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                   -Detail "parsing log Macrium/Veeam/WSB, nessuna modifica ai backup"

$script:LastResults = $null
$c.btnExportTxt.IsEnabled = $false

# Runspace + DispatcherTimer come negli altri 9 tool.
# Prima Invoke-BackupCheck girava SINCRONO sul thread UI: Get-WinEvent su 30
# giorni, Get-ChildItem -Recurse sui log Macrium e Get-WBJob possono impiegare
# decine di secondi, e siccome partiva da Add_Loaded la finestra risultava
# "Non risponde" già all'apertura. Il callback di progresso usava Invoke-OnUI,
# ma il Dispatcher era bloccato dalla chiamata stessa: nessun repaint.
$script:CheckQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:CheckState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null
})

function Run-Check {
    if ($script:CheckState.PS) { return }   # già in corso

    $c.btnCheck.IsEnabled = $false
    $c.btnExportTxt.IsEnabled = $false
    $c.lblStatus.Text = "Verifica in corso..."
    Set-EmptyState -Placeholder $c.lblEmpty -ListControl $c.lvBackups -Count 1
    Write-AuditEntry -Action 'check.start' -Result 'Info'

    $junk = $null; while ($script:CheckQueue.TryDequeue([ref]$junk)) {}

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\BackupParsers.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:CheckQueue)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        try {
            Import-Module $ModulePath -Force
            $progressCb = {
                param($i,$t,$n)
                $Queue.Enqueue([pscustomobject]@{ Type='Progress'; Step=$i; Total=$t; Name=$n })
            }
            $r = Invoke-BackupCheck -Progress $progressCb
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; Result=$r })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })
    $script:CheckState.PS    = $ps
    $script:CheckState.RS    = $rs
    $script:CheckState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:CheckState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null; $res = $null
        $redrained = $false
        while ($script:CheckQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Progress' {
                    $c.lblStatus.Text = "Controllo $($msg.Name) ($($msg.Step)/$($msg.Total))"
                }
                'Done'  { $res = $msg.Result; $done = $true }
                'Error' { $errMsg = $msg.Message; $done = $true }
            }
        }
        if (-not $done) {
            if ($script:CheckState.Async -and $script:CheckState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:CheckQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }

        $st = $script:CheckState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null

        if ($errMsg) {
            $c.lblStatus.Text = "Errore: $errMsg"
            # Azzerato anche il contatore: restava "Attivi: 2 / 4" della verifica
            # precedente accanto al messaggio d'errore.
            $c.lblCounter.Text = ''
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'check.error' -Result 'Failure' -Reason $errMsg
            Show-ErrorBox -Message $errMsg -Context "La verifica dei backup non è stata completata." -Title "Errore verifica"
            Set-EmptyState -Placeholder $c.lblEmpty -ListControl $c.lvBackups -Count 0 `
                           -Text "Verifica non riuscita. Il dettaglio tecnico è nel log del tool."
        } else {
            $arr = @($res)
            $c.lvBackups.ItemsSource = $arr
            $script:LastResults = $arr
            $c.btnExportTxt.IsEnabled = ($arr.Count -gt 0)
            $installed = @($arr | Where-Object { $_.Installed -eq $true }).Count
            Set-EmptyState -Placeholder $c.lblEmpty -ListControl $c.lvBackups -Count $arr.Count `
                           -Text "Nessun sistema di backup riconosciuto su questo PC (cercati Macrium Reflect, Veeam Agent, Acronis e Backup di Windows Server)."
            $msg2 = "Verifica completata. Sistemi di backup attivi: $installed su $($arr.Count) controllati."
            $c.lblStatus.Text = $msg2
            $c.lblCounter.Text = "Attivi: $installed / $($arr.Count)"
            Write-AppLog -Level Success -Message $msg2
            Write-AuditEntry -Action 'check.complete' -Result 'Success' -Reason "$installed/$($arr.Count) installati"
        }
        $c.btnCheck.IsEnabled = $true
    })
    $timer.Start()
}

$c.btnCheck.Add_Click({ Run-Check })

$c.btnExportTxt.Add_Click({
    if (-not $script:LastResults) { Show-MessageBox -Message "Esegui prima la verifica." -Icon Information; return }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $outDir "backup-check-$stamp.txt"
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("Backup Verifier - $(Get-Date)")
    $null = $sb.AppendLine("PC: $env:COMPUTERNAME")
    $null = $sb.AppendLine("")
    foreach ($r in $script:LastResults) {
        $null = $sb.AppendLine("=== $($r.System) ===")
        $null = $sb.AppendLine("  Installato: $($r.Installed)")
        $null = $sb.AppendLine("  Stato:      $($r.Status)")
        $null = $sb.AppendLine("  Ultimo job: $($r.LastJob)")
        $null = $sb.AppendLine("  Dettaglio:  $($r.Detail)")
        $null = $sb.AppendLine("")
    }
    # Elenca quali sistemi di backup esistono, se funzionano e dove sono i log:
    # è esattamente la ricognizione che precede un attacco ransomware.
    $null = New-ProtectedFile -Path $out
    $sb.ToString() | Out-File $out -Encoding UTF8
    Write-AuditEntry -Action 'export.txt' -Target $out -Result 'Success'
    Show-MessageBox -Message "Salvato: $out"
})

$w.Add_Loaded({ Run-Check })
$w.Add_Closing({
    # Termina il worker se ancora attivo, come negli altri tool.
    if ($script:CheckState.Timer) { try { $script:CheckState.Timer.Stop() } catch {} }
    if ($script:CheckState.PS)    { try { $script:CheckState.PS.Stop() } catch {}; try { $script:CheckState.PS.Dispose() } catch {} }
    if ($script:CheckState.RS)    { try { $script:CheckState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 08-BackupVerifier", 'OK', 'Error') | Out-Null
}
