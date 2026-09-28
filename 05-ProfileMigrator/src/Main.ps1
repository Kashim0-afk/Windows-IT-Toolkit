# Main.ps1 — 05-ProfileMigrator
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
Import-Module (Join-Path $ScriptDir "modules\ProfileExport.psm1") -Force

Initialize-AppLog   -Path (Join-Path $ProjectDir "data\logs\profile-migrator.log")
Initialize-AppAudit -AuditDir (Join-Path $ProjectDir "data\audit") -AppName "05-ProfileMigrator"

# Elevazione richiesta all'AVVIO, prima di caricare la UI: così il tecnico
# decide subito invece di scoprire a metà lavoro che l'azione principale è
# disabilitata. Se accetta, questa istanza esce e riparte quella elevata.
if (Request-AdminElevation -ScriptPath (Join-Path $ScriptDir 'Main.ps1') `
                           -ToolName "05-ProfileMigrator" -Required $false `
                           -Reason "i profili WiFi di tutti gli utenti e alcune chiavi di registro di sistema") {
    Write-AppLog -Level Info -Message "Riavvio come amministratore richiesto dall'utente"
    exit
}
$ui = Import-XamlWindow -XamlPath (Join-Path $ScriptDir "MainWindow.xaml") -ThemePath (Join-Path $SharedDir "assets\Theme.xaml")
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito" }
$w  = $ui.Window
$c  = $ui.Controls

$script:IsAdmin = Test-IsAdmin
Set-AdminBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                -IsAdmin $script:IsAdmin -Required $false -ToolName "05-ProfileMigrator"

# btnElevate: visibile solo se non admin. Copiare AppData/profili di ALTRI
# utenti (es. migrazione PC condiviso) richiede privilegi elevati.
if (-not $script:IsAdmin) {
    $c.btnElevate.Visibility = 'Visible'
    $c.btnElevate.Add_Click({
        $scriptPath = Join-Path $ScriptDir 'Main.ps1'
        if (Restart-AsAdmin -ScriptPath $scriptPath) { $w.Close() }
    })
}

# Default destinazione: Desktop dell'utente (più visibile e facile da
# raccogliere su USB). Volendo si può cambiare con Sfoglia.
$desktop = [Environment]::GetFolderPath('Desktop')
$defaultDest = Join-Path $desktop ("Migration-{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$c.txtDest.Text = $defaultDest

$c.btnBrowse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = if (Test-Path $c.txtDest.Text) { $c.txtDest.Text } else { Split-Path $c.txtDest.Text -Parent }
    if ($dlg.ShowDialog() -eq 'OK') { $c.txtDest.Text = $dlg.SelectedPath }
})

