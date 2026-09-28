# Common.psm1 — utility generiche

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# SID che possono legittimamente scrivere in un percorso da cui si eleva.
# ALLOW-LIST, non blacklist: vedi la nota in Test-PathTrustedForElevation.
$script:TrustedWriterSids = @(
    'S-1-5-18'                                   # LOCAL SYSTEM
    'S-1-5-32-544'                               # BUILTIN\Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # NT SERVICE\TrustedInstaller
    'S-1-3-0'                                    # CREATOR OWNER (risolto a runtime dall'owner)
    'S-1-5-32-549'                               # Server Operators
)

function Test-PathTrustedForElevation {
    # Verifica che il codice che stiamo per eseguire come amministratore non sia
    # modificabile da un utente non privilegiato. Se lo fosse, l'elevazione
    # eseguirebbe codice arbitrario con privilegi elevati: UAC mostra
    # powershell.exe firmato Microsoft e il tecnico accetta in buona fede.
    #
    # ALLOW-LIST e non blacklist di SID "a rischio". La versione precedente
    # cercava Everyone/Users/Authenticated Users e lasciava passare tutto il
    # resto: bypass banale sfruttando l'ereditarietà CREATOR OWNER. L'ACL di
    # default di C:\ concede a Users "crea cartelle" e a CREATOR OWNER
    # FullControl sui figli, quindi un utente standard che crea C:\UTILITIES
    # ottiene una ACE con IL PROPRIO SID — non uno dei quattro cercati — e il
    # controllo dava Trusted=$true. Verificato sperimentalmente.
    #
    # Si controlla anche l'OWNER: su Windows il proprietario detiene
    # implicitamente WRITE_DAC e può concedersi FullControl in qualsiasi
    # momento, quindi un owner non fidato vanifica qualunque DACL.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # Percorsi aggiuntivi da verificare (moduli condivisi, XAML): vengono
        # caricati dall'istanza elevata, quindi contano quanto lo script stesso.
        # XamlReader::Load non è markup inerte: istanzia tipi arbitrari.
        [string[]]$AlsoVerify = @()
    )

    # Qualunque diritto che consenta di sostituire o alterare il contenuto,
    # o di riscrivere la DACL per ottenerlo.
    $R = [System.Security.AccessControl.FileSystemRights]
    $writeMask = $R::WriteData -bor $R::AppendData -bor $R::WriteAttributes -bor
                 $R::WriteExtendedAttributes -bor $R::Delete -bor
                 $R::DeleteSubdirectoriesAndFiles -bor $R::ChangePermissions -bor
                 $R::TakeOwnership -bor $R::Write -bor $R::Modify -bor $R::FullControl

    function _sidOf($idRef) {
        try { return $idRef.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return '' }
    }

    # Perimetro: il file, e TUTTI gli antenati fino alla radice del volume.
    # Un antenato con permessi di scrittura permette di sostituire l'intero
    # sottoalbero, quindi controllare solo file e cartella padre non basta.
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($p in (@($Path) + $AlsoVerify)) {
        if (-not $p) { continue }
        $cur = try { [IO.Path]::GetFullPath($p) } catch { $p }
        while ($cur) {
            if (-not $targets.Contains($cur)) { $targets.Add($cur) }
            $next = Split-Path -Parent $cur
            if (-not $next -or $next -eq $cur) { break }
            $cur = $next
        }
    }

    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        try {
            $acl = Get-Acl -LiteralPath $t -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Trusted = $false; Reason = "ACL non leggibile su $t" }
        }

        # 1. Owner: chi possiede l'oggetto può sempre riaprirsi i permessi.
        $ownerSid = _sidOf $acl.Owner
        if ($script:TrustedWriterSids -notcontains $ownerSid) {
            return [pscustomobject]@{
                Trusted = $false
                Reason  = "'$($acl.Owner)' è proprietario di $t e può modificarne i permessi in qualsiasi momento"
            }
        }

        # 2. DACL: nessun principal fuori dall'allow-list può scrivere.
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($ace.FileSystemRights -band $writeMask) -eq 0) { continue }
            $sid = _sidOf $ace.IdentityReference
            if ($script:TrustedWriterSids -notcontains $sid) {
                return [pscustomobject]@{
                    Trusted = $false
                    Reason  = "'$($ace.IdentityReference)' può scrivere in $t"
                }
            }
        }
    }
    return [pscustomobject]@{ Trusted = $true; Reason = '' }
}

