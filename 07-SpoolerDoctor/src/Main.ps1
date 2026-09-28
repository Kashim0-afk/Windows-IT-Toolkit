# Main.ps1 — 07-SpoolerDoctor
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
Import-Module (Join-Path $ScriptDir "modules\SpoolerDoctor.psm1") -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\spooler-doctor.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "07-SpoolerDoctor"

# Elevazione richiesta all'AVVIO, prima di caricare la UI: così il tecnico
# decide subito invece di scoprire a metà lavoro che l'azione principale è
# disabilitata. Se accetta, questa istanza esce e riparte quella elevata.
if (Request-AdminElevation -ScriptPath (Join-Path $ScriptDir 'Main.ps1') `
                           -ToolName "07-SpoolerDoctor" -Required $true `
                           -Reason "Senza privilegi elevati puoi solo eseguire la diagnosi: fermare lo spooler, svuotare la coda di stampa e rimuovere driver orfani non sarà possibile.") {
    Write-AppLog -Level Info -Message "Riavvio come amministratore richiesto dall'utente"
    exit
}
$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

$isAdmin = Test-IsAdmin
$c.lblSubtitle.Text = "Diagnosi e risoluzione problemi di stampa | PC: $env:COMPUTERNAME"
Set-AdminBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                -IsAdmin $isAdmin -Required $true -ToolName "07-SpoolerDoctor (funzione 'Risolvi')"
if ($isAdmin) {
    # "(richiede admin)" non serve piu' una volta che i privilegi ci sono:
    # resterebbe un avviso inutile che sporca la barra.
    $c.btnRepair.Content = "Risolvi"
}
if (-not $isAdmin) {
    $c.btnRepair.IsEnabled = $false
    $c.btnRepair.ToolTip = "Disabilitato: richiede privilegi amministratore. Usa 'Riavvia come amministratore' qui sopra."
    $c.btnElevate.Visibility = 'Visible'
    $c.btnElevate.Add_Click({
        $scriptPath = Join-Path $ScriptDir 'Main.ps1'
        $null = Restart-AsAdmin -ScriptPath $scriptPath
        $w.Close()
    })
}

function Append-Log { param([string]$Lvl, [string]$Msg)
    $c.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] [$Lvl] $Msg`r`n"); $c.txtLog.ScrollToEnd()
}

# Runspace shared per diagnose+repair: entrambi possono richiedere 5-8s
# (Stop-Service Spooler, restart, Get-Printer/Driver/Port).
$script:WorkQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:WorkState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Job = ''; Cancel = $false
})

function _Start-Worker {
    param([scriptblock]$Script, [hashtable]$Vars, [string]$Job)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\SpoolerDoctor.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:WorkQueue)
    # Stato condiviso: il worker legge da qui la richiesta di annullamento.
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

