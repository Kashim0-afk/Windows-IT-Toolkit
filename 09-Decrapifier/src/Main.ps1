# Main.ps1 — 09-Decrapifier
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
Import-Module (Join-Path $ScriptDir "modules\DecrapifierLogic.psm1") -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\decrapifier.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "09-Decrapifier"

# Elevazione richiesta all'AVVIO, prima di caricare la UI: così il tecnico
# decide subito invece di scoprire a metà lavoro che l'azione principale è
# disabilitata. Se accetta, questa istanza esce e riparte quella elevata.
if (Request-AdminElevation -ScriptPath (Join-Path $ScriptDir 'Main.ps1') `
                           -ToolName "09-Decrapifier" -Required $true `
                           -Reason "Senza privilegi elevati puoi solo vedere l'anteprima: la rimozione delle app e il ripristino da backup non saranno possibili.") {
    Write-AppLog -Level Info -Message "Riavvio come amministratore richiesto dall'utente"
    exit
}
$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

$isAdmin = Test-IsAdmin
Set-AdminBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                -IsAdmin $isAdmin -Required $true -ToolName "09-Decrapifier (funzioni 'Applica' e 'Ripristina')"
if ($isAdmin) {
    # "(richiede admin)" non serve piu' una volta che i privilegi ci sono.
    $c.btnApply.Content = "Applica"
}
if (-not $isAdmin) {
    $c.btnApply.IsEnabled = $false
    $c.btnApply.ToolTip = "Disabilitato: richiede admin."
    $c.btnElevate.Visibility = 'Visible'
    $c.btnElevate.Add_Click({
        $scriptPath = Join-Path $ScriptDir 'Main.ps1'
        $null = Restart-AsAdmin -ScriptPath $scriptPath
        $w.Close()
    })
}

# Carica profili JSON
$profilesDir = Join-Path $ProjectDir "data\profiles"
if (-not (Test-Path $profilesDir)) { New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null }
$profileFiles = @(Get-ChildItem $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue)
foreach ($pf in $profileFiles) {
    [void]$c.cboProfile.Items.Add($pf.BaseName)
}
# Preselezione ESPLICITA di 'default'. Con SelectedIndex = 0 partiva
# 'aggressive' (ordine alfabetico: aggressive.json viene prima di default.json)
# e Add_Loaded ne mostrava subito l'anteprima: chi premeva "Applica" senza
# guardare la ComboBox rimuoveva Mail/Calendario, Teams, Collegamento al
# telefono e Mappe, cioe' proprio le app che default.json dichiara di NON
# toccare e che aggressive.json avverte di usare solo previo accordo col cliente.
if ($c.cboProfile.Items.Count -gt 0) {
    $idxDefault = $c.cboProfile.Items.IndexOf('default')
    $c.cboProfile.SelectedIndex = [Math]::Max(0, $idxDefault)
}
# La cartella dei profili guida un'operazione distruttiva eseguita da admin:
# va protetta come le altre cartelle dati, altrimenti chiunque può inserirci
# un profilo su misura.
$null = Protect-FileOwnerOnly -Path $profilesDir

$script:CurrentPlan = $null

# Runspace condiviso per preview / apply / restore (apply può durare
# 60-120s su 20+ AppX). Senza runspace UI completamente congelata.
$script:WorkQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:WorkState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Job = ''; Cancel = $false
})

function Append-Log { param([string]$Lvl,[string]$Msg)
    $c.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] [$Lvl] $Msg`r`n"); $c.txtLog.ScrollToEnd()
}

function _Start-Worker {
    param([scriptblock]$Script, [hashtable]$Vars, [string]$Job)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\DecrapifierLogic.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:WorkQueue)
    # Stato condiviso: permette al worker di leggere la richiesta di annullamento
    # impostata dal thread UI (hashtable sincronizzata).
    $rs.SessionStateProxy.SetVariable('State', $script:WorkState)
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Script)
    $script:WorkState.PS    = $ps
    $script:WorkState.RS    = $rs
    $script:WorkState.Async = $ps.BeginInvoke()
    $script:WorkState.Job   = $Job
}

