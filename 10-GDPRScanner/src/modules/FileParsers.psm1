# FileParsers.psm1 — estrae testo da file vari per scansione GDPR (read-only)

# Limite di decompressione. ZipArchiveEntry.Length e' la dimensione DECOMPRESSA
# dichiarata nell'header: un .xlsx di pochi MB puo' dichiararne (ed espanderne)
# vari GB e far morire il runspace. I documenti Office reali stanno molto sotto
# questa soglia; oltre, il file viene segnalato come non analizzabile.
$script:MaxEntryBytes = 80MB

function Read-ZipEntryText {
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.Length -gt $script:MaxEntryBytes) {
        throw ("Contenuto compresso troppo grande ({0} MB decompressi): possibile zip bomb." -f [math]::Round($Entry.Length/1MB))
    }
    $r = New-Object IO.StreamReader($Entry.Open(), [Text.Encoding]::UTF8)
    try { return $r.ReadToEnd() } finally { $r.Close() }
}
function Get-TextFileContent {
    param([string]$Path)
    try {
        return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    } catch {
        try { return [IO.File]::ReadAllText($Path) } catch { return '' }
    }
}

function Get-DocxText {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $sb = New-Object System.Text.StringBuilder
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
        if ($entry) {
            $xml = Read-ZipEntryText -Entry $entry
            # Word spezza abitualmente una parola su piu' <w:t> (correzioni,
            # formattazione parziale, rsid). Concatenandoli con uno SPAZIO un
            # codice fiscale diventava "RSSMRA85 M01H501Z" e non veniva piu'
            # riconosciuto: il documento risultava pulito.
            # Quindi: dentro lo stesso paragrafo i run si uniscono SENZA
            # separatore; il separatore si mette al cambio di paragrafo.
            # I <w:rPh> (guide fonetiche giapponesi) vanno esclusi: non sono
            # testo del documento e inquinerebbero il contenuto.
            $xmlNoPh = [regex]::Replace($xml, '<w:rPh\b.*?</w:rPh>', '', 'Singleline')
            foreach ($para in [regex]::Matches($xmlNoPh, '<w:p\b.*?</w:p>', 'Singleline')) {
                $buf = New-Object System.Text.StringBuilder
                foreach ($m in [regex]::Matches($para.Value, '<w:t[^>]*>(.*?)</w:t>', 'Singleline')) {
                    $null = $buf.Append($m.Groups[1].Value)
                }
                # tab e break dentro il paragrafo separano parole diverse
                $txt = $buf.ToString()
                if ($txt) { $null = $sb.Append($txt).Append("`n") }
            }
            # Testo fuori da <w:p> (rari, es. caselle di testo): recuperato a parte
            $outside = [regex]::Replace($xmlNoPh, '<w:p\b.*?</w:p>', '', 'Singleline')
            foreach ($m in [regex]::Matches($outside, '<w:t[^>]*>(.*?)</w:t>', 'Singleline')) {
                $null = $sb.Append($m.Groups[1].Value).Append(' ')
            }
        }
        $zip.Dispose()
    } catch {
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            Write-AppLog -Level Warning -Message ("Parsing DOCX fallito '{0}': {1}" -f $Path, $_.Exception.Message)
        }
    }
    return $sb.ToString()
}