# Anteprima read-only: enumera quante voci troverebbe ogni categoria
# senza scrivere alcun file. Esecuzione sincrona: i Get-*Summary sono veloci
# (<2s totali). Mostra il risultato nella griglia lvResult.
$c.btnPreview.Add_Click({
    $cats = Get-SelectedCategories
    if ($cats.Count -eq 0) { Show-MessageBox -Message "Seleziona almeno una categoria." -Icon Warning; return }
    $c.btnPreview.IsEnabled = $false
    $c.lblStatus.Text = "Anteprima in corso..."
    Write-AuditEntry -Action 'preview.start' -Result 'Info' -Reason ($cats -join ',')
    try {
        $summary = Invoke-FullExportPreview -Categories $cats
        $display = $summary | ForEach-Object {
            [pscustomobject]@{
                Category    = $_.Category
                Count       = $_.Count
                ItemsJoined = ($_.Items -join ', ')
            }
        }
        $c.lvResult.ItemsSource = $display
        $c.lblCounter.Text = "Voci totali: $((@($display) | Measure-Object Count -Sum).Sum)"
        Set-EmptyState -Placeholder $c.lblEmptyResult -ListControl $c.lvResult -Count @($display).Count `
                       -Text "Nessuna delle categorie selezionate ha prodotto voci da esportare su questo PC."
        $total = ($summary | Measure-Object Count -Sum).Sum
        $c.lblStatus.Text = "Anteprima: $total voci trovate (nessun file scritto). Premi 'Esporta' per salvare davvero."
        Write-AuditEntry -Action 'preview.complete' -Result 'Success' -Reason "$total voci"
    } catch {
        $err = $_.Exception.Message
        $c.lblStatus.Text = "Errore anteprima: $err"
        Write-AppLog -Level Error -Message $err
        Show-MessageBox -Message "Errore anteprima: $err" -Icon Error
    } finally {
        $c.btnPreview.IsEnabled = $true
    }
})

$script:ExportQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:ExportState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null; Dest = ''
})

function Get-SelectedCategories {
    $cats = @()
    if ($c.chkOutlook.IsChecked)  { $cats += 'Outlook' }
    if ($c.chkBrowser.IsChecked)  { $cats += 'Browser' }
    if ($c.chkSMB.IsChecked)      { $cats += 'SMB' }
    if ($c.chkWiFi.IsChecked)     { $cats += 'WiFi' }
    if ($c.chkPrinters.IsChecked) { $cats += 'Printers' }
    return $cats
}

$c.btnExport.Add_Click({
    $cats = Get-SelectedCategories
    if ($cats.Count -eq 0) { Show-MessageBox -Message "Seleziona almeno una categoria." -Icon Warning; return }

    $dest = $c.txtDest.Text.Trim()
    if (-not $dest) { Show-MessageBox -Message "Imposta cartella destinazione." -Icon Warning; return }

    # Blacklist path: rifiuta destinazioni dentro cartelle di sistema per evitare
    # sovrascrittura accidentale di file Windows/Program Files.
    $blockedRoots = @(
        $env:SystemRoot,                      # C:\Windows
        $env:ProgramFiles,                    # C:\Program Files
        ${env:ProgramFiles(x86)},             # C:\Program Files (x86)
        "$env:SystemRoot\System32",
        "$env:SystemRoot\SysWOW64",
        "$env:SystemDrive\Boot",
        "$env:SystemDrive\Recovery"
    )
    $destNorm = $null
    try { $destNorm = [System.IO.Path]::GetFullPath($dest) } catch {
        Show-MessageBox -Message "Destinazione non valida: '$dest' non può essere normalizzata ($($_.Exception.Message))." -Title "Destinazione vietata" -Icon Error
        Write-AuditEntry -Action 'export.dest.blocked' -Target $dest -Result 'Failure' -Reason "GetFullPath fallito: $($_.Exception.Message)"
        return
    }
    # Confronto con il separatore finale: senza, 'C:\Program Files' bloccava
    # anche destinazioni legittime come 'D:\Program Files Backup\Migrazione'
    # (StartsWith su prefisso puro).
    foreach ($root in $blockedRoots) {
        if (-not $root) { continue }
        $rootNorm = $root.TrimEnd('\')
        if ($destNorm.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase) -or
            $destNorm.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Show-MessageBox -Message "Destinazione non consentita: '$dest' È dentro una cartella di sistema ($root). Scegli un'altra cartella (es. Desktop, Documents, una USB)." -Title "Destinazione vietata" -Icon Error
            Write-AuditEntry -Action 'export.dest.blocked' -Target $dest -Result 'Failure' -Reason "Inside $root"
            return
        }
    }
    # Rifiuta anche radici di drive (es. C:\, D:\) - troppo invasivo.
    if ($destNorm -match '^[A-Z]:\\?$') {
        Show-MessageBox -Message "Destinazione non consentita: la radice del drive ($dest) non è un'opzione valida. Crea una sottocartella." -Title "Destinazione vietata" -Icon Error
        return
    }

    # L'export irrigidisce l'ACL della propria cartella (disattiva l'ereditarietà
    # e azzera la DACL). Farlo su una cartella PREESISTENTE scelta con Sfoglia —
    # una condivisa di rete, Documenti, una directory di lavoro — ne romperebbe i
    # permessi per tutti gli altri utenti, in modo silenzioso e permanente.
    # Quindi si esporta SEMPRE in una sottocartella creata da noi, a meno che il
    # percorso indicato non sia già una nostra cartella Migration-*.
    $leaf = Split-Path $destNorm -Leaf
    if ($leaf -notmatch '^Migration-') {
        $dest = Join-Path $destNorm ("Migration-{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $destNorm = [System.IO.Path]::GetFullPath($dest)
        $c.txtDest.Text = $dest
        Write-AppLog -Level Info -Message "Export in sottocartella dedicata: $dest"
    }

    if (Test-Path $dest) {
        $existingItems = @(Get-ChildItem $dest -ErrorAction SilentlyContinue).Count
        if ($existingItems -gt 0) {
            $r = Show-MessageBox -Message "La cartella '$dest' contiene già $existingItems elementi.`n`nContinuare comunque (i file esistenti potrebbero essere SOVRASCRITTI per le categorie selezionate)?" -Buttons YesNo -Icon Warning
            if ($r -ne 'Yes') { return }
        }
    }

    $wifiKeys = [bool]$c.chkWiFiKeys.IsChecked
    if ($cats -contains 'WiFi' -and $wifiKeys) {
        # L'avviso GDPR da solo è un disclaimer: verifichiamo se la destinazione
        # può davvero reggere una ACL. Su FAT32/exFAT (chiavette USB) NO, e le
        # PSK restano leggibili da chiunque infili la chiavetta in un PC.
        $fsType = $null
        try {
            $qualifier = [System.IO.Path]::GetPathRoot($destNorm)
            if ($qualifier -match '^[A-Za-z]:\\$') {
                $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($qualifier.Substring(0,2))'" -ErrorAction SilentlyContinue
                if ($vol) { $fsType = $vol.FileSystem }
            } elseif ($destNorm.StartsWith('\\')) {
                $fsType = 'SMB'
            }
        } catch { }

        $fsWarn = ''
        if ($fsType -and $fsType -ne 'NTFS' -and $fsType -ne 'ReFS') {
            $fsWarn = "`n`nLA DESTINAZIONE è $fsType : su questo filesystem i permessi NTFS non esistono. " +
                      "Le password saranno leggibili da CHIUNQUE colleghi il supporto a un PC. " +
                      "Cifra l'export (7z con password) o usa una destinazione NTFS."
        }

        $r = Show-MessageBox -Buttons YesNo -Icon Warning -Title "Attenzione GDPR" -Message (
            "Stai per esportare le password WiFi IN CHIARO nei file XML.`n`n" +
            "Chiunque acceda all'export potrà leggerle: È un trattamento di dati da giustificare." +
            $fsWarn + "`n`nProcedere?")
        if ($r -ne 'Yes') {
            $wifiKeys = $false
            $c.chkWiFiKeys.IsChecked = $false
        }
    }

    if ($script:ExportState.PS) { return }  # già in corso

    $c.btnExport.IsEnabled = $false
    $c.lblStatus.Text = "Export in corso..."
    Write-AuditEntry -Action 'export.start' -Target $dest -Result 'Info' -Reason "$($cats -join ',') wifiKeys=$wifiKeys"

    # Runspace: Invoke-FullExport può impiegare minuti (copia PST/profili
    # Outlook). Senza runspace la UI si congela completamente.
    $junk = $null; while ($script:ExportQueue.TryDequeue([ref]$junk)) {}

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\ProfileExport.psm1'))
    $rs.SessionStateProxy.SetVariable('LogModule',  (Join-Path $SharedDir 'modules\Logging.psm1'))
    # Log del worker su file DEDICATO: prima worker e thread UI scrivevano
    # entrambi profile-migrator.log e un lock momentaneo faceva saltare
    # Initialize-AppLog nel worker, uccidendo la pipeline senza accodare nulla.
    $rs.SessionStateProxy.SetVariable('LogPath',    (Join-Path $ProjectDir 'data\logs\profile-migrator-worker.log'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:ExportQueue)
    $rs.SessionStateProxy.SetVariable('DestRoot', $dest)
    $rs.SessionStateProxy.SetVariable('Categories', $cats)
    $rs.SessionStateProxy.SetVariable('WiFiKeys', $wifiKeys)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        # TUTTO dentro il try: un fallimento di Import-Module o Initialize-AppLog
        # fuori dal try non accodava né Done né Error e lasciava la UI
        # bloccata per sempre su "Export in corso...".
        $progressCb = {
            param($i,$t,$n)
            $Queue.Enqueue([pscustomobject]@{ Type='Progress'; Step=$i; Total=$t; Name=$n })
        }
        try {
            Import-Module $LogModule  -Force
            Import-Module $ModulePath -Force
            Initialize-AppLog -Path $LogPath   # file dedicato al worker
            $results = Invoke-FullExport -DestRoot $DestRoot -Categories $Categories -WiFiIncludeKeys $WiFiKeys -Progress $progressCb
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; Results=$results })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })
    $script:ExportState.PS    = $ps
    $script:ExportState.RS    = $rs
    $script:ExportState.Async = $ps.BeginInvoke()
    $script:ExportState.Dest  = $dest
    # Serve nel timer per calibrare l'avviso: se l'export contiene PSK in chiaro
    # e l'ACL è fallita, il messaggio deve dirlo esplicitamente.
    $script:ExportState.WiFiKeys = $wifiKeys

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ExportState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null; $results = $null
        $redrained = $false
        while ($script:ExportQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Progress' { $c.lblStatus.Text = "Export $($msg.Name) ($($msg.Step)/$($msg.Total))" }
                'Done'     { $results = $msg.Results; $done = $true }
                'Error'    { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        if (-not $done) {
            if ($script:ExportState.Async -and $script:ExportState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:ExportQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }
        $st = $script:ExportState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null

        if ($errMsg) {
            $c.lblStatus.Text = "Errore: $errMsg"
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'export.error' -Result 'Failure' -Reason $errMsg
            Show-MessageBox -Message "Errore: $errMsg" -Icon Error
        } else {
            # La voce __meta__ trasporta l'esito reale della protezione ACL:
            # va estratta e NON mostrata come categoria in griglia.
            $meta    = @($results | Where-Object { $_.Category -eq '__meta__' })[0]
            $results = @($results | Where-Object { $_.Category -ne '__meta__' })

            $display = $results | ForEach-Object {
                [pscustomobject]@{
                    Category    = $_.Category
                    Count       = $_.Count
                    ItemsJoined = ($_.Items -join ', ')
                }
            }
            $c.lvResult.ItemsSource = $display
            $totalItems = ($results | Measure-Object Count -Sum).Sum
            $emptyCats = @($results | Where-Object { $_.Count -eq 0 } | ForEach-Object { $_.Category })
            $c.lblStatus.Text = "Export completato in '$($st.Dest)'. Elementi totali: $totalItems."
            Write-AppLog -Level Success -Message "Export completato: $totalItems elementi in $($st.Dest)"
            $reason = "$totalItems items"
            if ($emptyCats.Count -gt 0) { $reason += " (categorie vuote: $($emptyCats -join ','))" }
            Write-AuditEntry -Action 'export.complete' -Target $st.Dest -Result 'Success' -Reason $reason

            # Avviso basato sull'ESITO REALE dell'irrigidimento, non sull'euristica
            # preventiva del filesystem: quella non vede ACL negate, mount point,
            # owner ostili o eccezioni. Qui sappiamo com'è andata davvero.
            if ($meta -and -not $meta.Protected) {
                Write-AppLog -Level Error -Message "ACL non applicata su $($st.Dest)"
                Write-AuditEntry -Action 'export.acl_failed' -Target $st.Dest -Result 'Warning'
                Show-MessageBox -Icon Warning -Title "Export NON protetto" -Message (
                    "Export completato in:`n$($st.Dest)`n`n" +
                    "ATTENZIONE: non è stato possibile limitare i permessi della cartella. " +
                    "Il contenuto è leggibile da chiunque acceda a questo percorso o al supporto.`n`n" +
                    "L'export contiene profili Outlook, cronologia di navigazione, mappature di rete" +
                    $(if ($st.WiFiKeys) { " e le PASSWORD WiFi IN CHIARO" } else { "" }) + ".`n`n" +
                    "Cifra la cartella (7-Zip con password) o spostala su un volume NTFS prima di consegnarla.")
            } else {
                Show-MessageBox -Message "Export completato in:`n$($st.Dest)" -Title "Successo" -Icon Information
            }
        }
        $c.btnExport.IsEnabled = $true
    })
    $timer.Start()
})

$c.btnOpenFolder.Add_Click({
    $dest = $c.txtDest.Text.Trim()
    if (-not (Test-Path $dest)) { Show-MessageBox -Message "Cartella non esiste ancora." -Icon Information; return }
    Start-Process explorer.exe $dest
})

$w.Add_Closing({
    if ($script:ExportState.Timer) { try { $script:ExportState.Timer.Stop() } catch {} }
    if ($script:ExportState.PS)    { try { $script:ExportState.PS.Stop() } catch {}; try { $script:ExportState.PS.Dispose() } catch {} }
    if ($script:ExportState.RS)    { try { $script:ExportState.RS.Close() } catch {} }
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 05-ProfileMigrator", 'OK', 'Error') | Out-Null
}
