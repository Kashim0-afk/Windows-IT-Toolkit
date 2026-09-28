# PrinterDiscovery.psm1 — discovery stampanti via probe TCP (read-only sulla rete)

function Get-LocalSubnet {
    [CmdletBinding()] param()
    # Preferisci l'adapter fisico effettivo: escludi loopback, virtual switch
    # (vEthernet di Hyper-V/WSL, "Default Switch"), bridge VMware/VirtualBox.
    $iface = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PrefixOrigin -ne 'WellKnown' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.InterfaceAlias -notlike '*Loopback*' -and
            $_.InterfaceAlias -notlike '*VMware*' -and
            $_.InterfaceAlias -notlike '*Hyper-V*' -and
            $_.InterfaceAlias -notlike '*VirtualBox*' -and
            $_.InterfaceAlias -notlike '*WSL*' -and
            $_.InterfaceAlias -notlike '*vEthernet*' -and
            $_.InterfaceAlias -notlike '*Default Switch*' -and
            $_.InterfaceAlias -notlike '*Tailscale*' -and
            $_.InterfaceAlias -notlike '*Bluetooth*'
        } | Select-Object -First 1

    if (-not $iface) {
        return [pscustomobject]@{ BaseIP='192.168.1'; Start=1; End=254; InterfaceAlias='(non rilevata)' }
    }
    $parts = $iface.IPAddress.Split('.')
    return [pscustomobject]@{
        BaseIP = "$($parts[0]).$($parts[1]).$($parts[2])"
        Start  = 1
        End    = 254
        InterfaceAlias = $iface.InterfaceAlias
        LocalIP = $iface.IPAddress
    }
}

function Test-PrinterPorts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IP,
        [int]$TimeoutMs = 250,
        [int[]]$Ports = @(9100, 631, 515, 80)
    )
    $portNames = @{ 9100='RAW'; 631='IPP'; 515='LPD'; 161='SNMP'; 80='HTTP'; 443='HTTPS' }
    $found = @()
    foreach ($port in $Ports) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($IP, $port, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($ok -and $tcp.Connected) {
                $found += $portNames[$port]
            }
        } catch { } finally {
            try { $tcp.Close() } catch { }
        }
    }
    return $found
}

function Get-PrinterIdentity {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$IP)
    $result = [pscustomobject]@{ Title=''; Server=''; Manufacturer='' }
    try {
        $req = [System.Net.WebRequest]::Create("http://$IP/")
        $req.Timeout = 2500
        $req.Method  = 'GET'
        $req.UserAgent = 'PrinterScanner/1.0'
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()

        $title = ''
        if ($body -match '(?is)<title>(.*?)</title>') { $title = $matches[1].Trim() }
        $server = $resp.Headers['Server']

        $hay = ($title + ' ' + $server)
        $mfr = switch -Wildcard ($hay) {
            "*HP*"        { 'HP'; break }
            "*Hewlett*"   { 'HP'; break }
            "*Brother*"   { 'Brother'; break }
            "*Canon*"     { 'Canon'; break }
            "*Epson*"     { 'Epson'; break }
            "*Xerox*"     { 'Xerox'; break }
            "*Lexmark*"   { 'Lexmark'; break }
            "*Kyocera*"   { 'Kyocera'; break }
            "*Konica*"    { 'Konica Minolta'; break }
            "*Ricoh*"     { 'Ricoh'; break }
            "*Samsung*"   { 'Samsung'; break }
            "*OKI*"       { 'OKI'; break }
            "*Develop*"   { 'Develop'; break }
            default       { '' }
        }

        $result.Title = $title
        $result.Server = $server
        $result.Manufacturer = $mfr
    } catch { }
    return $result
}

function Resolve-Hostname {
    param([string]$IP)
    # 1. Reverse DNS — funziona in rete con DNS interno aggiornato
    try {
        $entry = [System.Net.Dns]::GetHostEntry($IP)
        if ($entry -and $entry.HostName -and $entry.HostName -ne $IP) {
            return $entry.HostName
        }
    } catch { }

    # 2. NetBIOS via nbtstat — molte stampanti registrano NetBIOS anche senza DNS
    try {
        $out = & nbtstat -A $IP 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            # Preferisci il nome con tipo <20> (server), poi <00> (workstation/unico).
            # NIENTE match su 'UNIQUE': la colonna del tipo è LOCALIZZATA (su
            # Windows italiano vale 'UNICO', su tedesco 'EINDEUTIG'), quindi il
            # fallback NetBIOS non restituiva mai un hostname fuori dall'inglese.
            # Il suffisso <20>/<00> È già di per se' discriminante.
            $name = $null
            foreach ($line in $out) {
                if ($line -match '^\s*(\S+)\s+<20>\s+\S+') { $name = $matches[1]; break }
            }
            if (-not $name) {
                foreach ($line in $out) {
                    if ($line -match '^\s*(\S+)\s+<00>\s+\S+') { $name = $matches[1]; break }
                }
            }
            if ($name) { return $name.Trim() }
        }
    } catch { }

    return ''
}

