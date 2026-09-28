# ReportRenderer.psm1 — formattazione audit in testo (TextBox) e HTML (export)

function Format-AuditAsText {
    [CmdletBinding()] param([Parameter(Mandatory)]$Section)
    if ($null -eq $Section) { return '(nessun dato)' }
    if ($Section.Error)     { return "ERRORE: $($Section.Error)" }
    return ($Section | Format-List | Out-String).TrimEnd()
}

function ConvertTo-HtmlSafe {
    # Escape di TUTTI i campi interpolati nel report: nomi di stampante da print
    # server, Publisher del software e Description degli utenti locali sono
    # stringhe che non controlliamo.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Format-AuditAsHtml {
    [CmdletBinding()] param([Parameter(Mandatory)]$Audit)

    $css = @'
<style>
body { font-family: "Segoe UI", "Helvetica", sans-serif; background:#F3F3F3; color:#1A1A1A; margin:0; padding:32px; }
.container { max-width: 1100px; margin: 0 auto; }
h1 { color:#0078D4; font-weight:600; margin:0 0 4px 0; font-size: 28px; }
.subtitle { color:#6B6B6B; margin: 0 0 24px 0; font-size: 14px; }
.card { background:#FFFFFF; border:1px solid #E5E5E5; border-radius:8px; padding:24px; margin-bottom:20px; box-shadow:0 1px 2px rgba(0,0,0,0.04); }
h2 { color:#1A1A1A; font-weight:600; margin:0 0 16px 0; font-size:18px; border-bottom:2px solid #0078D4; padding-bottom:8px; display:inline-block; }
table { border-collapse: collapse; width: 100%; margin-top:8px; font-size:13px; }
th { text-align:left; background:#FAFAFA; color:#6B6B6B; padding:8px 12px; border-bottom:1px solid #E5E5E5; font-weight:600; }
td { padding:8px 12px; border-bottom:1px solid #F0F0F0; vertical-align: top; }
tr:hover td { background:#F9F9F9; }
.kv { display:grid; grid-template-columns: 220px 1fr; gap:6px 16px; }
.kv .k { color:#6B6B6B; font-size:13px; }
.kv .v { color:#1A1A1A; font-size:13px; word-break:break-word; }
.tag { display:inline-block; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:600; }
.tag-ok   { background:#E6F4EA; color:#107C10; }
.tag-warn { background:#FFF4CE; color:#9D5D00; }
.tag-err  { background:#FDE7E9; color:#C42B1C; }
.foot { color:#6B6B6B; font-size:11px; text-align:center; margin-top:24px; }
pre { background:#F5F5F5; padding:12px; border-radius:6px; font-family: Consolas, monospace; font-size:12px; overflow-x:auto; }
</style>
'@

    function Render-KV($obj, [string[]]$skip = @()) {
        if ($null -eq $obj) { return '<div>(nessun dato)</div>' }
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine('<div class="kv">')
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name -in $skip) { continue }
            $val = $p.Value
            if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $val = ($val | ForEach-Object { ConvertTo-HtmlSafe ($_ | Out-String).Trim() }) -join '<br/>'
            } else {
                $val = ConvertTo-HtmlSafe ([string]$val)
            }
            $null = $sb.AppendLine("<div class='k'>$($p.Name)</div><div class='v'>$val</div>")
        }
        $null = $sb.AppendLine('</div>')
        return $sb.ToString()
    }

    function Render-Table($items, [string[]]$columns) {
        if (-not $items -or $items.Count -eq 0) { return '<div>(nessun dato)</div>' }
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine('<table><thead><tr>')
        foreach ($c in $columns) { $null = $sb.AppendLine("<th>$c</th>") }
        $null = $sb.AppendLine('</tr></thead><tbody>')
        foreach ($it in $items) {
            $null = $sb.AppendLine('<tr>')
            foreach ($c in $columns) {
                $v = ConvertTo-HtmlSafe ([string]$it.$c)
                $null = $sb.AppendLine("<td>$v</td>")
            }
            $null = $sb.AppendLine('</tr>')
        }
        $null = $sb.AppendLine('</tbody></table>')
        return $sb.ToString()
    }

    $hw  = $Audit.Hardware
    $os  = $Audit.Sistema
    $sec = $Audit.Sicurezza
    $net = $Audit.Rete
    $usr = $Audit.Utenti
    $sw  = $Audit.Software

    $sw_top = if ($sw.Apps) { $sw.Apps | Select-Object -First 100 } else { @() }

    $hasRk = $sec.BitLocker | Where-Object { $_.RecoveryKey -and $_.RecoveryKey -ne '(richiede admin)' } | Select-Object -First 1
    $rkWarning = if ($hasRk) {
        '<div style="background:#FDE7E9;border:1px solid #C42B1C;color:#C42B1C;padding:10px;border-radius:4px;margin-bottom:8px;font-size:12px"><strong>ATTENZIONE GDPR/sicurezza:</strong> questo report contiene la BitLocker Recovery Key in chiaro. Conserva il file in una cartella protetta o cifrato (7z + password). Cancellalo dopo l&#39;uso.</div>'
    } else { '' }
    $bdeHtml = if ($sec.BitLocker -and $sec.BitLocker.Count -gt 0) {
        $rkWarning + (Render-Table -items $sec.BitLocker -columns @('Mount','Status','Encryption','Percentage','RecoveryKey'))
    } else { '<div>BitLocker non rilevato o non configurato</div>' }

    $avHtml = if ($sec.Antivirus -and $sec.Antivirus.Count -gt 0) {
        Render-Table -items $sec.Antivirus -columns @('Name','State')
    } else { '<div>Nessun antivirus rilevato in SecurityCenter</div>' }

    $fwHtml = if ($sec.Firewall -and $sec.Firewall.Count -gt 0) {
        Render-Table -items $sec.Firewall -columns @('Name','Enabled','DefaultInboundAction','DefaultOutboundAction')
    } else { '<div>(nessun dato firewall)</div>' }

    $tpmHtml = if ($sec.TPM) {
        Render-KV $sec.TPM
    } else { '<div>TPM non disponibile</div>' }

    $secureBootHtml = "<span class='tag $(if ($sec.SecureBoot -eq $true) {'tag-ok'} elseif ($sec.SecureBoot -eq $false) {'tag-warn'} else {'tag-err'})'>$(if ($sec.SecureBoot -eq $true) {'ATTIVO'} elseif ($sec.SecureBoot -eq $false) {'DISATTIVATO'} else {'N/D'})</span>"

    $html = @"
<!DOCTYPE html>
<html lang="it"><head><meta charset="utf-8"><title>PC Audit Report - $(ConvertTo-HtmlSafe $Audit.ComputerName)</title>$css</head>
<body>
<div class="container">

<h1>PC Audit Report</h1>
<div class="subtitle">$(ConvertTo-HtmlSafe $Audit.ComputerName) &middot; eseguito il $(Get-Date -Date $Audit.Timestamp -Format 'yyyy-MM-dd HH:mm') da $(ConvertTo-HtmlSafe $Audit.User)</div>

<div class="card"><h2>Hardware</h2>
$(Render-KV $hw -skip @('RamModules','Disks','NetAdapters'))
<br/><strong>Moduli RAM</strong><br/>$(if ($hw.RamModules) { (($hw.RamModules | ForEach-Object { ConvertTo-HtmlSafe $_ }) -join '<br/>') } else { '(n/d)' })
<br/><br/><strong>Dischi</strong><br/>$(if ($hw.Disks) { (($hw.Disks | ForEach-Object { ConvertTo-HtmlSafe $_ }) -join '<br/>') } else { '(n/d)' })
<br/><br/><strong>Adattatori di rete</strong><br/>$(if ($hw.NetAdapters) { (($hw.NetAdapters | ForEach-Object { ConvertTo-HtmlSafe $_ }) -join '<br/>') } else { '(n/d)' })
</div>

<div class="card"><h2>Sistema</h2>
$(Render-KV $os)
</div>

<div class="card"><h2>Sicurezza</h2>
<strong>Esecuzione come admin:</strong> $($sec.IsAdmin)<br/>
<strong>Secure Boot:</strong> $secureBootHtml<br/><br/>
<strong>BitLocker</strong><br/>$bdeHtml<br/>
<strong>Antivirus (SecurityCenter)</strong><br/>$avHtml<br/>
<strong>Firewall</strong><br/>$fwHtml<br/>
<strong>TPM</strong><br/>$tpmHtml
</div>

<div class="card"><h2>Rete</h2>
<strong>Indirizzi IP</strong><br/>$(Render-Table -items $net.IPAddresses -columns @('InterfaceAlias','IPAddress','PrefixLength','PrefixOrigin'))<br/>
<strong>DNS</strong><br/>$(Render-Table -items $net.DNS -columns @('InterfaceAlias','Servers'))<br/>
<strong>Gateway</strong><br/>$(Render-Table -items $net.Gateway -columns @('InterfaceAlias','NextHop','RouteMetric'))<br/>
<strong>Mappature SMB</strong><br/>$(Render-Table -items $net.SmbMappings -columns @('LocalPath','RemotePath','Status'))<br/>
<strong>Stampanti</strong><br/>$(Render-Table -items $net.Printers -columns @('Name','DriverName','PortName','Type','ShareName'))
</div>

<div class="card"><h2>Utenti</h2>
<strong>Utenti locali</strong><br/>$(Render-Table -items $usr.LocalUsers -columns @('Name','Enabled','LastLogon','Description'))<br/>
<strong>Membri del gruppo Administrators</strong><br/>$(Render-Table -items $usr.Administrators -columns @('Name','ObjectClass','PrincipalSource'))<br/>
<strong>Profili</strong><br/>$(Render-Table -items $usr.Profiles -columns @('Path','LastUse','Loaded'))
</div>

<div class="card"><h2>Software installato ($($sw.Count) totali, primi 100)</h2>
$(Render-Table -items $sw_top -columns @('Name','Version','Publisher','InstallDate'))
</div>

<div class="foot">Generato da 03-PCAudit (UTILITIES) - read-only - $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
</div></body></html>
"@

    return $html
}

Export-ModuleMember -Function Format-AuditAsText, Format-AuditAsHtml, ConvertTo-HtmlSafe