function _Start-Timer {
    if ($script:WorkState.Timer) { try { $script:WorkState.Timer.Stop() } catch {} }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:WorkState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null
        $redrained = $false
        $previewMsg = $null; $applyMsg = $null; $restoreMsg = $null
        while ($script:WorkQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Log' {
                    Append-Log $msg.Level $msg.Message
                    Write-AppLog -Level $msg.Level -Message $msg.Message
                    Write-AuditEntry -Action "$($script:WorkState.Job).step" -Result $msg.Level -Reason $msg.Message
                }
                'PreviewDone' { $previewMsg = $msg; $done = $true }
                'ApplyDone'   { $applyMsg   = $msg; $done = $true }
                'RestoreDone' { $restoreMsg = $msg; $done = $true }
                'Error'       { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        if (-not $done) {
            if ($script:WorkState.Async -and $script:WorkState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:WorkQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }
        $st = $script:WorkState
        $job = $st.Job
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null; $st.Job = ''

        if ($errMsg) {
            $c.lblStatus.Text = "Errore: $errMsg"
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action "${job}.error" -Result 'Failure' -Reason $errMsg
            Show-MessageBox -Message "Errore: $errMsg" -Icon Error
        } elseif ($previewMsg) {
            $plan = $previewMsg.Plan
            $script:CurrentPlan = $plan
            $c.lvAppx.ItemsSource         = $plan.AppxToRemove
            $c.lvNotInstalled.ItemsSource = $plan.AppxNotInstalled
            $c.lblCounter.Text = "Da rimuovere: $(@($plan.AppxToRemove).Count) | Gia assenti: $(@($plan.AppxNotInstalled).Count)"
            Set-EmptyState -Placeholder $c.lblEmptyNotInstalled -ListControl $c.lvNotInstalled -Count @($plan.AppxNotInstalled).Count `
                           -Text "Tutte le app previste dal profilo risultano presenti su questo PC."
            # Stato vuoto esplicito: una lista bianca si legge come "caricamento
            # fallito", una frase si legge come "controllato, non c'e' nulla".
            Set-EmptyState -Placeholder $c.lblAppxEmpty -ListControl $c.lvAppx `
                           -Count @($plan.AppxToRemove).Count

            $blockedSummary = ''
            if ($plan.AppxBlockedSafety -and $plan.AppxBlockedSafety.Count -gt 0) {
                $c.lblBlocked.Text = "$($plan.AppxBlockedSafety.Count) app critiche di sistema bloccate automaticamente e MAI rimosse: " +
                                     (($plan.AppxBlockedSafety | Select-Object -First 6) -join ', ') +
                                     $(if ($plan.AppxBlockedSafety.Count -gt 6) { ' ...' } else { '' })
                $c.brdBlocked.Visibility = 'Visible'
                $blockedSummary = " | $($plan.AppxBlockedSafety.Count) bloccati da blacklist sicurezza"
                Write-AppLog -Level Warning -Message ("Blacklist ha bloccato: " + ($plan.AppxBlockedSafety -join ', '))
                foreach ($b in $plan.AppxBlockedSafety) {
                    Write-AuditEntry -Action 'preview.blocked' -Target $b -Result 'Warning' -Reason 'Critical AppX blacklist'
                }
            } else {
                # Nasconde il banner quando l'anteprima viene rieseguita dopo Applica
                # e non c'e' più nulla di bloccato.
                $c.brdBlocked.Visibility = 'Collapsed'
            }
            $c.lblStatus.Text = "Anteprima profilo '$($plan.ProfileName)': $($plan.AppxToRemove.Count) app da rimuovere, $($plan.AppxNotInstalled.Count) già assenti$blockedSummary."
            Write-AppLog -Level Success -Message "Preview: $($plan.AppxToRemove.Count) app da rimuovere"
            Write-AuditEntry -Action 'preview.complete' -Result 'Success' -Reason "$($plan.AppxToRemove.Count) targets, $($plan.AppxBlockedSafety.Count) blocked"
        } elseif ($applyMsg) {
            $r = $applyMsg.Result
            $wasCancelled = [bool]$r.Cancelled
            $head = if ($wasCancelled) { "Operazione interrotta dall'utente." } else { "Operazione completata." }
            $c.lblStatus.Text = "$head Rimossi: $($r.RemovedOk) / Falliti: $($r.RemovedKo). Backup: $($r.BackupPath)"
            Write-AuditEntry -Action 'apply.complete' -Result $(if ($wasCancelled) { 'Warning' } else { 'Success' }) `
                             -Reason "Removed=$($r.RemovedOk), Failed=$($r.RemovedKo), Cancelled=$wasCancelled"
            Show-MessageBox -Title $(if ($wasCancelled) { "Interrotta" } else { "Completata" }) `
                            -Icon $(if ($wasCancelled) { 'Warning' } else { 'Information' }) `
                            -Message "$head`nRimossi: $($r.RemovedOk)`nFalliti: $($r.RemovedKo)`n`nBackup: $($r.BackupPath)"
            # Come in 07: Annulla spento prima del return, altrimenti resta
            # cliccabile durante l'anteprima automatica senza alcun effetto.
            if ($c.btnCancel) { $c.btnCancel.IsEnabled = $false }
            $script:WorkState.Cancel = $false
            Run-Preview  # ri-pull stato
            return       # btnPreview/Apply IsEnabled gestiti da Run-Preview
        } elseif ($restoreMsg) {
            $res = $restoreMsg.Result
            $c.lblStatus.Text = "Ripristino completato. Reinstallati: $($res.Restored) / Falliti: $($res.Failed)."
            Write-AuditEntry -Action 'restore.complete' -Result 'Success' -Reason "Restored=$($res.Restored), Failed=$($res.Failed)"
            Show-MessageBox -Message "Reinstallati: $($res.Restored)`nFalliti: $($res.Failed)" -Title "Ripristino completato" -Icon Information
        }
        $c.btnPreview.IsEnabled = $true
        $c.btnApply.IsEnabled   = $isAdmin
        if ($c.btnRestore) { $c.btnRestore.IsEnabled = $isAdmin }
        if ($c.btnCancel)  { $c.btnCancel.IsEnabled  = $false }
        $script:WorkState.Cancel = $false
    })
    $timer.Start()
}

