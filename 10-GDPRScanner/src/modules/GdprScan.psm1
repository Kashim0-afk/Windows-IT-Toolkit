# GdprScan.psm1 — orchestratore scansione GDPR su cartella

# Pattern ottimizzati per evitare match generici. Validati con checksum dove possibile.
$script:Patterns = @{
    # Omocodia: quando due persone generano lo stesso CF, l'Agenzia delle Entrate
    # sostituisce le cifre con le lettere L M N P Q R S T U V. Test-CodiceFiscale
    # gestisce già la conversione, ma la vecchia regex con \d secco non faceva
    # mai arrivare quei codici al validatore: falso negativo silenzioso.
    # Il checksum finale scarta comunque i falsi positivi.
    'CF'    = '\b[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z]\b'
    'PIVA'  = '\b\d{11}\b'
    'IBAN'  = '\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b'
    'CARTA' = '\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}\b'
    'EMAIL' = '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'
}

function Find-SensitiveData {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string[]]$Types = @('CF','PIVA','IBAN','CARTA','EMAIL')
    )
    $hits = @{}
    foreach ($t in $Types) {
        $hits[$t] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($t in $Types) {
        $rx = $script:Patterns[$t]
        if (-not $rx) { continue }
        # NON $matches: e' la variabile automatica riempita da -match. I
        # validatori chiamati nello switch usano -match nel proprio scope, ma si
        # evita comunque di ombreggiare l'automatica qui, per coerenza con la
        # stessa regola gia' applicata in Get-AppxPresent (09-Decrapifier).
        $rxMatches = [regex]::Matches($Text, $rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $rxMatches) {
            $val = $m.Value
            $valid = switch ($t) {
                'CF'    { Test-CodiceFiscale $val }
                'PIVA'  { Test-PartitaIva $val }
                'IBAN'  { Test-Iban $val }
                'CARTA' { Test-LuhnCard $val }
                'EMAIL' { $true }  # nessun checksum standard
            }
            if ($valid) { $hits[$t].Add($val) | Out-Null }
        }
    }
    return $hits
}

