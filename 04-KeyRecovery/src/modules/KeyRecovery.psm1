# KeyRecovery.psm1 — recupero chiavi e credenziali locali (read-only)
# Tool sensibile: leggere SOLO con consenso scritto.

# Common.psm1 serve per Protect-FileOwnerOnly / Clear-SensitiveDirectory sulla
# temp dei profili WiFi. L'import va fatto QUI e non solo in Main.ps1: questo
# modulo viene caricato anche dentro un runspace isolato, dove i moduli
# importati dal thread UI non sono visibili.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) '_shared\modules\Common.psm1') -DisableNameChecking

function Get-WindowsOEMKey {
    [CmdletBinding()] param()
    try {
        $sl = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        $k = $sl.OA3xOriginalProductKey
        if ($k) { return $k.Trim() }
        return $null
    } catch { return $null }
}

function Get-WindowsLicenseInfo {
    [CmdletBinding()] param()
    try {
        $statusMap = @{0='Unlicensed';1='Licensed';2='OOB Grace';3='OOT Grace';4='Non-Genuine Grace';5='Notification';6='Extended Grace'}
        $prod = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
            Where-Object { $_.PartialProductKey -and $_.Name -like '*Windows*' } |
            Select-Object -First 1
        if (-not $prod) { return $null }
        return [pscustomobject]@{
            ProductName       = $prod.Name
            Description       = $prod.Description
            PartialKey        = $prod.PartialProductKey
            LicenseStatus     = $statusMap[[int]$prod.LicenseStatus]
            ChannelType       = $prod.ProductKeyChannel
        }
    } catch { return $null }
}

function ConvertFrom-DigitalProductId {
    [CmdletBinding()] param([Parameter(Mandatory)][byte[]]$Bytes)
    # Algoritmo legacy. Per Windows 10/11 con digital license la chiave NON è
    # archiviata in plain text - questo decoder restituisce un valore ma potrebbe
    # NON corrispondere alla chiave attuale. Usare come fallback informativo.
    if (-not $Bytes -or $Bytes.Length -lt 67) {
        return $null
    }
    $chars = 'BCDFGHJKMPQRTVWXY2346789'
    $b = New-Object byte[] 15
    try {
        [Array]::Copy($Bytes, 52, $b, 0, 15)
    } catch { return $null }
    $isWin8OrLater = ((($b[14] -shr 3) -band 1) -ne 0)
    $b[14] = $b[14] -band 247
    $last = 0
    $key = ''
    for ($i = 24; $i -ge 0; $i--) {
        $current = 0
        for ($j = 14; $j -ge 0; $j--) {
            $current = ($current * 256) -bxor $b[$j]
            $b[$j]   = [Math]::Truncate($current / 24)
            $current = $current % 24
        }
        $key = $chars[$current] + $key
        $last = $current
    }
    if ($isWin8OrLater) {
        $key = $key.Substring(1, $last) + 'N' + $key.Substring($last + 1, $key.Length - $last - 1)
    }
    $formatted = ''
    for ($i = 0; $i -lt $key.Length; $i++) {
        if ($i -gt 0 -and ($i % 5) -eq 0) { $formatted += '-' }
        $formatted += $key[$i]
    }
    return $formatted
}

function Get-WindowsKeyFromRegistry {
    [CmdletBinding()] param()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion'
    )
    foreach ($p in $paths) {
        try {
            $r = Get-ItemProperty $p -ErrorAction Stop
            if ($r.DigitalProductId) {
                $k = ConvertFrom-DigitalProductId -Bytes $r.DigitalProductId
                if ($k) { return $k }
            }
        } catch { }
    }
    return $null
}

