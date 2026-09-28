# BackupParsers.psm1 — parser log dei principali sistemi di backup (read-only)

function Read-XmlSafely {
    # Caricamento XML con DTD ed entità esterne DISABILITATE.
    #
    # `$doc.XmlResolver = $null` NON basta e trae in inganno: XmlDocument.Load()
    # su uno Stream si costruisce internamente un XmlTextReader con il PROPRIO
    # resolver, e l'entità esterna viene risolta lo stesso. Verificato su questa
    # macchina: con XmlResolver null il valore di una <!ENTITY SYSTEM "file://...">
    # veniva comunque letto dal disco.
    #
    # I log di backup sono file scritti da software di terze parti in cartelle
    # sotto %ProgramData% che spesso ereditano permessi di scrittura per Users:
    # sono input NON FIDATO. Senza questa protezione un utente standard poteva
    # piazzare un XML con un'entità esterna e far leggere al tool file arbitrari
    # (il contenuto finiva nella UI e nel report), oppure indirizzare una
    # richiesta verso un host remoto (SSRF / leak di hash NTLM via UNC).
    # DtdProcessing=Prohibit blocca anche l'espansione ricorsiva (billion laughs).
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver   = $null
    $settings.MaxCharactersFromEntities = 1024
    $settings.MaxCharactersInDocument   = 50MB

    $reader = [System.Xml.XmlReader]::Create($Stream, $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return $doc
    } finally { $reader.Close() }
}

function Get-MacriumStatus {
    [CmdletBinding()] param()
    $candidates = @(
        "$env:ProgramData\Macrium\Reflect\Logs",
        "C:\ProgramData\Macrium\Reflect\Logs"
    )
    $logDir = $null
    foreach ($p in $candidates) { if (Test-Path $p) { $logDir = $p; break } }
    if (-not $logDir) {
        return [pscustomobject]@{ System='Macrium Reflect'; Installed=$false; Status='Non rilevato'; LastJob=$null; Detail='' }
    }


    # Macrium logs XML: nome file include data
    $xmls = @(Get-ChildItem $logDir -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10)

    if ($xmls.Count -eq 0) {
        return [pscustomobject]@{ System='Macrium Reflect'; Installed=$true; Status='Nessun log'; LastJob=$null; Detail='' }
    }

    $last = $xmls[0]
    $jobStatus = 'Sconosciuto'; $jobTime = $last.LastWriteTime; $size = ''
    try {
        # Macrium XML può essere UTF-8 o UTF-16 LE/BE: lasciamo che il parser
        # XmlDocument rilevi l'encoding dichiarato nel prologo XML caricando
        # via XmlReader sul file (gestione lock-friendly via FileStream sola lettura).
        $fs = [System.IO.File]::Open($last.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $x = Read-XmlSafely -Stream $fs
        } finally { $fs.Dispose() }
        $resultNode = $x.SelectSingleNode("//*[local-name()='Result']")
        if ($resultNode) { $jobStatus = $resultNode.InnerText }
        else {
            $resultNode = $x.SelectSingleNode("//*[local-name()='Status']")
            if ($resultNode) { $jobStatus = $resultNode.InnerText }
        }
    } catch [System.IO.IOException] {
        $jobStatus = 'File in uso (backup in corso?)'
    } catch {
        $jobStatus = "Parse error: $($_.Exception.Message -replace '\r?\n',' ')"
    }

    return [pscustomobject]@{
        System    = 'Macrium Reflect'
        Installed = $true
        Status    = $jobStatus
        LastJob   = $jobTime
        Detail    = "Log: $($last.FullName)"
    }
}

function Get-VeeamAgentStatus {
    [CmdletBinding()] param()
    $candidates = @(
        "$env:ProgramData\Veeam\Endpoint",
        "$env:ProgramData\Veeam\Backup",
        "C:\ProgramData\Veeam"
    )
    $found = $false
    foreach ($p in $candidates) { if (Test-Path $p) { $found = $true; break } }
    if (-not $found) {
        return [pscustomobject]@{ System='Veeam Agent'; Installed=$false; Status='Non rilevato'; LastJob=$null; Detail='' }
    }

    # Event log Veeam Endpoint
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName='Veeam Agent'; StartTime=(Get-Date).AddDays(-30) } -MaxEvents 50 -ErrorAction Stop)
    } catch {
        try {
            $events = @(Get-WinEvent -ProviderName 'Veeam Endpoint Backup Service' -MaxEvents 50 -ErrorAction Stop)
        } catch { $events = @() }
    }

    if ($events.Count -eq 0) {
        return [pscustomobject]@{ System='Veeam Agent'; Installed=$true; Status='Nessun evento recente'; LastJob=$null; Detail='' }
    }

    # Si prende l'evento PEGGIORE della finestra, non il più recente.
    # Veeam scrive molti eventi informativi (retention, licenza, "job finished"):
    # con $events[0] bastava un Information subito dopo un fallimento per far
    # risultare OK un backup fallito. Su uno strumento che serve a verificare i
    # backup è il falso negativo peggiore possibile.
    # Level: 1=Critical, 2=Error, 3=Warning, 4=Information (non localizzato).
    $worst = $events | Where-Object { $_.Level -ge 1 -and $_.Level -le 3 } |
             Sort-Object Level | Select-Object -First 1
    $last = if ($worst) { $worst } else { $events[0] }
    $status = switch ([int]$last.Level) {
        1       { 'Failure' }
        2       { 'Failure' }
        3       { 'Warning' }
        default { 'OK' }
    }

    return [pscustomobject]@{
        System    = 'Veeam Agent'
        Installed = $true
        Status    = $status
        LastJob   = $last.TimeCreated
        Detail    = ($last.Message -split "`n")[0]
    }
}