# OUI table: primi 3 byte del MAC -> vendor stampante.
# Lista curata dei prefissi più comuni; non esaustiva ma copre la maggioranza
# dei device incontrati in PMI/uffici. Aggiungi righe qui per coprire nuovi modelli.
$script:PrinterOUI = @{
    # HP / HP Inc / HPE
    '0017A4'='HP'; '001321'='HP'; '0024A8'='HP'; '002655'='HP'; '002667'='HP'
    '0030C1'='HP'; '003D8C'='HP'; '00904B'='HP'; '00E018'='HP'; '080038'='HP'
    '080046'='HP'; '0CC47A'='HP'; '1062E5'='HP'; '1458D0'='HP'; '1C98EC'='HP'
    '2C44FD'='HP'; '305A3A'='HP'; '38EAA7'='HP'; '3C2C30'='HP'; '3CD92B'='HP'
    '40A8F0'='HP'; '5065F3'='HP'; '5C8A38'='HP'; '6451C5'='HP'; '745A56'='HP'
    '80C16E'='HP'; '80E82C'='HP'; '901B0E'='HP'; '9457A5'='HP'; 'A0481C'='HP'
    'A0B3CC'='HP'; 'A48BCD'='HP'; 'A4F40B'='HP'; 'A8517B'='HP'; 'ACE2D3'='HP'
    'B499BA'='HP'; 'B888E3'='HP'; 'BC83A7'='HP'; 'C4346B'='HP'; 'C8B5B7'='HP'
    'CCBE71'='HP'; 'D08E79'='HP'; 'D45D64'='HP'; 'D8D385'='HP'; 'D89D67'='HP'
    'E063DA'='HP'; 'E4E749'='HP'; 'EC8EB5'='HP'; 'FCDE9F'='HP'

    # Brother
    '0080F0'='Brother'; '001BA9'='Brother'; '30055C'='Brother'; '484D7E'='Brother'
    '6CCEB5'='Brother'; 'B0AC0F'='Brother'; 'B0FC0D'='Brother'; 'D80FFC'='Brother'
    'EC2EF4'='Brother'

    # Canon
    '002818'='Canon'; '00CB51'='Canon'; '18002A'='Canon'; '38EE63'='Canon'
    '48A9D2'='Canon'; '4831DB'='Canon'; '749EA6'='Canon'; '7C0BC6'='Canon'
    '8C5DF2'='Canon'; 'A82CA0'='Canon'; 'AC2887'='Canon'; 'C45000'='Canon'
    'E47914'='Canon'; 'F49E63'='Canon'

    # Epson / Seiko Epson
    '0026AB'='Epson'; '002654'='Epson'; '442A60'='Epson'; '64EB8C'='Epson'
    '88E1B7'='Epson'; 'A4EE57'='Epson'; 'B40EDC'='Epson'; 'C462EA'='Epson'
    'D04D2C'='Epson'; 'F8D027'='Epson'

    # Xerox
    '0000AA'='Xerox'; '080037'='Xerox'; '080036'='Xerox'; '080074'='Xerox'
    '9C934E'='Xerox'

    # Lexmark
    '0020001'='Lexmark'; '0021B7'='Lexmark'; '002486'='Lexmark'; '6CC783'='Lexmark'
    '70877B'='Lexmark'; '80F2EB'='Lexmark'; '84A937'='Lexmark'; 'A4070B'='Lexmark'
    'B45BAB'='Lexmark'; 'FCEBED'='Lexmark'

    # Kyocera
    '002021'='Kyocera'; '0050B6'='Kyocera'; '00A0E5'='Kyocera'; '00C0EE'='Kyocera'
    '207BD2'='Kyocera'; '60A44C'='Kyocera'; '644BC3'='Kyocera'; '743A65'='Kyocera'
    '8C09B6'='Kyocera'; 'ACF65B'='Kyocera'; 'B8AC6F'='Kyocera'; 'DCAEDE'='Kyocera'

    # Konica Minolta (anche brand Develop)
    '0020E0'='Konica Minolta'; '002023'='Konica Minolta'; '002048'='Konica Minolta'
    '0080AB'='Konica Minolta'; '002626'='Konica Minolta'; '002658'='Konica Minolta'
    '6CB75B'='Konica Minolta'; 'A40DCF'='Konica Minolta'; 'A4F33B'='Konica Minolta'
    'F008F1'='Konica Minolta'

    # Ricoh
    '0017F1'='Ricoh'; '003E07'='Ricoh'; '0014B9'='Ricoh'; '30FAB7'='Ricoh'
    '78B1D0'='Ricoh'; '78F470'='Ricoh'; '84E26C'='Ricoh'; '9C7DA3'='Ricoh'
    'B0C745'='Ricoh'; 'C0D050'='Ricoh'; 'C411B7'='Ricoh'; 'D02788'='Ricoh'
    'E0510F'='Ricoh'; 'EC1DB2'='Ricoh'; 'F0E33E'='Ricoh'

    # Samsung (printer division ora HP)
    '4070EF'='Samsung'; '5C0A5B'='Samsung'; '64C753'='Samsung'; '78593E'='Samsung'
    '90BF1C'='Samsung'; 'B0DF3A'='Samsung'; 'CC07E4'='Samsung'

    # OKI Data
    '0080C7'='OKI'; '00D78D'='OKI'; '4061E9'='OKI'; '88003C'='OKI'
    'A4B197'='OKI'; 'D80F99'='OKI'

    # Sharp
    '0034EF'='Sharp'; '00163E'='Sharp'; '002277'='Sharp'; '004080'='Sharp'
    '88FA9E'='Sharp'; 'A8ADAD'='Sharp'; 'B40167'='Sharp'

    # Zebra (etichettatrici)
    '0007F8'='Zebra'; '00A0F8'='Zebra'; '4439C4'='Zebra'; 'AC3FA4'='Zebra'
}