function Get-XlsxText {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $sb = New-Object System.Text.StringBuilder
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)

        # 1. shared strings
        $strings = @()
        $ssEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/sharedStrings.xml' } | Select-Object -First 1
        if ($ssEntry) {
            $xml = Read-ZipEntryText -Entry $ssEntry
            # Si itera per <si> (shared item), NON per <t>: una cella con
            # formattazione mista contiene piu' <r><t> dentro lo STESSO <si>.
            # Contando i <t> l'array slittava e da quel punto in poi ogni indice
            # t="s" puntava alla stringa sbagliata: bastava una parola in
            # grassetto per rendere illeggibile tutto il resto del foglio.
            foreach ($si in [regex]::Matches($xml, '<si\b.*?</si>', 'Singleline')) {
                # esclude le guide fonetiche <rPh>, che non sono contenuto
                $siXml = [regex]::Replace($si.Value, '<rPh\b.*?</rPh>', '', 'Singleline')
                $buf = New-Object System.Text.StringBuilder
                foreach ($m in [regex]::Matches($siXml, '<t[^>]*>(.*?)</t>', 'Singleline')) {
                    $null = $buf.Append($m.Groups[1].Value)
                }
                $strings += $buf.ToString()
            }
        }

        # 2. sheets cells
        foreach ($e in $zip.Entries) {
            if ($e.FullName -like 'xl/worksheets/sheet*.xml') {
                $xml = Read-ZipEntryText -Entry $e
                # Il tipo cella si estrae in DUE passaggi, non con un gruppo
                # opzionale nella stessa regex: con '<c[^>]*?(?:t="(\w+)")?[^>]*>'
                # il gruppo opzionale matcha sempre vuoto e [^>]* si mangia t="s",
                # quindi $type restava '' e per ogni cella testo veniva emesso
                # l'INDICE numerico invece della stringa condivisa. Risultato: un
                # xlsx con anagrafiche (CF, IBAN, email) risultava pulito.
                # (?:\s*<f...>...</f>)? : le celle CALCOLATE hanno <f> (formula)
                # prima di <v>. Senza questo ramo opzionale una colonna "Codice
                # fiscale" generata con CONCATENA o CERCA.VERT veniva ignorata
                # del tutto e il file risultava pulito.
                foreach ($m in [regex]::Matches($xml, '<c\b[^>]*>(?:\s*<f[^>]*>.*?</f>|\s*<f[^>]*/>)?\s*<v>(.*?)</v>', 'Singleline')) {
                    $cellTag = $m.Value
                    $val     = $m.Groups[1].Value
                    if ($cellTag -match '\st="s"') {
                        $idx = 0
                        if ([int]::TryParse($val, [ref]$idx) -and $idx -ge 0 -and $idx -lt $strings.Count) {
                            $null = $sb.Append($strings[$idx]).Append(' ')
                        }
                    } else {
                        # t="str" (formula), t="n"/assente (numero), t="b", ecc.
                        $null = $sb.Append($val).Append(' ')
                    }
                }
                # Inline strings (t="is"): testo dentro la cella, non in sharedStrings.
                foreach ($m in [regex]::Matches($xml, '<c\b[^>]*t="inlineStr"[^>]*>\s*<is>(.*?)</is>', 'Singleline')) {
                    foreach ($tm in [regex]::Matches($m.Groups[1].Value, '<t[^>]*>(.*?)</t>', 'Singleline')) {
                        $null = $sb.Append($tm.Groups[1].Value).Append(' ')
                    }
                }
            }
        }
        $zip.Dispose()
    } catch {
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            Write-AppLog -Level Warning -Message ("Parsing XLSX fallito '{0}': {1}" -f $Path, $_.Exception.Message)
        }
    }
    return $sb.ToString()
}

function Get-FileTextContent {
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    switch ($ext) {
        '.txt'  { return Get-TextFileContent $Path }
        '.csv'  { return Get-TextFileContent $Path }
        '.log'  { return Get-TextFileContent $Path }
        '.ini'  { return Get-TextFileContent $Path }
        '.eml'  { return Get-TextFileContent $Path }
        '.html' { return Get-TextFileContent $Path }
        '.htm'  { return Get-TextFileContent $Path }
        '.xml'  { return Get-TextFileContent $Path }
        '.json' { return Get-TextFileContent $Path }
        '.docx' { return Get-DocxText $Path }
        '.xlsx' { return Get-XlsxText $Path }
        default { return '' }
    }
}

function Get-SupportedExtensions {
    return @('.txt','.csv','.log','.ini','.eml','.html','.htm','.xml','.json','.docx','.xlsx')
}

Export-ModuleMember -Function Get-TextFileContent, Get-DocxText, Get-XlsxText, Get-FileTextContent, Get-SupportedExtensions
