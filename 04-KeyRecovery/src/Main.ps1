# Main.ps1 — 04-KeyRecovery
# Recupero chiavi locali. Read-only. Solo con consenso.

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
Import-Module (Join-Path $ScriptDir "modules\KeyRecovery.psm1") -Force

$logPath  = Join-Path $ProjectDir "data\logs\key-recovery.log"
$auditDir = Join-Path $ProjectDir "data\audit"
Initialize-AppLog   -Path $logPath
Initialize-AppAudit -AuditDir $auditDir -AppName "04-KeyRecovery"

# Elevazione richiesta all'AVVIO, prima di caricare la UI: così il tecnico
# decide subito invece di scoprire a metà lavoro che l'azione principale è
# disabilitata. Se accetta, questa istanza esce e riparte quella elevata.
if (Request-AdminElevation -ScriptPath (Join-Path $ScriptDir 'Main.ps1') `
                           -ToolName "04-KeyRecovery" -Required $false `
                           -Reason "la chiave di ripristino BitLocker e le password delle reti WiFi salvate da altri utenti") {
    Write-AppLog -Level Info -Message "Riavvio come amministratore richiesto dall'utente"
    exit
}
$xamlPath  = Join-Path $ScriptDir "MainWindow.xaml"
$themePath = Join-Path $SharedDir "assets\Theme.xaml"

$ui = Import-XamlWindow -XamlPath $xamlPath -ThemePath $themePath
if (-not $ui -or -not $ui.Window) { throw "Caricamento XAML fallito (file: $xamlPath)" }
$w  = $ui.Window
$c  = $ui.Controls

$c.lblSubtitle.Text = "Recupera le chiavi presenti su questo PC prima di una reinstallazione. Non modifica nulla, nessun dato esce dal PC. | PC: $env:COMPUTERNAME | Utente: $env:USERNAME"
$script:IsAdmin = Test-IsAdmin
Set-ReadOnlyExtrasBanner -Window $w -BannerBorder $c.brdAdminBanner -BannerText $c.lblAdminWarn `
                         -IsAdmin $script:IsAdmin `
                         -Extras "chiave di ripristino BitLocker e profili WiFi di tutti gli utenti"

# btnElevate: visibile solo se non admin. BitLocker recovery key e profili
# WiFi "tutti gli utenti" richiedono privilegi elevati.
if (-not $script:IsAdmin) {
    $c.btnElevate.Visibility = 'Visible'
    $c.btnElevate.Add_Click({
        $scriptPath = Join-Path $ScriptDir 'Main.ps1'
        if (Restart-AsAdmin -ScriptPath $scriptPath) { $w.Close() }
    })
}

Write-AppLog -Level Info -Message "Avvio Key Recovery"
$script:LastResult = $null

function Confirm-Consent {
    $msg = "Confermi di avere il CONSENSO ESPLICITO del proprietario di questo PC per recuperare i seguenti dati sensibili?`n`n" +
           "  - Chiave di ripristino BitLocker (per ogni volume cifrato)`n" +
           "  - Password reti WiFi salvate (in chiaro)`n" +
           "  - Product Key Windows OEM / digital license`n`n" +
           "Output salvato solo in locale ($ProjectDir\data\reports), mai trasmesso.`n`n" +
           "Premi 'Si' SOLO se autorizzato."
    $r = Show-MessageBox -Message $msg -Title "Conferma consenso" -Buttons YesNo -Icon Warning
    return ($r -eq 'Yes')
}

function Update-Status { param([string]$T) Invoke-OnUI -Window $w -Action { $c.lblStatus.Text = $T } }

function Format-WindowsResult($win) {
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("=== Windows ===")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[AFFIDABILE] OEM Key (BIOS, valida per reinstall su stesso hardware):")
    $null = $sb.AppendLine("  $(if ($win.OEMKeyBIOS) { $win.OEMKeyBIOS } else { '(non disponibile - PC non OEM o BIOS senza key embedded)' })")
    $null = $sb.AppendLine("")
    if ($win.License) {
        $null = $sb.AppendLine("Stato licenza corrente (sempre da SoftwareLicensingProduct):")
        $null = $sb.AppendLine("  Prodotto:       $($win.License.ProductName)")
        $null = $sb.AppendLine("  Descrizione:    $($win.License.Description)")
        $null = $sb.AppendLine("  Partial key:    $($win.License.PartialKey)")
        $null = $sb.AppendLine("  License status: $($win.License.LicenseStatus)")
        $null = $sb.AppendLine("  Channel:        $($win.License.ChannelType)")
        $null = $sb.AppendLine("")
    }
    $null = $sb.AppendLine("[NON AFFIDABILE su Win10/11 con digital license] Decoder DigitalProductId (legacy):")
    $null = $sb.AppendLine("  $(if ($win.KeyFromReg) { $win.KeyFromReg } else { '(non disponibile)' })")
    $null = $sb.AppendLine("  ATTENZIONE: questo valore è calcolato da DigitalProductId (registry) con un")
    $null = $sb.AppendLine("  algoritmo legacy Win7/8. Su Windows 10/11 attivati con account Microsoft o")
    $null = $sb.AppendLine("  digital entitlement la chiave NON è più archiviata in plaintext: il")
    $null = $sb.AppendLine("  decoder restituisce un valore che NON corrisponde alla licenza reale.")
    $null = $sb.AppendLine("  USA la OEM Key sopra, oppure 'Partial key' come riferimento.")
    return $sb.ToString()
}