function Load-CurrentProfile {
    $name = $c.cboProfile.SelectedItem
    if (-not $name) { return $null }
    $jsonFile = Join-Path $profilesDir ("$name.json")
    if (-not (Test-Path $jsonFile)) { return $null }
    try {
        return Read-DecrapifierProfile -Path $jsonFile
    } catch {
        Show-MessageBox -Title "Profilo non valido" -Icon Error -Message (
            "Il profilo '$name.json' non è leggibile: il file JSON non è valido.`n`n" +
            "Cosa fare: premi 'Apri cartella profili', apri '$name.json' con un editor di testo " +
            "e correggi la sintassi, oppure riparti da 'default.json' che è sempre valido.`n`n" +
            "--- Dettaglio tecnico ---`n$($_.Exception.Message)")
        Write-AppLog -Level Error -Message ("Profilo {0}: {1}" -f $name, $_.Exception.Message)
        return $null
    }
}

function Run-Preview {
    if ($script:WorkState.PS) { return }
    # NOTA: niente $profile - è variabile automatica PowerShell.
    $selectedProfile = Load-CurrentProfile
    if (-not $selectedProfile) { Show-MessageBox -Message "Nessun profilo caricato." -Icon Warning; return }

    $c.btnPreview.IsEnabled = $false
    $c.lblStatus.Text = "Anteprima in corso..."
    Write-AuditEntry -Action 'preview.start' -Target $selectedProfile.name -Result 'Info'

    $junk = $null; while ($script:WorkQueue.TryDequeue([ref]$junk)) {}
    _Start-Worker -Job 'preview' -Vars @{ ProfileObject = $selectedProfile } -Script {
        Import-Module $ModulePath -Force
        try {
            $plan = Get-DecrapifierPlan -ProfileObject $ProfileObject
            $Queue.Enqueue([pscustomobject]@{ Type='PreviewDone'; Plan=$plan })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    }
    _Start-Timer
}

function Run-Apply {
    if (-not (Test-IsAdmin)) {
        Show-MessageBox -Message "Devi lanciare come amministratore." -Icon Warning
        return
    }
    if (-not $script:CurrentPlan) {
        Show-MessageBox -Message "Esegui prima l'anteprima." -Icon Information
        return
    }
    if ($script:CurrentPlan.AppxToRemove.Count -eq 0) {
        Show-MessageBox -Message "Nessuna app da rimuovere." -Icon Information
        return
    }

    $msg = "Verrà eseguito:`n- Backup stato AppX in data\backups\`n- Rimozione di $($script:CurrentPlan.AppxToRemove.Count) AppX:`n`n  " +
           (($script:CurrentPlan.AppxToRemove | Select-Object -First 25 -ExpandProperty Name) -join "`n  ") +
           $(if ($script:CurrentPlan.AppxToRemove.Count -gt 25) { "`n  ...e altre $($script:CurrentPlan.AppxToRemove.Count - 25) (elenco completo nella scheda 'App da rimuovere')" }) +
           "`n`nProcedere?`n`n" +
           "('Ripristina ultimo backup' tenta di rimettere a posto le app rimosse, ma solo quelle " +
           "i cui file sono ancora presenti sul disco: alcune vanno reinstallate a mano dallo Store.)"
    $r = Show-MessageBox -Message $msg -Title "Conferma applicazione" -Buttons YesNo -Icon Warning
    if ($r -ne 'Yes') {
        $c.lblStatus.Text = "Operazione annullata."
        Write-AuditEntry -Action 'apply.cancelled' -Result 'Warning'
        return
    }

    if ($script:WorkState.PS) { return }
    $c.btnApply.IsEnabled = $false
    $c.btnPreview.IsEnabled = $false
    $script:WorkState.Cancel = $false
    if ($c.btnCancel) { $c.btnCancel.IsEnabled = $true }
    $c.txtLog.Text = ""
    $c.lblStatus.Text = "Applicazione in corso... (puoi interromperla con 'Annulla')"
    Write-AuditEntry -Action 'apply.start' -Target $script:CurrentPlan.ProfileName -Result 'Info' -Reason "$($script:CurrentPlan.AppxToRemove.Count) targets"

    $junk = $null; while ($script:WorkQueue.TryDequeue([ref]$junk)) {}
    $vars = @{
        Plan      = $script:CurrentPlan
        BackupDir = (Join-Path $ProjectDir "data\backups")
    }
    _Start-Worker -Job 'apply' -Vars $vars -Script {
        Import-Module $ModulePath -Force
        $logCb = { param($lvl,$msg) $Queue.Enqueue([pscustomobject]@{ Type='Log'; Level=$lvl; Message=$msg }) }
        $cancelCb = { return $State.Cancel }
        try {
            $r = Invoke-Decrapifier -Plan $Plan -BackupDir $BackupDir -Log $logCb -CancelCheck $cancelCb
            $Queue.Enqueue([pscustomobject]@{ Type='ApplyDone'; Result=$r })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    }
    _Start-Timer
}

function Run-Restore {
    if (-not (Test-IsAdmin)) {
        Show-MessageBox -Message "Devi lanciare come amministratore per ripristinare." -Icon Warning
        return
    }
    $backupRoot = Join-Path $ProjectDir "data\backups"
    if (-not (Test-Path $backupRoot)) {
        Show-MessageBox -Message "Nessun backup trovato in data\backups\." -Icon Information
        return
    }
    $backups = @(Get-ChildItem $backupRoot -Directory -Filter 'appx-state-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) {
        Show-MessageBox -Message "Nessun backup AppX trovato in data\backups\." -Icon Information
        return
    }
    $latest = $backups[0]
    $r = Show-MessageBox -Message "Ripristino backup piu recente:`n$($latest.FullName)`n`n(Backup del $($latest.LastWriteTime))`n`nL'operazione tenta di ri-aggiungere AppxProvisionedPackage rimossi.`nProcedere?" -Title "Conferma ripristino" -Buttons YesNo -Icon Warning
    if ($r -ne 'Yes') { return }

    if ($script:WorkState.PS) { return }
    $c.btnRestore.IsEnabled = $false
    $c.btnApply.IsEnabled   = $false
    $c.btnPreview.IsEnabled = $false
    $c.txtLog.Text = ""
    $c.lblStatus.Text = "Ripristino in corso..."
    Write-AuditEntry -Action 'restore.start' -Target $latest.FullName -Result 'Info'

    $junk = $null; while ($script:WorkQueue.TryDequeue([ref]$junk)) {}
    _Start-Worker -Job 'restore' -Vars @{ BackupPath = $latest.FullName } -Script {
        Import-Module $ModulePath -Force
        $logCb = { param($lvl,$msg) $Queue.Enqueue([pscustomobject]@{ Type='Log'; Level=$lvl; Message=$msg }) }
        try {
            $res = Restore-AppxFromBackup -BackupPath $BackupPath -Log $logCb
            $Queue.Enqueue([pscustomobject]@{ Type='RestoreDone'; Result=$res })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    }
    _Start-Timer
}

$c.btnPreview.Add_Click({ Run-Preview })
$c.btnApply.Add_Click(  { Run-Apply })
if ($c.btnCancel) {
    $c.btnCancel.Add_Click({
        # L'interruzione avviene fra una app e la successiva: fermare una
        # rimozione a meta' lascerebbe il pacchetto in stato incoerente.
        $script:WorkState.Cancel = $true
        $c.btnCancel.IsEnabled = $false
        $c.lblStatus.Text = "Interruzione richiesta: l'operazione si fermera' dopo l'app in corso..."
        Write-AuditEntry -Action 'apply.cancel_requested' -Result 'Warning'
    })
}
if ($c.btnRestore) {
    if (-not $isAdmin) { $c.btnRestore.IsEnabled = $false }
    $c.btnRestore.Add_Click({ Run-Restore })
}
$c.btnOpenProfiles.Add_Click({
    if (-not (Test-Path $profilesDir)) { New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null }
    Start-Process explorer.exe $profilesDir
})

$w.Add_Loaded({ Run-Preview })
$w.Add_Closing({
    if ($script:WorkState.Timer) { try { $script:WorkState.Timer.Stop() } catch {} }
    if ($script:WorkState.PS)    { try { $script:WorkState.PS.Stop() } catch {}; try { $script:WorkState.PS.Dispose() } catch {} }
    if ($script:WorkState.RS)    { try { $script:WorkState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 09-Decrapifier", 'OK', 'Error') | Out-Null
}
