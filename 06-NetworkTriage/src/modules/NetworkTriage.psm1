# NetworkTriage.psm1 — diagnosi sequenziale rete con verdetto in italiano

function Test-PingTarget {
    param([string]$Target, [int]$TimeoutMs = 1500)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $r = $ping.Send($Target, $TimeoutMs)
        if ($r.Status -eq 'Success') {
            return [pscustomobject]@{ Ok=$true; Latency=$r.RoundtripTime; Detail="$($r.RoundtripTime) ms" }
        }
        return [pscustomobject]@{ Ok=$false; Detail=[string]$r.Status }
    } catch {
        return [pscustomobject]@{ Ok=$false; Detail=$_.Exception.Message }
    }
}

function Test-DnsResolve {
    param([string]$Name, [string]$Server = $null)
    try {
        if ($Server) {
            $r = Resolve-DnsName -Name $Name -Server $Server -DnsOnly -ErrorAction Stop -QuickTimeout
        } else {
            $r = Resolve-DnsName -Name $Name -DnsOnly -ErrorAction Stop -QuickTimeout
        }
        $a = $r | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
        return [pscustomobject]@{ Ok=($null -ne $a); Detail = if ($a) { "$Name -> $($a.IPAddress)" } else { '(nessuna A)' } }
    } catch {
        return [pscustomobject]@{ Ok=$false; Detail=$_.Exception.Message }
    }
}

function Test-Tcp {
    # Nota: niente parametro $Host - è una variabile automatica di PowerShell.
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 2000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($Address, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $tcp.Connected) {
            return [pscustomobject]@{ Ok=$true; Detail="${Address}:${Port} OK" }
        }
        return [pscustomobject]@{ Ok=$false; Detail="${Address}:${Port} timeout/closed" }
    } catch {
        return [pscustomobject]@{ Ok=$false; Detail=$_.Exception.Message }
    } finally {
        try { $tcp.Close() } catch { }
    }
}

function Test-Http {
    param([string]$Url, [int]$TimeoutSec = 4)
    try {
        # Windows PowerShell 5.1 negozia di default fino a TLS 1.0, che
        # microsoft.com e la maggior parte degli endpoint HTTPS moderni
        # rifiutano: senza questo il test HTTPS falliva con "Could not create
        # SSL/TLS secure channel" anche con la rete perfettamente funzionante,
        # segnalando un falso problema. Aggiungiamo TLS 1.2 in OR (non lo
        # sostituiamo) e ignoriamo l'eventuale errore su .NET privi dell'enum.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { }
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000
        $req.Method = 'HEAD'
        $req.UserAgent = 'NetworkTriage/1.0'
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return [pscustomobject]@{ Ok=($code -ge 200 -and $code -lt 400); Detail="HTTP $code" }
    } catch {
        return [pscustomobject]@{ Ok=$false; Detail=$_.Exception.Message }
    }
}

function Get-LocalNetwork {
    $iface = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PrefixOrigin -ne 'WellKnown' -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notlike '*Loopback*'
        } | Select-Object -First 1

    $gw = $null
    if ($iface) {
        $gw = (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceAlias -eq $iface.InterfaceAlias } |
            Select-Object -First 1).NextHop
    }

    $dns = if ($iface) {
        (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $iface.InterfaceAlias -ErrorAction SilentlyContinue).ServerAddresses
    } else { @() }

    return [pscustomobject]@{
        Interface = $iface.InterfaceAlias
        IP        = $iface.IPAddress
        Prefix    = $iface.PrefixLength
        Gateway   = $gw
        DNS       = @($dns)
    }
}

