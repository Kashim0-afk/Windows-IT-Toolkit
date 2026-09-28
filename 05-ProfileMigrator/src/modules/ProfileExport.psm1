# ProfileExport.psm1 — export profilo utente per migrazione (v1: solo export)

# Common.psm1 per Protect-FileOwnerOnly (PSK WiFi in chiaro). Import qui e non
# solo in Main.ps1: questo modulo viene caricato dentro un runspace isolato.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_shared\modules\Common.psm1') -DisableNameChecking

function Export-OutlookProfile {
    param([Parameter(Mandatory)][string]$DestRoot)
    $dest = Join-Path $DestRoot 'Outlook'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    # PSTFiles va dichiarato QUI: su [pscustomobject] l'assegnazione di una
    # proprietà inesistente lancia SetValueInvocationException, e siccome
    # Outlook è la prima categoria l'intero export si interrompeva su ogni PC
    # con Outlook installato.
    $info = [pscustomobject]@{ Category='Outlook'; Items=@(); Count=0; PSTFiles=@() }

    # 1. Registry profiles per ogni versione Office
    $regPaths = @(
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles',
        'HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles'
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) {
            $regFile = Join-Path $dest ("registry-" + ($rp -replace '[\\:]','_') + ".reg")
            $regKey = $rp -replace 'HKCU:','HKEY_CURRENT_USER'
            & reg export $regKey $regFile /y *>$null
            if (Test-Path $regFile) { $info.Items += $regFile; $info.Count++ }
        }
    }

    # 2. Signatures
    $sigSrc = "$env:APPDATA\Microsoft\Signatures"
    if (Test-Path $sigSrc) {
        $sigDest = Join-Path $dest 'Signatures'
        Copy-Item -Path $sigSrc -Destination $sigDest -Recurse -Force -ErrorAction SilentlyContinue
        $info.Items += $sigDest
        $info.Count += @(Get-ChildItem $sigSrc -File -Recurse -ErrorAction SilentlyContinue).Count
    }

    # 3. Lista PST/OST nella cartella default
    $defaultDataPath = "$env:LOCALAPPDATA\Microsoft\Outlook"
    if (Test-Path $defaultDataPath) {
        $pstList = @(Get-ChildItem $defaultDataPath -Filter '*.pst' -ErrorAction SilentlyContinue)
        $info.PSTFiles = @($pstList | Select-Object FullName, @{n='SizeMB';e={[math]::Round($_.Length/1MB,1)}}, LastWriteTime)
        if ($pstList.Count -gt 0) {
            $listFile = Join-Path $dest 'pst-list.txt'
            $pstList | ForEach-Object { "$($_.FullName) [$([math]::Round($_.Length/1MB,1)) MB]" } | Out-File $listFile -Encoding UTF8
            $info.Items += $listFile
        }
    }

    return $info
}

function Export-BrowserData {
    param([Parameter(Mandatory)][string]$DestRoot)
    $dest = Join-Path $DestRoot 'Browser'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $info = [pscustomobject]@{ Category='Browser'; Items=@(); Count=0 }

    # Chrome
    $chromeSrc = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    if (Test-Path $chromeSrc) {
        $bookmarksSrc = Join-Path $chromeSrc 'Default\Bookmarks'
        if (Test-Path $bookmarksSrc) {
            Copy-Item $bookmarksSrc (Join-Path $dest 'chrome-bookmarks.json') -Force -ErrorAction SilentlyContinue
            $info.Items += 'chrome-bookmarks.json'
            $info.Count++
        }
    }

    # Edge
    $edgeSrc = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    if (Test-Path $edgeSrc) {
        $bookmarksSrc = Join-Path $edgeSrc 'Default\Bookmarks'
        if (Test-Path $bookmarksSrc) {
            Copy-Item $bookmarksSrc (Join-Path $dest 'edge-bookmarks.json') -Force -ErrorAction SilentlyContinue
            $info.Items += 'edge-bookmarks.json'
            $info.Count++
        }
    }

    # Firefox: cerca profili
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffRoot) {
        $profiles = @(Get-ChildItem $ffRoot -Directory -ErrorAction SilentlyContinue)
        foreach ($p in $profiles) {
            $bookmarksSrc = Join-Path $p.FullName 'places.sqlite'
            if (Test-Path $bookmarksSrc) {
                Copy-Item $bookmarksSrc (Join-Path $dest "firefox-$($p.Name)-places.sqlite") -Force -ErrorAction SilentlyContinue
                $info.Items += "firefox-$($p.Name)-places.sqlite"
                $info.Count++
            }
        }
    }

    return $info
}