function Get-MacForIP {
    param([string]$IP)
    # Get-NetNeighbor: Win 8.1+/2012 R2+. Niente Stub state.
    try {
        $n = Get-NetNeighbor -IPAddress $IP -ErrorAction SilentlyContinue |
             Where-Object { $_.State -in 'Reachable','Stale','Permanent','Delay','Probe' } |
             Select-Object -First 1
        if ($n -and $n.LinkLayerAddress) { return ($n.LinkLayerAddress -replace '-','').ToUpper() }
    } catch { }
    # Fallback arp -a (parsing testuale, lingua-dipendente ma il MAC è regex)
    try {
        $arp = & arp -a $IP 2>$null
        foreach ($line in $arp) {
            if ($line -match '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}') {
                return ($matches[0] -replace '[:-]','').ToUpper()
            }
        }
    } catch { }
    return ''
}

function Get-VendorByMAC {
    param([string]$MAC)
    if ([string]::IsNullOrEmpty($MAC) -or $MAC.Length -lt 6) { return '' }
    $oui6 = $MAC.Substring(0,6).ToUpper()
    if ($script:PrinterOUI.ContainsKey($oui6)) { return $script:PrinterOUI[$oui6] }
    # Alcuni vendor (Lexmark) hanno chiavi a 7 hex nella tabella per disambiguare
    $oui7 = if ($MAC.Length -ge 7) { $MAC.Substring(0,7).ToUpper() } else { '' }
    if ($oui7 -and $script:PrinterOUI.ContainsKey($oui7)) { return $script:PrinterOUI[$oui7] }
    return ''
}

function Invoke-PrinterScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseIP,
        [int]$Start = 1,
        [int]$End   = 254,
        [int]$TimeoutMs = 250,
        [scriptblock]$Progress = $null,
        [scriptblock]$ItemFound = $null,
        [scriptblock]$CancelCheck = $null
    )
    $results = @()
    $total = $End - $Start + 1
    $count = 0
    for ($i = $Start; $i -le $End; $i++) {
        $count++
        if ($CancelCheck -and (& $CancelCheck)) { break }
        $ip = "$BaseIP.$i"
        if ($Progress) { & $Progress $count $total $ip }

        # 443 incluso: molte MFP recenti espongono l'admin web solo in HTTPS.
        # Senza sondarla, il doppio click apriva sempre http:// e falliva.
        $ports = Test-PrinterPorts -IP $ip -TimeoutMs $TimeoutMs -Ports @(9100, 631, 515, 80, 443)
        $isPrinter = ($ports -contains 'RAW') -or ($ports -contains 'IPP') -or ($ports -contains 'LPD')
        if (-not $isPrinter) { continue }

        $id = Get-PrinterIdentity -IP $ip
        $hostname = Resolve-Hostname -IP $ip
        # MAC OUI fallback: più affidabile del probe HTTP per identificare il
        # vendor (la pagina web di una stampante può essere HTTPS-only, in 401,
        # o disabilitata; il MAC è sempre nella ARP cache dopo il probe TCP).
        $mac = Get-MacForIP -IP $ip
        $vendor = if ($id.Manufacturer) { $id.Manufacturer } else { Get-VendorByMAC -MAC $mac }
        $entry = [pscustomobject]@{
            IP           = $ip
            Hostname     = $hostname
            Manufacturer = $vendor
            Title        = $id.Title
            Server       = $id.Server
            MAC          = $mac
            Ports        = ($ports -join ', ')
        }
        $results += $entry
        if ($ItemFound) { & $ItemFound $entry }
    }
    return $results
}

Export-ModuleMember -Function Get-LocalSubnet, Test-PrinterPorts, Get-PrinterIdentity, Resolve-Hostname, Get-MacForIP, Get-VendorByMAC, Invoke-PrinterScan