function Run-Diagnose {
    if ($script:WorkState.PS) { return }
    $c.btnDiagnose.IsEnabled = $false
    $c.lblStatus.Text = "Diagnosi in corso..."
    Write-AuditEntry -Action 'diagnose.start' -Result 'Info'

    $junk = $null; while ($script:WorkQueue.TryDequeue([ref]$junk)) {}

    _Start-Worker -Job 'diagnose' -Vars @{} -Script {
        Import-Module $ModulePath -Force
        $logCb = { param($lvl,$msg) $Queue.Enqueue([pscustomobject]@{ Type='Log'; Level=$lvl; Message=$msg }) }
        try {
            $svc = Get-SpoolerStatus
            $inv = Get-SpoolerInventory -Log $logCb
            $Queue.Enqueue([pscustomobject]@{ Type='DiagnoseDone'; Svc=$svc; Inv=$inv })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    }
    _Start-Timer
}

function _Apply-DiagnoseResult {
    param($svc, $inv)
    # Cache dell'inventario: Run-Repair lo riusa invece di richiamare
    # Get-SpoolerInventory / Get-RemovableOrphanDrivers sul thread UI.
    $script:LastInventory = $inv
    $statusText = New-Object System.Text.StringBuilder
    $null = $statusText.AppendLine("=== Servizio Spooler ===")
    $null = $statusText.AppendLine("  Status:    $($svc.Status)")
    $null = $statusText.AppendLine("  StartType: $($svc.StartType)")
    $null = $statusText.AppendLine("")
    $null = $statusText.AppendLine("=== Inventario ===")
    $null = $statusText.AppendLine("  Stampanti installate:   $($inv.Printers.Count)")
    $null = $statusText.AppendLine("  Driver di stampa:       $($inv.Drivers.Count)")
    $null = $statusText.AppendLine("  Porte stampante:        $($inv.Ports.Count)")
    $null = $statusText.AppendLine("  Job in coda:            $($inv.Jobs.Count)")
    $null = $statusText.AppendLine("  Driver orfani:          $($inv.OrphanDrivers.Count)")
    $null = $statusText.AppendLine("  File in spool dir:      $($inv.SpoolDirItems)  ($($inv.SpoolDir))")

    $c.txtStatus.Text         = $statusText.ToString()
    $c.lvPrinters.ItemsSource = $inv.Printers
    $c.lvJobs.ItemsSource     = $inv.Jobs
    $c.lvOrphans.ItemsSource  = $inv.OrphanDrivers
    $c.lblCounter.Text = "Stampanti: $(@($inv.Printers).Count) | Job: $(@($inv.Jobs).Count) | Orfani: $(@($inv.OrphanDrivers).Count)"
    Set-EmptyState -Placeholder $c.lblEmptyPrinters -ListControl $c.lvPrinters -Count @($inv.Printers).Count `
                   -Text "Nessuna stampante installata su questo PC."
    Set-EmptyState -Placeholder $c.lblEmptyJobs -ListControl $c.lvJobs -Count @($inv.Jobs).Count `
                   -Text "Nessun lavoro di stampa in coda. La coda è pulita."
    Set-EmptyState -Placeholder $c.lblEmptyOrphans -ListControl $c.lvOrphans -Count @($inv.OrphanDrivers).Count `
                   -Text "Nessun driver di stampa orfano: tutti i driver installati sono usati da almeno una stampante."
    $c.lblStatus.Text = "Diagnosi completata. Stampanti=$($inv.Printers.Count), Job=$($inv.Jobs.Count), Orfani=$($inv.OrphanDrivers.Count)"
    Write-AppLog -Level Success -Message "Diagnosi: $($inv.Printers.Count) stampanti, $($inv.Jobs.Count) job, $($inv.OrphanDrivers.Count) driver orfani"
    Write-AuditEntry -Action 'diagnose.complete' -Result 'Success' -Reason "$($inv.Printers.Count) printers, $($inv.Jobs.Count) jobs"
}

function _Start-Timer {
    if ($script:WorkState.Timer) { try { $script:WorkState.Timer.Stop() } catch {} }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:WorkState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null
        $diagnose = $null; $repair = $null
        while ($script:WorkQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Log' {
                    Append-Log $msg.Level $msg.Message
                    Write-AppLog -Level $msg.Level -Message $msg.Message
                    # Etichetta l'azione con il job reale ('diagnose' o 'repair'):
                    # prima era sempre 'repair.step', quindi anche gli avvisi
                    # emessi durante la diagnosi read-only finivano nell'audit
                    # come passi di riparazione, falsando la cronologia.
                    Write-AuditEntry -Action ("{0}.step" -f $script:WorkState.Job) -Result $msg.Level -Reason $msg.Message
                }
                'DiagnoseDone' { $diagnose = $msg; $done = $true }
                'RepairDone'   { $repair = $msg; $done = $true }
                'Error'        { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        $redrained = $false
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
        } elseif ($diagnose) {
            _Apply-DiagnoseResult $diagnose.Svc $diagnose.Inv
        } elseif ($repair) {
            $c.lblStatus.Text = "Riparazione completata. Backup: $($repair.Result.BackupPath)"
            Write-AuditEntry -Action 'repair.complete' -Result 'Success' -Reason $repair.Result.BackupPath
            Show-MessageBox -Message "Riparazione completata.`nBackup salvato in:`n$($repair.Result.BackupPath)" -Title "Successo" -Icon Information
            # Annulla va spento PRIMA del return: altrimenti resta cliccabile
            # durante la ri-diagnosi e imposta Cancel su uno stato condiviso che
            # in quella fase nessuno legge, restando poi sporco.
            if ($c.btnCancel) { $c.btnCancel.IsEnabled = $false }
            $script:WorkState.Cancel = $false
            Run-Diagnose  # ri-pull stato post-repair
            return        # btnRepair/Diagnose IsEnabled gestiti da Run-Diagnose stessa
        }
        $c.btnDiagnose.IsEnabled = $true
        $c.btnRepair.IsEnabled   = $isAdmin
        if ($c.btnCancel) { $c.btnCancel.IsEnabled = $false }
        $script:WorkState.Cancel = $false
    })
    $timer.Start()
}

function Run-Repair {
    if (-not (Test-IsAdmin)) {
        Show-MessageBox -Message "Devi lanciare come amministratore per risolvere." -Icon Warning
        return
    }

    # Inventario dall'ultima diagnosi (Add_Loaded ne esegue sempre una all'avvio):
    # richiamare Get-SpoolerInventory qui congelava la finestra 5-15s sul thread
    # UI, prima ancora di mostrare la richiesta di conferma.
    if (-not $script:LastInventory) {
        Show-MessageBox -Message "Esegui prima la Diagnosi: serve a sapere cosa verrà toccato." -Title "Diagnosi mancante" -Icon Information
        return
    }

    # Avviso job in coda
    $jobsCount = @($script:LastInventory.Jobs).Count
    if ($jobsCount -gt 0 -and $c.chkClearQueue.IsChecked) {
        $r = Show-MessageBox -Message "Ci sono $jobsCount job in coda. Procedendo verranno CANCELLATI.`n`nContinuare?" -Title "Job in coda" -Buttons YesNo -Icon Warning
        if ($r -ne 'Yes') {
            $c.lblStatus.Text = "Operazione annullata dall'utente."
            Write-AuditEntry -Action 'repair.cancelled' -Result 'Warning' -Reason "$jobsCount job in coda, utente ha annullato"
            return
        }
    }

    # Se chiesto rimozione driver orfani, anteprima della LISTA esatta che sarà rimossa.
    $orphanDetail = ''
    if ($c.chkRemoveOrphan.IsChecked) {
        # Dall'inventario in cache, campo RemovableOrphanDrivers (blacklist di
        # sistema già applicata): È esattamente cio' che Repair-Spooler
        # rimuovera'. Usare OrphanDrivers elencherebbe anche driver che restano.
        $removable = @($script:LastInventory.RemovableOrphanDrivers)
        if ($removable.Count -eq 0) {
            $orphanDetail = "- Driver orfani: NESSUNO (driver di sistema esclusi automaticamente)`n"
        } else {
            $names = ($removable | Select-Object -First 8 -ExpandProperty Name) -join "`n    "
            $more  = if ($removable.Count -gt 8) { "`n    ...e altri $($removable.Count - 8)" } else { '' }
            $orphanDetail = "- Rimozione driver orfani ($($removable.Count)):`n    $names$more`n"
        }
    }

    $confirm = Show-MessageBox -Message "Verrà eseguito:`n- Backup stato spooler in data\backups\`n- Stop spooler`n$(if ($c.chkClearQueue.IsChecked) { "- Svuota coda PRINTERS`n" })$orphanDetail- Restart spooler`n`nProcedere?" -Title "Conferma riparazione" -Buttons YesNo -Icon Warning
    if ($confirm -ne 'Yes') {
        $c.lblStatus.Text = "Operazione annullata."
        Write-AuditEntry -Action 'repair.cancelled' -Result 'Warning'
        return
    }

    if ($script:WorkState.PS) { return }
    $c.btnRepair.IsEnabled = $false
    $c.btnDiagnose.IsEnabled = $false
    $c.lblStatus.Text = "Riparazione in corso... (la rimozione driver si può interrompere con 'Annulla')"
    $script:WorkState.Cancel = $false
    if ($c.btnCancel) { $c.btnCancel.IsEnabled = $true }
    $c.txtLog.Text = ""
    Write-AuditEntry -Action 'repair.start' -Result 'Info'

    $junk = $null; while ($script:WorkQueue.TryDequeue([ref]$junk)) {}

    $vars = @{
        ClearQueue   = [bool]$c.chkClearQueue.IsChecked
        RemoveOrphan = [bool]$c.chkRemoveOrphan.IsChecked
        BackupDir    = (Join-Path $ProjectDir "data\backups")
        # I nomi ESATTI mostrati nella conferma: il worker rimuoverà solo questi.
        ApprovedOrphans = @($script:LastInventory.RemovableOrphanDrivers | ForEach-Object { $_.Name })
    }
    _Start-Worker -Job 'repair' -Vars $vars -Script {
        Import-Module $ModulePath -Force
        $logCb = { param($lvl,$msg) $Queue.Enqueue([pscustomobject]@{ Type='Log'; Level=$lvl; Message=$msg }) }
        try {
            $cancelCb = { return $State.Cancel }
            $r = Repair-Spooler -ClearQueue $ClearQueue -RemoveOrphanDrv $RemoveOrphan -BackupDir $BackupDir `
                                -Log $logCb -CancelCheck $cancelCb -ApprovedOrphanNames $ApprovedOrphans
            $Queue.Enqueue([pscustomobject]@{ Type='RepairDone'; Result=$r })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    }
    _Start-Timer
}