function Export-SmbMappings {
    param([Parameter(Mandatory)][string]$DestRoot)
    $dest = Join-Path $DestRoot 'Network'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $info = [pscustomobject]@{ Category='Mappature SMB'; Items=@(); Count=0 }

    $maps = @(Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath, RemotePath, Status)
    if ($maps.Count -gt 0) {
        $out = Join-Path $dest 'smb-mappings.xml'
        $maps | Export-Clixml -Path $out
        $info.Items += $out
        $info.Count = $maps.Count
    }
    return $info
}

function Export-WiFiProfiles {
    param(
        [Parameter(Mandatory)][string]$DestRoot,
        [bool]$IncludeKeys = $false
    )
    $dest = Join-Path $DestRoot 'WiFi'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $info = [pscustomobject]@{ Category='WiFi'; Items=@(); Count=0; IncludeKeys=$IncludeKeys; Protected=$false }
    try {
        if ($IncludeKeys) {
            # Con key=clear gli XML contengono le PSK in chiaro: ACL ristretta
            # PRIMA dell'export. Su volumi non-NTFS (USB FAT32) l'ACL non è
            # applicabile: Protected resta $false e il chiamante avvisa.
            $info.Protected = [bool](Protect-FileOwnerOnly -Path $dest)
            & netsh wlan export profile folder="$dest" key=clear *>$null
            $netshExit = $LASTEXITCODE
            $null = Protect-FileOwnerOnly -Path $dest
        } else {
            & netsh wlan export profile folder="$dest" *>$null
            $netshExit = $LASTEXITCODE
        }
        $exported = @(Get-ChildItem $dest -Filter '*.xml' -ErrorAction SilentlyContinue)
        $info.Count = $exported.Count
        $info.Items = $exported.Name
        # Zero file può voler dire "nessuna rete salvata" oppure "netsh ha
        # fallito": per il tecnico sono cose diverse, e con l'export delle
        # password una svista qui gli fa credere di aver salvato qualcosa.
        if ($netshExit -ne 0 -and $exported.Count -eq 0) {
            $info | Add-Member -NotePropertyName Failed -NotePropertyValue $true -Force
            if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
                Write-AppLog -Level Warning -Message "netsh wlan export ha restituito exit code ${netshExit}: nessun profilo WiFi esportato."
            }
        }
    } catch {
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            Write-AppLog -Level Warning -Message ("Export WiFi fallito: {0}" -f $_.Exception.Message)
        }
    }
    return $info
}

function Export-Printers {
    param([Parameter(Mandatory)][string]$DestRoot)
    $dest = Join-Path $DestRoot 'Printers'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $info = [pscustomobject]@{ Category='Stampanti'; Items=@(); Count=0 }
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, DriverName, PortName, Type, Shared, Published)
    $ports    = @(Get-PrinterPort -ErrorAction SilentlyContinue | Select-Object Name, Description, PortMonitor, PrinterHostAddress, PrinterHostIP)
    if ($printers.Count -gt 0) {
        $printers | Export-Clixml -Path (Join-Path $dest 'printers.xml')
        $ports    | Export-Clixml -Path (Join-Path $dest 'ports.xml')
        $info.Items = @('printers.xml','ports.xml')
        $info.Count = $printers.Count
    }
    return $info
}