function Get-WindowsBackupStatus {
    [CmdletBinding()] param()
    if (-not (Get-Command Get-WBJob -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ System='Windows Server Backup'; Installed=$false; Status="Modulo non disponibile (È solo su Windows Server)"; LastJob=$null; Detail='' }
    }
    try {
        $jobs = @(Get-WBJob -Previous 5 -ErrorAction SilentlyContinue)
        if ($jobs.Count -eq 0) {
            return [pscustomobject]@{ System='Windows Server Backup'; Installed=$true; Status='Nessun job'; LastJob=$null; Detail='' }
        }
        $last = $jobs[0]
        return [pscustomobject]@{
            System    = 'Windows Server Backup'
            Installed = $true
            Status    = $last.JobState
            LastJob   = $last.StartTime
            Detail    = "Job ID: $($last.JobId)"
        }
    } catch {
        return [pscustomobject]@{ System='Windows Server Backup'; Installed=$true; Status='Errore: ' + $_.Exception.Message; LastJob=$null; Detail='' }
    }
}

function Get-AcronisStatus {
    [CmdletBinding()] param()
    $candidates = @(
        "$env:ProgramData\Acronis",
        "C:\ProgramData\Acronis"
    )
    # Si memorizza il candidato che ha soddisfatto Test-Path, non il primo:
    # riportare sempre $candidates[0] indicava all'utente un percorso che
    # sul suo PC poteva non esistere.
    $foundPath = $null
    foreach ($p in $candidates) { if (Test-Path $p) { $foundPath = $p; break } }
    if (-not $foundPath) {
        return [pscustomobject]@{ System='Acronis'; Installed=$false; Status='Non rilevato'; LastJob=$null; Detail='' }
    }
    return [pscustomobject]@{ System='Acronis'; Installed=$true; Status='Rilevato (parsing log non ancora supportato)'; LastJob=$null; Detail='Cartella rilevata: ' + $foundPath + ' - verifica lo stato dei job dalla console Acronis.' }
}

function Invoke-BackupCheck {
    [CmdletBinding()] param([scriptblock]$Progress = $null)
    $checks = @(
        @{ Name='Macrium';           Cmd={ Get-MacriumStatus } },
        @{ Name='Veeam Agent';       Cmd={ Get-VeeamAgentStatus } },
        @{ Name='Acronis';           Cmd={ Get-AcronisStatus } },
        @{ Name='Windows Server Bk'; Cmd={ Get-WindowsBackupStatus } }
    )
    $results = @()
    $i = 0
    foreach ($ch in $checks) {
        $i++
        if ($Progress) { & $Progress $i $checks.Count $ch.Name }
        try { $results += & $ch.Cmd } catch { $results += [pscustomobject]@{ System=$ch.Name; Installed=$null; Status='Eccezione: ' + $_.Exception.Message; LastJob=$null; Detail='' } }
    }

    # Severity NORMALIZZATA per la UI. I DataTrigger dello XAML confrontavano
    # Status con 'OK'/'Failure'/'Warning', valori prodotti dal solo parser Veeam:
    # un backup Macrium FALLITO ("Backup Failed") o un WSB "Failed" restavano in
    # nero come una riga qualsiasi, cioè l'opposto di quel che serve.
    foreach ($r in $results) {
        $s = [string]$r.Status
        $sev = if ($s -match '(?i)fail|error|errore|fehler|erreur|abort|annull|critic') { 'Failure' }
               elseif ($s -match '(?i)warn|avvis|attenzion') { 'Warning' }
               elseif ($r.Installed -eq $false) { 'NonRilevato' }
               elseif ($s -match '(?i)^ok$|success|completat|riuscit') { 'OK' }
               else { 'Info' }
        $r | Add-Member -NotePropertyName Severity -NotePropertyValue $sev -Force
    }
    return $results
}

Export-ModuleMember -Function Get-MacriumStatus, Get-VeeamAgentStatus, Get-WindowsBackupStatus, Get-AcronisStatus, Invoke-BackupCheck