function Invoke-FolderScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Types = @('CF','PIVA','IBAN','CARTA','EMAIL'),
        [int]$MaxFileSizeMB = 50,
        [scriptblock]$Progress = $null,
        [scriptblock]$ItemFound = $null,
        [scriptblock]$CancelCheck = $null,
        [bool]$SkipSystemFolders = $true,
        # Callback di log verso la UI. NON si può usare Write-AppLog qui: questa
        # funzione gira in un runspace che importa solo Validators/FileParsers/
        # GdprScan, mai Logging.psm1, quindi le guardie
        # `if (Get-Command Write-AppLog)` erano sempre false e TUTTI i messaggi
        # sugli scarti erano codice morto. Intanto la UI dichiarava all'utente
        # che i file non leggibili erano "elencati nel log".
        [scriptblock]$Log = $null,
        # Riferimento per restituire i conteggi degli scarti al chiamante.
        [hashtable]$Stats = $null
    )

    if (-not (Test-Path $Path)) { throw "Cartella non esistente: $Path" }
    $exts = Get-SupportedExtensions

    # Esclusione cartelle di sistema: evita falsi positivi e scansioni di ore
    # quando un utente punta accidentalmente a C:\ o a una root.
    $excludeRegex = '(?i)\\(Windows|Program Files|Program Files \(x86\)|ProgramData\\Microsoft|\$Recycle\.Bin|\$WinREAgent|\$SysReset|System Volume Information)(\\|$)'

    # -Attributes !ReparsePoint: senza questo la ricorsione ATTRAVERSA junction e
    # symlink. Una junction Documenti\backup -> \\server\riservato (creabile da
    # utente standard) portava lo scan fuori dal perimetro scelto dal tecnico,
    # indicizzando in un report dati di un'altra share. Variante peggiore:
    # junction ricorsiva = scansione che non termina.
    # Il confronto finale su FullName blocca comunque qualunque uscita dal ramo.
    $rootFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')

    # ENUMERAZIONE IN STREAMING, non materializzata.
    # Prima l'intera lista veniva costruita con @(Get-ChildItem -Recurse | Where...)
    # PRIMA di iniziare: su C:\Users erano minuti in cui la barra restava a 0, la
    # status bar non cambiava e soprattutto il pulsante Annulla non aveva alcun
    # effetto, perché CancelCheck veniva interrogato solo dopo. Ora l'utente
    # viene informato durante l'enumerazione e può interromperla.
    if ($Progress) { & $Progress 0 0 "Conteggio dei file in $Path..." }

    # Walk esplicito cartella per cartella con uno stack.
    # NON si puo' usare "foreach ($x in (Get-ChildItem -Recurse ...))": la
    # sotto-espressione fra parentesi viene valutata COMPLETAMENTE prima che il
    # ciclo inizi, quindi l'annullamento restava insensibile per tutta
    # l'enumerazione (misurato: ~58s su una cartella utente reale).
    # Directory.EnumerateFiles e' lazy e qui e' racchiuso per singola cartella,
    # cosi' una cartella non accessibile non interrompe l'intera scansione.
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seen = 0
    $dirSkipped = 0
    $tooBig = 0
    $cancelledDuringEnum = $false
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootFull)

    while ($stack.Count -gt 0) {
        if ($CancelCheck -and (& $CancelCheck)) { $cancelledDuringEnum = $true; break }
        $dir = $stack.Pop()

        # Sottocartelle (saltando i reparse point: junction/symlink porterebbero
        # fuori dal perimetro scelto, o in ricorsione infinita)
        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $di = New-Object System.IO.DirectoryInfo($sub)
                    if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    # L'esclusione si applica al percorso RELATIVO alla radice scelta,
                    # non a quello assoluto: puntando lo scan su
                    # C:\Program Files\Gestionale\Archivio ogni file matchava
                    # $excludeRegex e il verdetto era "nessun dato personale trovato"
                    # senza aver analizzato nulla.
                    $rel = $sub.Substring([Math]::Min($rootFull.Length, $sub.Length))
                    if ($SkipSystemFolders -and ($rel -match $excludeRegex)) { continue }
                    # Contenimento esplicito: è la difesa che il commento più sopra
                    # dichiarava e che in realtà non esisteva nel codice.
                    if (-not ([IO.Path]::GetFullPath($sub)).StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $stack.Push($sub)
                } catch { $dirSkipped++ }
            }
        } catch {
            # Cartella non enumerabile (accesso negato, path troppo lungo):
            # va CONTATA, non ignorata in silenzio. Prima spariva un intero
            # sottoalbero e il tecnico leggeva comunque "scan completato".
            $dirSkipped++
            if ($Log) { & $Log 'Warning' ("Cartella non analizzata '{0}': {1}" -f $dir, $_.Exception.Message) }
        }

        try {
            foreach ($fp in [System.IO.Directory]::EnumerateFiles($dir)) {
                $seen++
                if (($seen % 500) -eq 0) {
                    if ($CancelCheck -and (& $CancelCheck)) { $cancelledDuringEnum = $true; break }
                    if ($Progress) { & $Progress 0 0 "Ricerca file: $seen esaminati, $($files.Count) da analizzare..." }
                }
                $ext = [System.IO.Path]::GetExtension($fp).ToLower()
                if ($exts -notcontains $ext) { continue }
                $relF = $fp.Substring([Math]::Min($rootFull.Length, $fp.Length))
                if ($SkipSystemFolders -and ($relF -match $excludeRegex)) { continue }
                if (-not ([IO.Path]::GetFullPath($fp)).StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $fi = New-Object System.IO.FileInfo($fp)
                if (($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                # File oltre il limite: NON è "pulito", è non analizzato. Un CSV
                # di anagrafiche da 80 MB spariva senza che nulla lo segnalasse.
                if (($fi.Length / 1MB) -ge $MaxFileSizeMB) {
                    $tooBig++
                    if ($Log) { & $Log 'Warning' ("File troppo grande, NON analizzato: {0} ({1} MB)" -f $fp, [math]::Round($fi.Length/1MB)) }
                    continue
                }
                $files.Add($fi)
            }
        } catch { }
        if ($cancelledDuringEnum) { break }
    }

    $total = $files.Count
    $count = 0
    $skipped = 0
    $unreadable = 0
    $results = @()
    $progressEvery = if ($total -gt 1000) { [Math]::Max(1, [int]($total / 200)) } else { 1 }

    if ($cancelledDuringEnum) { return $results }

    foreach ($f in $files) {
        $count++
        if ($CancelCheck -and (& $CancelCheck)) { break }
        if ($Progress -and (($count % $progressEvery -eq 0) -or ($count -eq $total))) {
            & $Progress $count $total $f.FullName
        }

        try {
            $text = Get-FileTextContent -Path $f.FullName
            if ([string]::IsNullOrEmpty($text)) {
                # I parser gestiscono le proprie eccezioni e restituiscono stringa
                # VUOTA: senza questo ramo un .docx/.xlsx protetto da password —
                # cioè proprio il file dove finisce l'anagrafica — veniva
                # classificato come pulito. Un documento Office realmente vuoto è
                # raro, quindi contarlo fra i non verificati è la scelta prudente.
                if ($f.Extension -match '(?i)\.(docx|xlsx|docm|xlsm)$') {
                    $unreadable++
                    if ($Log) { & $Log 'Warning' ("Contenuto non estraibile (protetto da password o danneggiato), NON verificato: {0}" -f $f.FullName) }
                }
                continue
            }

            $hits = Find-SensitiveData -Text $text -Types $Types
            $totalHits = 0
            foreach ($t in $Types) { $totalHits += $hits[$t].Count }
            if ($totalHits -eq 0) { continue }

            $sample = @{}
            foreach ($t in $Types) {
                if ($hits[$t].Count -gt 0) {
                    $sample[$t] = ($hits[$t] | Select-Object -First 3 | ForEach-Object { Mask-Sensitive $_ }) -join ', '
                }
            }

            $entry = [pscustomobject]@{
                File         = $f.FullName
                SizeKB       = [math]::Round($f.Length / 1KB, 1)
                Extension    = $f.Extension
                CF           = $hits['CF'].Count
                PIVA         = $hits['PIVA'].Count
                IBAN         = $hits['IBAN'].Count
                CARTA        = $hits['CARTA'].Count
                EMAIL        = $hits['EMAIL'].Count
                Total        = $totalHits
                ExamplesMasked = ($sample.Keys | ForEach-Object { "${_}: $($sample[$_])" }) -join ' | '
            }
            $results += $entry
            if ($ItemFound) { & $ItemFound $entry }
        } catch {
            # Mai ingoiare in silenzio: un file saltato per errore di parsing
            # veniva conteggiato come "pulito" e il tecnico leggeva "scan
            # completato". In uno strumento di compliance è un falso negativo
            # invisibile. Registriamo e contiamo gli scarti.
            $skipped++
            if ($Log) { & $Log 'Warning' ("File non analizzato '{0}': {1}" -f $f.FullName, $_.Exception.Message) }
        }
    }

    $notVerified = $skipped + $dirSkipped + $tooBig + $unreadable
    if ($notVerified -gt 0 -and $Log) {
        & $Log 'Warning' ("NON verificati: $skipped file illeggibili, $unreadable protetti/vuoti, $tooBig oltre ${MaxFileSizeMB}MB, $dirSkipped cartelle inaccessibili.")
    }
    if ($Stats) {
        $Stats['Skipped']     = $skipped
        $Stats['DirSkipped']  = $dirSkipped
        $Stats['TooBig']      = $tooBig
        $Stats['Unreadable']  = $unreadable
        $Stats['NotVerified'] = $notVerified
        $Stats['Analyzed']    = $count
    }

    return $results
}

Export-ModuleMember -Function Find-SensitiveData, Invoke-FolderScan