function Invoke-FullTriage {
    [CmdletBinding()] param(
        [scriptblock]$Step = $null,
        [scriptblock]$CancelCheck = $null
    )

    $results = @()
    $net = Get-LocalNetwork
    $script:_lastResults = @()
    $script:_cancelled   = $false

    function _addStep($name, $ok, $detail, $advice = '') {
        $r = [pscustomobject]@{ Step=$name; Ok=$ok; Detail=$detail; Advice=$advice }
        $script:_lastResults += $r
        if ($Step) { & $Step $r }
    }
    function _cancelled {
        if ($CancelCheck -and (& $CancelCheck)) { $script:_cancelled = $true; return $true }
        return $false
    }

    # 1. IP locale
    if ($net.IP) {
        _addStep "Configurazione IP" $true "$($net.Interface): $($net.IP)/$($net.Prefix)"
    } else {
        _addStep "Configurazione IP" $false "Nessuna interfaccia IPv4 attiva" "Verifica adapter di rete e cavo/WiFi."
        return $script:_lastResults
    }

    if (_cancelled) { return $script:_lastResults }

    # 2. Gateway raggiungibile
    if ($net.Gateway) {
        $r = Test-PingTarget -Target $net.Gateway
        if ($r.Ok) {
            _addStep "Gateway $($net.Gateway)" $true $r.Detail
        } else {
            _addStep "Gateway $($net.Gateway)" $false $r.Detail "Il router non risponde. Problema sulla rete locale (cavo, switch, WiFi)."
        }
    } else {
        _addStep "Gateway" $false "Nessun default gateway" "Verifica DHCP o configurazione manuale IP."
    }

    if (_cancelled) { return $script:_lastResults }

    # 3. DNS interno (primo DNS configurato)
    if ($net.DNS -and $net.DNS.Count -gt 0) {
        $primary = $net.DNS[0]
        $r = Test-DnsResolve -Name 'www.microsoft.com' -Server $primary
        if ($r.Ok) {
            _addStep "DNS interno ($primary)" $true $r.Detail
        } else {
            _addStep "DNS interno ($primary)" $false $r.Detail "Il DNS configurato non risolve. Prova a impostare 8.8.8.8 manualmente o riavvia il router."
        }
    } else {
        _addStep "DNS interno" $false "Nessun DNS configurato" "DHCP non ha assegnato DNS. Configura manualmente."
    }

    if (_cancelled) { return $script:_lastResults }

    # 4. DNS esterno (Google)
    $r = Test-PingTarget -Target '8.8.8.8'
    if ($r.Ok) {
        _addStep "DNS esterno (8.8.8.8)" $true $r.Detail
    } else {
        _addStep "DNS esterno (8.8.8.8)" $false $r.Detail "Internet bloccato a livello firewall/router. Contatta amministratore di rete."
    }

    # 5. DNS esterno alternativo
    $r = Test-PingTarget -Target '1.1.1.1'
    if ($r.Ok) {
        _addStep "DNS esterno (1.1.1.1)" $true $r.Detail
    } else {
        _addStep "DNS esterno (1.1.1.1)" $false $r.Detail
    }

    if (_cancelled) { return $script:_lastResults }

    # 6. Resolve dominio noto
    $r = Test-DnsResolve -Name 'www.microsoft.com'
    if ($r.Ok) {
        _addStep "Risoluzione DNS pubblica" $true $r.Detail
    } else {
        _addStep "Risoluzione DNS pubblica" $false $r.Detail "Risoluzione DNS non funziona globalmente. Possibile DNS errato o blocco firewall."
    }

    if (_cancelled) { return $script:_lastResults }

    # 7. HTTP/HTTPS
    $r = Test-Http -Url 'http://www.msftconnecttest.com/connecttest.txt'
    if ($r.Ok) {
        _addStep "HTTP (msftconnecttest)" $true $r.Detail
    } else {
        _addStep "HTTP (msftconnecttest)" $false $r.Detail "HTTP bloccato. Possibile proxy o firewall in uscita."
    }

    $r = Test-Http -Url 'https://www.microsoft.com'
    if ($r.Ok) {
        _addStep "HTTPS (microsoft.com)" $true $r.Detail
    } else {
        _addStep "HTTPS (microsoft.com)" $false $r.Detail "HTTPS bloccato. Verifica certificati e proxy."
    }

    # 8. Proxy
    $proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue)
    $proxyEnabled = if ($proxy.ProxyEnable -eq 1) { $true } else { $false }
    if ($proxyEnabled) {
        _addStep "Proxy WinINET" $true "Attivo: $($proxy.ProxyServer)" "Verifica che il proxy sia raggiungibile e configurato correttamente."
    } else {
        _addStep "Proxy WinINET" $true "Disattivato (connessione diretta)"
    }

    return $script:_lastResults
}

function Get-Verdict {
    param($Results)
    $failed = @($Results | Where-Object { -not $_.Ok })
    if ($failed.Count -eq 0) {
        return "Tutto OK. La rete del PC funziona correttamente."
    }
    $first = $failed[0]
    $extra = ''
    if ($failed.Count -gt 1) {
        $names = ($failed | Select-Object -Skip 1 | ForEach-Object { $_.Step }) -join '; '
        $extra = " Altri test falliti: $names."
    }
    return "Primo problema rilevato: '$($first.Step)'. $($first.Advice) ($($failed.Count)/$($Results.Count) test falliti).$extra"
}

Export-ModuleMember -Function Test-PingTarget, Test-DnsResolve, Test-Tcp, Test-Http, Get-LocalNetwork, Invoke-FullTriage, Get-Verdict
