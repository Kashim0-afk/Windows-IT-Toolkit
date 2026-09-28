# DriverDiscovery.psm1 — scansione PnP device problematici (read-only)

# Codici CM_PROB_* che indicano un driver realmente KO o mancante.
# Esclude di proposito: 22 (disabled by user), 25 (setup in progress),
# 29 (disabled firmware), 53 (waiting for boot service) — non sono guasti.
$script:RealProblemCodes = @(1,10,14,18,19,24,28,31,32,37,38,39,43,52)

# Mappa codice → descrizione italiana breve (Get-PnpDevice.ProblemDescription
# spesso è vuota su Windows ITA, quindi la costruiamo noi).
$script:ProblemMap = @{
    1  = 'Configurazione device non corretta'
    10 = 'Impossibile avviare il dispositivo'
    14 = 'Riavvio richiesto'
    18 = 'Driver da reinstallare'
    19 = 'Registry corrotto per questo device'
    22 = 'Disabilitato manualmente'
    24 = 'Device assente ma censito'
    25 = 'Setup in corso'
    28 = 'Driver non installato'
    29 = 'Disabilitato dal firmware'
    31 = 'Driver non funziona correttamente'
    32 = 'Servizio driver disabilitato'
    37 = 'Inizializzazione driver fallita'
    38 = 'Istanza driver precedente ancora caricata'
    39 = 'Driver corrotto o mancante'
    43 = 'Device fermato per errore segnalato dal driver'
    45 = 'Device non connesso'
    52 = 'Driver non firmato digitalmente'
    53 = 'In attesa avvio servizio'
}

function Get-ProblemDevices {
    [CmdletBinding()]
    param(
        # Default: solo problemi "veri". Con -IncludeAll torna anche disabilitati,
        # SoftwareComponent in Degraded, ecc. (utile per debug)
        [switch]$IncludeAll
    )

    $pnp = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    if (-not $pnp) { return @() }

    if ($IncludeAll) {
        $pnp = $pnp | Where-Object { ($_.Status -ne 'OK') -or ($_.Problem -gt 0) }
    } else {
        # Filtro stretto: solo Problem code "veri".
        # I 'SoftwareComponent' con Problem=0 e Status=Degraded sono rumore
        # registrato da Intel/AMD/Realtek su Windows 11 — vengono esclusi.
        $pnp = $pnp | Where-Object { $_.Problem -in $script:RealProblemCodes }
    }

    $results = @()
    foreach ($d in $pnp) {
        $hwid = $null
        if ($d.HardwareID) { $hwid = ($d.HardwareID | Select-Object -First 1) }
        elseif ($d.CompatibleID) { $hwid = ($d.CompatibleID | Select-Object -First 1) }

        $vendor = ''
        if ($hwid -match 'VEN_([0-9A-F]{4})')      { $vendor = "PCI VEN $($matches[1])" }
        elseif ($hwid -match 'VID_([0-9A-F]{4})')  { $vendor = "USB VID $($matches[1])" }
        elseif ($d.Manufacturer)                   { $vendor = $d.Manufacturer }

        $statusLabel = switch ($d.Status) {
            'Error'    { 'ERRORE' }
            'Degraded' { 'DEGRADO' }
            'Unknown'  { 'IGNOTO' }
            default    { [string]$d.Status }
        }

        # Descrizione problema: preferisci ProblemDescription se presente,
        # altrimenti mappa il codice, altrimenti riporta il codice grezzo.
        $detail = ''
        if ($d.ProblemDescription) {
            $detail = ([string]$d.ProblemDescription).Trim()
        } elseif ($script:ProblemMap.ContainsKey([int]$d.Problem)) {
            $detail = $script:ProblemMap[[int]$d.Problem]
        } elseif ($d.Problem -gt 0) {
            $detail = "Codice problema $($d.Problem)"
        }

        $results += [pscustomobject]@{
            Status     = $statusLabel
            Name       = if ($d.FriendlyName) { ([string]$d.FriendlyName).Trim() } else { '' }
            Class      = if ($d.Class)        { ([string]$d.Class).Trim() }        else { '' }
            Vendor     = $vendor
            Detail     = $detail
            HardwareID = $hwid
            InstanceID = $d.InstanceId
            Problem    = $d.Problem
        }
    }

    return $results | Sort-Object Status, Class, Name
}