function Invoke-FullExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestRoot,
        [string[]]$Categories = @('Outlook','Browser','SMB','WiFi','Printers'),
        [bool]$WiFiIncludeKeys = $false,
        [scriptblock]$Progress = $null
    )
    if (-not (Test-Path $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }

    # ACL sull'INTERA cartella di export, PRIMA della prima categoria.
    # Prima era protetta solo la sottocartella WiFi, ma restavano leggibili da
    # qualunque altro utente locale: i .reg di Outlook (account, server, blob di
    # credenziali), le firme email, places.sqlite di Firefox (cronologia
    # completa), le mappature SMB e manifest.json. Sono dati personali quanto le
    # PSK, e su PC multi-utente erano esposti.
    $rootProtected = [bool](Protect-FileOwnerOnly -Path $DestRoot)

    $results = @()
    $total = $Categories.Count
    $i = 0
    foreach ($cat in $Categories) {
        $i++
        if ($Progress) { & $Progress $i $total $cat }
        $r = switch ($cat) {
            'Outlook'  { Export-OutlookProfile  -DestRoot $DestRoot }
            'Browser'  { Export-BrowserData     -DestRoot $DestRoot }
            'SMB'      { Export-SmbMappings     -DestRoot $DestRoot }
            'WiFi'     { Export-WiFiProfiles    -DestRoot $DestRoot -IncludeKeys $WiFiIncludeKeys }
            'Printers' { Export-Printers        -DestRoot $DestRoot }
        }
        $results += $r
    }

    # Manifest (UTF-8 senza BOM per compatibilità cross-tool)
    $manifest = [pscustomobject]@{
        Timestamp        = (Get-Date)
        SourceComputer   = $env:COMPUTERNAME
        SourceUser       = $env:USERNAME
        WiFiIncludeKeys  = $WiFiIncludeKeys
        Categories       = $results
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    $manifestPath = Join-Path $DestRoot 'manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding $false))

    # Riapplica l'ACL: le sottocartelle create dalle singole categorie ereditano
    # da $DestRoot, ma se la protezione iniziale era fallita (o la cartella è
    # stata creata prima) questo è il secondo tentativo, sul contenuto completo.
    $finalProtected = [bool](Protect-FileOwnerOnly -Path $DestRoot)

    # L'esito viaggia INSIEME ai risultati: prima veniva calcolato e buttato via,
    # e il chiamante non aveva modo di sapere che l'export era leggibile da tutti.
    $results += [pscustomobject]@{
        Category  = '__meta__'
        Count     = 0
        Items     = @()
        Protected = ($rootProtected -and $finalProtected)
        DestRoot  = $DestRoot
    }
    return $results
}

# =============================================================================
# Anteprima read-only: stessi conteggi delle Export-*, MA senza scrivere file.
# Utile per mostrare all'utente cosa troverebbe l'export prima di eseguirlo.
# =============================================================================

function Get-OutlookSummary {
    $info = [pscustomobject]@{ Category='Outlook'; Items=@(); Count=0 }
    foreach ($rp in @('HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles','HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles')) {
        if (Test-Path $rp) {
            $sub = @(Get-ChildItem $rp -ErrorAction SilentlyContinue)
            foreach ($s in $sub) { $info.Items += "Profilo Outlook: $($s.PSChildName) ($rp)"; $info.Count++ }
        }
    }
    if (Test-Path "$env:APPDATA\Microsoft\Signatures") {
        $sigs = @(Get-ChildItem "$env:APPDATA\Microsoft\Signatures" -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($sigs -gt 0) { $info.Items += "$sigs file di firma email"; $info.Count += $sigs }
    }
    if (Test-Path "$env:LOCALAPPDATA\Microsoft\Outlook") {
        $pst = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Outlook" -Filter '*.pst' -ErrorAction SilentlyContinue)
        foreach ($p in $pst) { $info.Items += "PST: $($p.Name) [$([math]::Round($p.Length/1MB,1)) MB]" }
    }
    return $info
}

function Get-BrowserSummary {
    $info = [pscustomobject]@{ Category='Browser'; Items=@(); Count=0 }
    if (Test-Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks")  { $info.Items += 'Chrome bookmarks'; $info.Count++ }
    if (Test-Path "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks") { $info.Items += 'Edge bookmarks';   $info.Count++ }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffRoot) {
        foreach ($p in @(Get-ChildItem $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $p.FullName 'places.sqlite')) { $info.Items += "Firefox profile $($p.Name)"; $info.Count++ }
        }
    }
    return $info
}

function Get-SmbSummary {
    $info = [pscustomobject]@{ Category='Mappature SMB'; Items=@(); Count=0 }
    $maps = @(Get-SmbMapping -ErrorAction SilentlyContinue)
    foreach ($m in $maps) { $info.Items += "$($m.LocalPath) -> $($m.RemotePath)"; $info.Count++ }
    return $info
}

function Get-WiFiSummary {
    $info = [pscustomobject]@{ Category='WiFi'; Items=@(); Count=0 }
    # NIENTE parsing dell'output localizzato di netsh: le etichette cambiano con
    # la lingua di Windows ('Profilo Utente' non esiste, in italiano è
    # 'Tutti i profili utente') e l'anteprima riportava sempre 0 profili mentre
    # l'export vero ne trovava N. Usiamo lo stesso meccanismo dell'export
    # (esportazione XML + conteggio file), che è indipendente dalla lingua.
    $tmp = Join-Path $env:TEMP ("wlan-summary-" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $null = Protect-FileOwnerOnly -Path $tmp
        # Senza key=clear: l'anteprima non deve mai materializzare le password.
        & netsh wlan export profile folder="$tmp" *>$null
        foreach ($f in @(Get-ChildItem $tmp -Filter '*.xml' -ErrorAction SilentlyContinue)) {
            $name = $null
            try {
                [xml]$x = Get-Content $f.FullName -Raw -Encoding UTF8
                $node = $x.WLANProfile.SelectSingleNode("*[local-name()='SSIDConfig']/*[local-name()='SSID']/*[local-name()='name']")
                if ($node) { $name = [string]$node.InnerText }
                if (-not $name) { $name = [string]$x.WLANProfile.name }
            } catch { }
            if (-not $name) { $name = $f.BaseName }
            $info.Items += $name
            $info.Count++
        }
    } catch {
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            Write-AppLog -Level Warning -Message ("Anteprima WiFi fallita: {0}" -f $_.Exception.Message)
        }
    } finally {
        Clear-SensitiveDirectory -Path $tmp
    }
    return $info
}

function Get-PrintersSummary {
    $info = [pscustomobject]@{ Category='Stampanti'; Items=@(); Count=0 }
    $printers = @(Get-Printer -ErrorAction SilentlyContinue)
    foreach ($p in $printers) { $info.Items += "$($p.Name) [$($p.DriverName)]"; $info.Count++ }
    return $info
}

function Invoke-FullExportPreview {
    [CmdletBinding()]
    param([string[]]$Categories = @('Outlook','Browser','SMB','WiFi','Printers'))
    $results = @()
    foreach ($cat in $Categories) {
        $r = switch ($cat) {
            'Outlook'  { Get-OutlookSummary }
            'Browser'  { Get-BrowserSummary }
            'SMB'      { Get-SmbSummary }
            'WiFi'     { Get-WiFiSummary }
            'Printers' { Get-PrintersSummary }
        }
        $results += $r
    }
    return $results
}

Export-ModuleMember -Function Export-OutlookProfile, Export-BrowserData, Export-SmbMappings, Export-WiFiProfiles, Export-Printers, Invoke-FullExport, Get-OutlookSummary, Get-BrowserSummary, Get-SmbSummary, Get-WiFiSummary, Get-PrintersSummary, Invoke-FullExportPreview