# Test-PathOwnerOnlyAccess: verifica di CONFIDENZIALITÀ, distinta da quella di
# integrità fatta da Test-PathTrustedForElevation.
#
# Le due domande sono diverse e non vanno confuse:
#   - elevazione  -> "chi può MODIFICARE il codice?"  L'utente corrente NON è
#                    fidato: se può scrivere, può iniettare codice.
#   - report      -> "chi può LEGGERE il file?"       L'utente corrente È il
#                    destinatario legittimo: deve poterlo leggere.
# Usare il controllo di elevazione per verificare un report faceva fallire
# sempre la protezione, con un falso avviso "ACL non applicata" a ogni export.
function Test-PathOwnerOnlyAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Ok = $false; Reason = 'percorso inesistente' } }
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch { return [pscustomobject]@{ Ok = $false; Reason = "ACL non leggibile: $($_.Exception.Message)" } }

    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($me, 'S-1-5-18', 'S-1-5-32-544')   # utente corrente, SYSTEM, Administrators

    if ($acl.AreAccessRulesProtected -ne $true) {
        return [pscustomobject]@{ Ok = $false; Reason = "ereditarietà ancora attiva su $Path" }
    }
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = try { $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { '' }
        # QUALUNQUE diritto (anche sola lettura) di un principal estraneo è una fuga.
        if ($allowed -notcontains $sid) {
            return [pscustomobject]@{ Ok = $false; Reason = "'$($ace.IdentityReference)' ha ancora accesso a $Path" }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Restart-AsAdmin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        # Se $true (default) blocca l'elevazione quando la cartella degli script
        # è scrivibile da utenti standard. Passare $false solo consapevolmente.
        [bool]$RequireTrustedPath = $true
    )
    if (Test-IsAdmin) { return $false }

    if ($RequireTrustedPath) {
        # Si verifica anche TUTTO ciò che l'istanza elevata caricherà: i moduli
        # condivisi e i due XAML. XamlReader::Load istanzia tipi arbitrari, quindi
        # un MainWindow.xaml sostituibile equivale a codice sostituibile.
        $srcDir  = Split-Path -Parent $ScriptPath
        $rootDir = Split-Path -Parent (Split-Path -Parent $srcDir)
        $also = @(
            (Join-Path $rootDir '_shared\modules\Common.psm1')
            (Join-Path $rootDir '_shared\modules\GUI.psm1')
            (Join-Path $rootDir '_shared\modules\Logging.psm1')
            (Join-Path $rootDir '_shared\modules\Audit.psm1')
            (Join-Path $rootDir '_shared\assets\Theme.xaml')
            (Join-Path $srcDir  'MainWindow.xaml')
        )
        foreach ($m in (Get-ChildItem (Join-Path $srcDir 'modules') -Filter *.psm1 -ErrorAction SilentlyContinue)) {
            $also += $m.FullName
        }

        $trust = Test-PathTrustedForElevation -Path $ScriptPath -AlsoVerify $also
        if (-not $trust.Trusted) {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            # NON un blocco secco: la suite vive spesso sul Desktop del tecnico,
            # dove il proprietario è il tecnico stesso. In quel caso il rischio
            # esiste (malware che gira come l'utente può alterare gli script prima
            # dell'elevazione) ma la decisione spetta a chi conosce il PC. Si
            # espone il motivo esatto e si chiede una conferma consapevole.
            $msg = "AVVISO DI SICUREZZA prima di elevare i privilegi.`n`n" +
                   "$($trust.Reason)`n`n" +
                   "Chi può scrivere in quel percorso può modificare gli script di questa suite. " +
                   "Eseguendoli come amministratore, quel codice girerebbe con privilegi elevati: " +
                   "UAC mostrerebbe solo 'powershell.exe' firmato Microsoft.`n`n" +
                   "Percorso sicuro consigliato: C:\Program Files\UTILITIES (scrivibile solo dagli amministratori).`n`n" +
                   "Elevare comunque?`n" +
                   "  SI = procedo, mi assumo il rischio su questo PC`n" +
                   "  NO = annullo (consigliato sui PC dei clienti)"
            $ans = [System.Windows.MessageBox]::Show($msg, "Percorso non protetto", 'YesNo', 'Warning')
            if ($ans -ne 'Yes') {
                if (Get-Command Write-AuditEntry -ErrorAction SilentlyContinue) {
                    Write-AuditEntry -Action 'elevation.blocked' -Target $ScriptPath -Result 'Warning' -Reason $trust.Reason
                }
                return $false
            }
            if (Get-Command Write-AuditEntry -ErrorAction SilentlyContinue) {
                Write-AuditEntry -Action 'elevation.forced' -Target $ScriptPath -Result 'Warning' -Reason $trust.Reason
            }
        }
    }

    # -WindowStyle Hidden: nasconde la console PowerShell host. Senza, la GUI WPF
    # gira dentro la console e chiudere la console termina anche la GUI.
    # ArgumentList come ARRAY: il quoting lo fa .NET, niente argument injection
    # da percorsi o argomenti con spazi/virgolette.
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', $ScriptPath
    ) + $Arguments
    try {
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden
    } catch [System.ComponentModel.Win32Exception] {
        # L'utente ha premuto "No" sul prompt UAC. Senza questo catch l'eccezione
        # esce dall'handler Add_Click e diventa un crash WPF non gestito.
        return $false
    } catch {
        return $false
    }
    return $true
}