$c.btnDiagnose.Add_Click({ Run-Diagnose })
$c.btnRepair.Add_Click(  { Run-Repair })
if ($c.btnCancel) {
    $c.btnCancel.Add_Click({
        # Interrompe solo la fase di rimozione driver: stop/svuota/restart dello
        # spooler non sono interrompibili, fermarsi lì lascerebbe il sistema di
        # stampa inutilizzabile.
        $script:WorkState.Cancel = $true
        $c.btnCancel.IsEnabled = $false
        $c.lblStatus.Text = "Interruzione richiesta: lo spooler verrà comunque riavviato correttamente."
        Write-AuditEntry -Action 'repair.cancel_requested' -Result 'Warning'
    })
}

$c.btnTestPrint.Add_Click({
    $sel = $c.lvPrinters.SelectedItem
    if (-not $sel) {
        Show-MessageBox -Message "Seleziona prima una stampante nella tab 'Stampanti'." -Icon Information
        return
    }
    try {
        # Il nome stampante NON è un dato fidato: chi controlla un print server
        # a cui il PC è connesso lo sceglie. Concatenandolo in una stringa di
        # argomenti, una virgoletta chiude il parametro e permette di iniettare
        # switch di PrintUIEntry — fra cui /if, che installa una stampante da un
        # .inf arbitrario, e un .inf può eseguire comandi. Questo processo gira
        # ELEVATO, quindi il bersaglio è di valore.
        # Doppia difesa: whitelist sui caratteri + percorso assoluto di rundll32
        # (con il nome nudo Start-Process cerca anche nella working directory,
        # che start.bat imposta sulla cartella del tool).
        if ($sel.Name -match '["|&<>^%`$]') {
            Show-MessageBox -Icon Warning -Title "Nome stampante non valido" -Message (
                "Il nome di questa stampante contiene caratteri non ammessi e la pagina di prova " +
                "non verrà inviata:`n`n$($sel.Name)`n`n" +
                "Un nome del genere è anomalo e può indicare una stampante pubblicata in modo malevolo.")
            Write-AppLog -Level Warning -Message "Pagina di prova rifiutata, nome sospetto: $($sel.Name)"
            Write-AuditEntry -Action 'testprint.rejected' -Target $sel.Name -Result 'Warning' -Reason 'Caratteri non ammessi nel nome'
            return
        }
        $rundll = Join-Path $env:SystemRoot 'System32\rundll32.exe'
        Start-Process $rundll -ArgumentList @('printui.dll,PrintUIEntry', '/k', '/n', $sel.Name)
        Write-AuditEntry -Action 'testprint' -Target $sel.Name -Result 'Info'
    } catch {
        Show-MessageBox -Message "Errore lancio test stampa: $($_.Exception.Message)" -Icon Error
    }
})

$w.Add_Loaded({ Run-Diagnose })
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 07-SpoolerDoctor", 'OK', 'Error') | Out-Null
}