# Pattern runspace (vedi memoria WPF+PS runspace): Invoke-FullRecovery contiene
# netsh wlan export (~2-5s) + Get-BitLockerVolume (~5s timeout da non-admin per
# volume) + Get-CimInstance, totale 7-15s di freeze. Lo spostiamo in runspace.
$script:RecoveryQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
$script:RecoveryState = [hashtable]::Synchronized(@{
    PS = $null; RS = $null; Async = $null; Timer = $null
})

function Start-Recovery {
    if (-not (Confirm-Consent)) {
        Update-Status "Consenso negato. Recovery annullato."
        Write-AppLog -Level Warning -Message "Consenso negato"
        Write-AuditEntry -Action 'consent.denied' -Result 'Warning'
        return
    }
    if ($script:RecoveryState.PS) { return }  # già in corso

    Write-AuditEntry -Action 'consent.granted' -Result 'Info'
    $c.btnRecover.IsEnabled = $false
    Update-Status "Recovery in corso..."
    Write-AuditEntry -Action 'recovery.start' -Result 'Info'

    $junk = $null; while ($script:RecoveryQueue.TryDequeue([ref]$junk)) {}

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('ModulePath', (Join-Path $ScriptDir 'modules\KeyRecovery.psm1'))
    $rs.SessionStateProxy.SetVariable('Queue', $script:RecoveryQueue)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        Import-Module $ModulePath -Force
        try {
            $r = Invoke-FullRecovery
            $Queue.Enqueue([pscustomobject]@{ Type='Done'; Result=$r })
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Type='Error'; Message=$_.Exception.Message })
        }
    })
    $script:RecoveryState.PS    = $ps
    $script:RecoveryState.RS    = $rs
    $script:RecoveryState.Async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:RecoveryState.Timer = $timer
    $timer.Add_Tick({
        $msg = $null; $done = $false; $errMsg = $null; $r = $null
        $redrained = $false
        while ($script:RecoveryQueue.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'Done'  { $r = $msg.Result; $done = $true }
                'Error' { $errMsg = $msg.Message; $done = $true }
            }
        }
        # Watchdog: se il worker muore prima di accodare Done/Error, senza questo
        # controllo il timer girerebbe all'infinito con la UI bloccata.
        if (-not $done) {
            if ($script:RecoveryState.Async -and $script:RecoveryState.Async.IsCompleted) {
                # ridrena prima di dichiarare il fallimento: il worker puo' aver
                # accodato il risultato nell'istante fra l'ultimo TryDequeue e
                # questo test, e senza questo secondo giro un'operazione riuscita
                # verrebbe segnalata come fallita.
                $again = $null
                while ($script:RecoveryQueue.TryDequeue([ref]$again)) { $msg = $again; $redrained = $true }
                if ($redrained) { return }
                $errMsg = "Il processo in background è terminato senza restituire un risultato."
                $done = $true
            } else { return }
        }
        $st = $script:RecoveryState
        $st.Timer.Stop()
        try { $st.PS.EndInvoke($st.Async) | Out-Null } catch { Write-AppLog -Level Error -Message ("Worker: " + $_.Exception.Message) }
        foreach ($e in $st.PS.Streams.Error) { Write-AppLog -Level Warning -Message ("Worker (non-terminante): " + $e.ToString()) }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close()   } catch { }
        $st.PS = $null; $st.RS = $null; $st.Async = $null

        if ($errMsg) {
            Update-Status "Errore: $errMsg"
            Write-AppLog -Level Error -Message $errMsg
            Write-AuditEntry -Action 'recovery.error' -Result 'Failure' -Reason $errMsg
            Show-ErrorBox -Message $errMsg -Context "Il recupero delle chiavi non è stato completato." -Title "Errore recovery"
        } else {
            $script:LastResult = $r
            $c.txtWin.Text = Format-WindowsResult $r.Windows
            $c.lvWifi.ItemsSource = $r.WiFi
            $c.lblCounter.Text = "Profili WiFi: $(@($r.WiFi).Count)"
            Set-EmptyState -Placeholder $c.lblEmptyWifi -ListControl $c.lvWifi -Count @($r.WiFi).Count `
                           -Text "Nessun profilo WiFi salvato su questo PC."
            Update-Status "Recovery completato. Windows OEM key: $(if ($r.Windows.OEMKeyBIOS) { 'OK' } else { 'N/D' }) | Profili WiFi: $($r.WiFi.Count)"
            Write-AppLog -Level Success -Message "Recovery completato: WiFi=$($r.WiFi.Count)"
            Write-AuditEntry -Action 'recovery.complete' -Result 'Success' -Reason "WiFi=$($r.WiFi.Count), OEM=$([bool]$r.Windows.OEMKeyBIOS)"
        }
        $c.btnRecover.IsEnabled = $true
    })
    $timer.Start()
}

function Save-Report {
    param([ValidateSet('json','txt')][string]$Format)
    if (-not $script:LastResult) { Show-MessageBox -Message "Esegui prima il recovery." -Icon Information; return }
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $outDir "keys-${env:COMPUTERNAME}-$stamp.$Format"

    # Product key, PSK WiFi e chiavi BitLocker in chiaro: cartella e file vanno
    # irrigiditi PRIMA della scrittura, e a ogni export (non solo alla prima
    # creazione della cartella, com'era prima).
    $protected = New-ProtectedFile -Path $outFile
    if (-not $protected) {
        $go = Show-MessageBox -Buttons YesNo -Icon Warning -Title "Permessi non ristretti" -Message (
            "NON è stato possibile limitare i permessi del file:`n$outFile`n`n" +
            "Il report contiene product key, password WiFi e chiavi BitLocker IN CHIARO e sarebbe " +
            "leggibile da altri utenti di questo PC.`n`nSalvare comunque?")
        if ($go -ne 'Yes') {
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            Write-AppLog -Level Warning -Message "Export annullato: ACL non applicabile su $outFile"
            Write-AuditEntry -Action "export.$Format" -Target $outFile -Result 'Warning' -Reason 'Annullato: ACL non applicabile'
            return
        }
        Write-AppLog -Level Error -Message "ACL non applicata su $outFile (export forzato dall'utente)"
        Write-AuditEntry -Action 'export.acl_failed' -Target $outFile -Result 'Warning'
    }

    if ($Format -eq 'json') {
        $script:LastResult | ConvertTo-Json -Depth 8 | Out-File $outFile -Encoding UTF8
    } else {
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine("Key Recovery Report")
        $null = $sb.AppendLine("Generated: $($script:LastResult.Timestamp)")
        $null = $sb.AppendLine("Computer:  $($script:LastResult.Computer)")
        $null = $sb.AppendLine("User:      $($script:LastResult.User)")
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine((Format-WindowsResult $script:LastResult.Windows))
        $null = $sb.AppendLine("=== WiFi Profiles ($($script:LastResult.WiFi.Count)) ===")
        foreach ($p in $script:LastResult.WiFi) {
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("Profile:  $($p.Profile)")
            $null = $sb.AppendLine("  SSID:           $($p.SSID)")
            $null = $sb.AppendLine("  Authentication: $($p.Authentication)")
            $null = $sb.AppendLine("  Cipher:         $($p.Cipher)")
            $null = $sb.AppendLine("  Password:       $($p.Password)")
        }
        $sb.ToString() | Out-File $outFile -Encoding UTF8
    }
    Write-AppLog -Level Success -Message "Report $Format`: $outFile"
    Write-AuditEntry -Action "export.$Format" -Target $outFile -Result 'Success'
    $r = Show-MessageBox -Message "Report salvato:`n$outFile`n`nAprire la cartella?" -Buttons YesNo -Icon Information
    if ($r -eq 'Yes') { Start-Process explorer.exe "/select,`"$outFile`"" }
}

$c.btnRecover.Add_Click(    { Start-Recovery })
$c.btnExportJson.Add_Click( { Save-Report -Format 'json' })
$c.btnExportTxt.Add_Click(  { Save-Report -Format 'txt' })
$c.btnOpenFolder.Add_Click({
    $outDir = Join-Path $ProjectDir "data\reports"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    # Se la cartella nasce da questo pulsante resterebbe con ACL ereditate,
    # e i report con chiavi in chiaro la troverebbero già esistente.
    $null = Protect-FileOwnerOnly -Path $outDir
    Start-Process explorer.exe $outDir
})

$w.Add_Closing({
    if ($script:RecoveryState.Timer) { try { $script:RecoveryState.Timer.Stop() } catch {} }
    if ($script:RecoveryState.PS)    { try { $script:RecoveryState.PS.Stop() } catch {}; try { $script:RecoveryState.PS.Dispose() } catch {} }
    if ($script:RecoveryState.RS)    { try { $script:RecoveryState.RS.Close() } catch {} }
    Close-AppAudit; Write-AppLog -Level Info -Message "Chiusura applicazione"
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
    [System.Windows.MessageBox]::Show($errMsg, "Errore fatale - 04-KeyRecovery", 'OK', 'Error') | Out-Null
}