# Request-AdminElevation: da chiamare all'AVVIO di Main.ps1, PRIMA di caricare
# lo XAML (così non lampeggia una finestra che verrà subito chiusa).
#
# Chiede all'utente se riavviare come amministratore quando i privilegi servono
# davvero. Prima l'elevazione era solo un pulsante dentro la finestra: il tecnico
# apriva il tool, premeva l'azione principale e scopriva solo allora che era
# disabilitata.
#
#   Required = $true  -> senza admin la funzione PRINCIPALE non è utilizzabile
#                        (07 riparazione spooler, 09 rimozione AppX).
#   Required = $false -> il tool funziona comunque, da admin raccoglie di più.
#
# Ritorna $true se è stata avviata l'istanza elevata: il chiamante DEVE uscire
# subito senza aprire la finestra.
function Request-AdminElevation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ToolName,
        [bool]$Required = $false,
        # Cosa si perde restando utente standard. Frase concreta, non generica.
        [string]$Reason = ''
    )
    if (Test-IsAdmin) { return $false }

    # Interruttore per esecuzioni non presidiate (test automatici, deploy via
    # script): salta la finestra di dialogo e prosegue senza elevare. Il tool
    # resta comunque funzionante in modalità ridotta e il banner continua a
    # segnalare cosa non è disponibile.
    if ($env:UTILITIES_NO_ELEVATE_PROMPT -eq '1') { return $false }

    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

    if ($Required) {
        $msg = "$ToolName richiede privilegi di AMMINISTRATORE per funzionare.`n`n" +
               $(if ($Reason) { "$Reason`n`n" } else { '' }) +
               "Vuoi riavviarlo ora come amministratore?`n`n" +
               "SI  = Windows chiedera' conferma (UAC) e il tool si riaprira' con tutti i permessi.`n" +
               "NO  = il tool si apre comunque, ma le azioni che modificano il sistema resteranno disabilitate."
        $title = "Privilegi di amministratore necessari"
    } else {
        $msg = "$ToolName può raccogliere più informazioni se eseguito come amministratore.`n`n" +
               $(if ($Reason) { "Senza privilegi elevati non saranno disponibili: $Reason`n`n" } else { '' }) +
               "Vuoi riavviarlo ora come amministratore?`n`n" +
               "SI = Windows chiedera' conferma (UAC) e il tool si riaprira'.`n" +
               "NO = il tool si apre subito, con i dati accessibili all'utente corrente."
        $title = "Eseguire come amministratore?"
    }

    $answer = [System.Windows.MessageBox]::Show($msg, $title, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return $false }

    return (Restart-AsAdmin -ScriptPath $ScriptPath)
}