function Test-WingetAvailable {
    [CmdletBinding()] param()
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Get-WingetUpgrades {
    [CmdletBinding()]
    param(
        # Default: NON include pacchetti con versione installata sconosciuta.
        # Quei record gonfiano la lista di "aggiornamenti incerti" perché
        # winget non sa se la versione installata è già uguale/superiore.
        [switch]$IncludeUnknown
    )
    if (-not (Test-WingetAvailable)) { return @() }

    # Parser: la riga di trattini in winget moderno è una sola sequenza continua
    # senza separatori; le colonne si ricavano dalle posizioni delle parole nella
    # riga di intestazione (Name|Nome, Id, Version|Versione, Available|Disponibile, Source|Origine).
    try {
        $wgArgs = @('upgrade','--accept-source-agreements')
        if ($IncludeUnknown) { $wgArgs += '--include-unknown' }
        # @(...) obbligatorio: con una sola riga di output winget restituisce una
        # [string], quindi $raw.Length contava i CARATTERI e $raw[$i] iterava sui
        # singoli caratteri. Risultato: nessun match e "0 aggiornamenti" mostrato
        # all'utente al posto dell'errore reale di winget.
        $raw = @(& winget @wgArgs 2>$null)
        $wgExit = $LASTEXITCODE
    } catch {
        # winget ha lanciato un'eccezione (non solo un exit code != 0): segnala
        # il fallimento al chiamante, altrimenti Get-LastWingetExitCode
        # tornerebbe 0 e la UI mostrerebbe "tutto aggiornato" invece dell'errore.
        $script:LastWingetExit = -1
        return @()
    }
    # NIENTE Write-AppLog qui: questa funzione gira in un runspace che importa
    # solo DriverDiscovery.psm1, quindi la guardia `if (Get-Command Write-AppLog)`
    # sarebbe sempre falsa e il messaggio non verrebbe mai scritto (verificato
    # con un runspace reale). L'esito viaggia invece nella variabile di modulo,
    # che il chiamante legge con Get-LastWingetExitCode.
    $script:LastWingetExit = $wgExit
    if (-not $raw -or $raw.Count -eq 0) { return @() }

    # Trova la riga di trattini ('---...---'): l'header è la riga immediatamente sopra.
    $dashIdx = -1
    for ($i = 0; $i -lt $raw.Count; $i++) {
        if ([string]$raw[$i] -match '^-{10,}\s*$') { $dashIdx = $i; break }
    }
    if ($dashIdx -lt 1) { return @() }

    $header = [string]$raw[$dashIdx - 1]
    # Posizioni inizio di ciascuna parola nell'header (non-whitespace preceduto da spazio o inizio riga).
    $colStarts = New-Object System.Collections.Generic.List[int]
    $prev = ' '
    for ($p = 0; $p -lt $header.Length; $p++) {
        $ch = $header[$p]
        if ($ch -ne ' ' -and $prev -eq ' ') { $colStarts.Add($p) }
        $prev = $ch
    }
    if ($colStarts.Count -lt 4) { return @() }

    $results = @()
    for ($i = $dashIdx + 1; $i -lt $raw.Count; $i++) {
        $line = [string]$raw[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Righe di summary/sezioni successive: il parser deve fermarsi qui altrimenti
        # leggerebbe la tabella "richiede targeting esplicito" come ulteriori upgrade.
        # Supporta winget EN + ITA (header locale).
        if ($line -match '^\s*\d+\s+(?:upgrades?|aggiornament|paquet|paket)' -or
            $line -match '^\s*\d+\s+pacchett' -or
            $line -match '^The following packages' -or
            $line -match '^I pacchetti seguenti' -or
            $line -match '^No installed package' -or
            $line -match '^Non e. stato trovato' -or
            $line -match '(?i)pinned packages were excluded' -or
            $line -match '(?i)pacchetti bloccati') { break }

        $cols = @()
        for ($k = 0; $k -lt $colStarts.Count; $k++) {
            $startPos = $colStarts[$k]
            $endPos   = if ($k -lt $colStarts.Count - 1) { $colStarts[$k+1] } else { $line.Length }
            if ($startPos -ge $line.Length) { $cols += ''; continue }
            $len = [Math]::Min($endPos - $startPos, $line.Length - $startPos)
            $cols += $line.Substring($startPos, $len).Trim()
        }
        # Atteso: Name, Id, Current, Available, [Source]
        if ($cols.Count -ge 4 -and $cols[0] -and $cols[1] -and $cols[2] -and $cols[3]) {
            $current = $cols[2]
            # Marca esplicitamente gli aggiornamenti "incerti": versione installata
            # non rilevabile da winget → l'utente deve verificare manualmente.
            $note = ''
            if ($current -match '^(Unknown|Sconosciut|<)') { $note = 'Versione installata sconosciuta' }

            $results += [pscustomobject]@{
                Name      = $cols[0]
                Id        = $cols[1]
                Current   = $current
                Available = $cols[3]
                Source    = if ($cols.Count -ge 5) { $cols[4] } else { '' }
                Note      = $note
            }
        }
    }
    return $results
}

function Get-LastWingetExitCode {
    # Esito dell'ultima esecuzione di winget. Serve al chiamante per distinguere
    # "nessun aggiornamento disponibile" da "winget ha fallito": entrambi i casi
    # producono una lista vuota, ma per il tecnico significano cose opposte.
    if ($null -eq $script:LastWingetExit) { return 0 }
    return $script:LastWingetExit
}

Export-ModuleMember -Function Get-ProblemDevices, Test-WingetAvailable, Get-WingetUpgrades, Get-LastWingetExitCode