function Get-WiFiProfiles {
    [CmdletBinding()] param()
    # Strategia: export profili come XML in cartella temp e parse strutturato.
    # Così siamo indipendenti dalla lingua del sistema (IT/EN/DE/FR/...).
    $tmp = Join-Path $env:TEMP ("wlan-export-" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        # La cartella conterra' le PSK WiFi IN CHIARO: restringiamo l'ACL PRIMA
        # dell'export, non dopo. %TEMP% eredita ACL che su PC multi-utente mal
        # configurati possono essere permissive.
        $null = Protect-FileOwnerOnly -Path $tmp
        & netsh wlan export profile folder="$tmp" key=clear *>$null
        $netshExit = $LASTEXITCODE
        $xmls = @(Get-ChildItem $tmp -Filter '*.xml' -ErrorAction SilentlyContinue)
        # netsh fallito e zero file: NON è "nessuna rete salvata". Si restituisce
        # una riga esplicita, altrimenti il tecnico legge "Profili WiFi: 0" e
        # conclude che non ce ne sono.
        if ($netshExit -ne 0 -and $xmls.Count -eq 0) {
            return @([pscustomobject]@{
                Profile        = '(errore)'
                SSID           = ''
                Authentication = ''
                Cipher         = ''
                Password       = "netsh non ha potuto esportare i profili (codice $netshExit). Il servizio WLAN potrebbe essere disattivato o il PC non ha una scheda WiFi."
            })
        }
        $results = @()
        foreach ($f in $xmls) {
            try {
                [xml]$x = Get-Content $f.FullName -Raw -Encoding UTF8
                $nm     = $x.WLANProfile
                $name   = [string]$nm.name
                # Profili WPA possono avere più nodi <SSID> (uno hex + uno con <name>):
                # selezioniamo esplicitamente quello che contiene <name>.
                $ssidNode = $nm.SelectSingleNode("*[local-name()='SSIDConfig']/*[local-name()='SSID' and *[local-name()='name']]/*[local-name()='name']")
                $ssid   = if ($ssidNode) { [string]$ssidNode.InnerText } else { '' }
                $auth   = [string]$nm.MSM.security.authEncryption.authentication
                $cipher = [string]$nm.MSM.security.authEncryption.encryption
                $key    = ''
                $kmNode = $nm.MSM.security.sharedKey
                if ($kmNode -and $kmNode.keyMaterial) { $key = [string]$kmNode.keyMaterial }
                # netsh restituisce la chiave in chiaro SOLO da amministratore.
                # Da utente standard keyMaterial è un blob esadecimale cifrato e
                # <protected> vale true: prima veniva mostrato sotto l'etichetta
                # "Password" come se fosse la password reale.
                $protectedFlag = ''
                if ($kmNode) { $protectedFlag = [string]$kmNode.protected }
                $isProtected = ($protectedFlag -eq 'true')
                $results += [pscustomobject]@{
                    Profile        = $name
                    SSID           = $ssid
                    Authentication = $auth
                    Cipher         = $cipher
                    Password       = if ($key -and -not $isProtected) { $key }
                                     elseif ($key) { '(cifrata - rilancia come amministratore per leggerla)' }
                                     else { '(nessuna o rete aperta)' }
                }
            } catch { }
        }
        return $results
    } finally {
        # Sovrascrittura prima dell'unlink: un Remove-Item normale lascia il
        # contenuto (PSK in chiaro) recuperabile sul volume.
        try { Clear-SensitiveDirectory -Path $tmp } catch { }
    }
}

function Invoke-FullRecovery {
    [CmdletBinding()] param()
    return [pscustomobject]@{
        Timestamp   = (Get-Date)
        Computer    = $env:COMPUTERNAME
        User        = $env:USERNAME
        Windows     = [pscustomobject]@{
            OEMKeyBIOS    = Get-WindowsOEMKey
            KeyFromReg    = Get-WindowsKeyFromRegistry
            License       = Get-WindowsLicenseInfo
        }
        WiFi        = Get-WiFiProfiles
    }
}

Export-ModuleMember -Function Get-WindowsOEMKey, Get-WindowsLicenseInfo, Get-WindowsKeyFromRegistry, Get-WiFiProfiles, Invoke-FullRecovery