function Protect-FileOwnerOnly {
    # Restringe l'ACL di un file/cartella: rimuove l'ereditarietà e concede
    # accesso solo a utente corrente + SYSTEM + Administrators. Serve per output
    # con dati sensibili (chiavi, password) su PC multi-utente: impedisce ad altri
    # account standard di leggere il file. NB: il contenuto resta in chiaro (per
    # scenari di recovery il file DEVE essere leggibile dal proprietario), la
    # protezione è a livello di permessi NTFS, non di cifratura.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        # SOLO la sezione Access (DACL). GetAccessControl() senza argomenti
        # include anche la SACL di audit, e riscriverla richiede il privilegio
        # SeSecurityPrivilege: sulle chiamate ripetute Set-Acl falliva con
        # PrivilegeNotHeldException pur non dovendo toccare alcun audit rule.
        $acl = $item.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        # $true = proteggi (no ereditarietà), $false = non copiare le regole ereditate
        $acl.SetAccessRuleProtection($true, $false)

        # SetAccessRuleProtection rimuove SOLO l'ereditarietà: le ACE ESPLICITE
        # già presenti sopravvivono. Su una cartella creata in precedenza (o
        # copiata da un archivio) può esserci una ACE esplicita Users:FullControl
        # che lascerebbe i report leggibili a tutti. Azzeriamo la DACL.
        foreach ($ace in @($acl.Access)) { $null = $acl.RemoveAccessRuleSpecific($ace) }

        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow  = [System.Security.AccessControl.AccessControlType]::Allow
        $inherit = if ($item.PSIsContainer) {
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        } else {
            [System.Security.AccessControl.InheritanceFlags]::None
        }
        $prop = [System.Security.AccessControl.PropagationFlags]::None
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, $rights, $inherit, $prop, $allow)))
        foreach ($wk in @([System.Security.Principal.WellKnownSidType]::LocalSystemSid,
                          [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid)) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($wk, $null)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rights, $inherit, $prop, $allow)))
        }
        # Proprietà all'utente corrente quando non lo è già.
        # Il proprietario detiene WRITE_DAC implicito: se la cartella è stata
        # PRE-CREATA da un altro utente, riscriverne la DACL non basta, quello se
        # la riconcede quando vuole. Caso reale: data\backups e data\reports non
        # esistono finché il tool non gira, quindi un utente standard può crearle
        # per primo e restarne proprietario.
        try {
            $meSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $curOwner = try { $acl.GetOwner([System.Security.Principal.SecurityIdentifier]) } catch { $null }
            if ($curOwner -and $curOwner.Value -ne $meSid.Value) { $acl.SetOwner($meSid) }
        } catch {
            # Prendere la proprietà richiede SeTakeOwnership o esserlo già:
            # se non si può, si prosegue con la sola DACL (e la verifica finale
            # segnalerà comunque l'esito al chiamante).
        }

        # SetAccessControl (API .NET) invece di Set-Acl: scrive SOLO le sezioni
        # effettivamente modificate. Set-Acl tenta di riscrivere anche la SACL e
        # falliva con PrivilegeNotHeldException (SeSecurityPrivilege) sulle
        # chiamate ripetute su una cartella già protetta.
        $item.SetAccessControl($acl)

        # Verifica di CONFIDENZIALITÀ, non quella di elevazione: se resta un
        # principal estraneo con un qualunque diritto — anche di sola lettura —
        # l'irrigidimento è fallito e il chiamante DEVE saperlo, perché questi
        # file contengono chiavi e password in chiaro.
        $check = Test-PathOwnerOnlyAccess -Path $Path
        if (-not $check.Ok) {
            Write-Warning "ACL applicata ma ancora permissiva su ${Path}: $($check.Reason)"
            return $false
        }
        return $true
    } catch {
        Write-Warning "ACL non ristretta su ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function New-ProtectedFile {
    # Crea il file VUOTO e ne restringe subito l'ACL, PRIMA che vi venga scritto
    # contenuto sensibile. Evita la finestra TOCTOU del pattern
    # "Out-File poi Protect-FileOwnerOnly", durante la quale il contenuto è
    # leggibile secondo le ACL ereditate.
    # Ritorna $true se il file è protetto, $false altrimenti (il chiamante
    # deve avvisare l'utente prima di scriverci dati sensibili).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($dir) { $null = Protect-FileOwnerOnly -Path $dir }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType File -Path $Path -Force | Out-Null
    return (Protect-FileOwnerOnly -Path $Path)
}

function Clear-SensitiveDirectory {
    # Sovrascrive con zeri il contenuto dei file prima di cancellarli, poi
    # rimuove la cartella. Usato per le temp che contengono PSK WiFi in chiaro:
    # un Remove-Item normale fa solo unlink e il contenuto resta recuperabile.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $len = $_.Length
                if ($len -gt 0) { [System.IO.File]::WriteAllBytes($_.FullName, (New-Object byte[] $len)) }
            } catch { }
        }
    } catch { }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function ConvertTo-HtmlSafe {
    # Escaping HTML per qualunque valore interpolato in un report.
    # Vive in _shared perché serve sia a 03-PCAudit che a 10-GDPRScanner.
    param($Text)
    if ($null -eq $Text) { return '' }
    return ([string]$Text).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-OEMVendor {
    $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $sys) { return [pscustomobject]@{ Vendor='Unknown'; Model=''; Raw='' } }
    $mfr   = ($sys.Manufacturer | Out-String).Trim()
    $model = ($sys.Model        | Out-String).Trim()
    $vendor = switch -Wildcard ($mfr) {
        "Dell*"      { "Dell" }
        "HP*"        { "HP" }
        "Hewlett*"   { "HP" }
        "Lenovo*"    { "Lenovo" }
        "ASUS*"      { "ASUS" }
        "Acer*"      { "Acer" }
        "MSI*"       { "MSI" }
        "Microsoft*" { "Microsoft" }
        "Apple*"     { "Apple" }
        "Samsung*"   { "Samsung" }
        "*Toshiba*"  { "Toshiba" }
        "*Fujitsu*"  { "Fujitsu" }
        "VMware*"    { "VMware" }
        "innotek*"   { "VirtualBox" }
        default      { $mfr }
    }
    return [pscustomobject]@{ Vendor=$vendor; Model=$model; Raw=$mfr }
}

function Get-OEMUpdateToolUrl {
    param([string]$Vendor)
    switch ($Vendor) {
        "Dell"      { "https://www.dell.com/support/kbdoc/it-it/000177325/dell-command-update" }
        "HP"        { "https://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html" }
        "Lenovo"    { "https://support.lenovo.com/it/it/solutions/ht037099" }
        "ASUS"      { "https://www.asus.com/it/support/Download-Center/" }
        "Acer"      { "https://www.acer.com/it-it/support" }
        "MSI"       { "https://www.msi.com/support" }
        "Microsoft" { "https://support.microsoft.com/surface" }
        default     { $null }
    }
}

Export-ModuleMember -Function Test-IsAdmin, Restart-AsAdmin, Test-PathTrustedForElevation, `
                              Test-PathOwnerOnlyAccess, Request-AdminElevation, `
                              Protect-FileOwnerOnly, New-ProtectedFile, Clear-SensitiveDirectory, `
                              ConvertTo-HtmlSafe, Get-OEMVendor, Get-OEMUpdateToolUrl
