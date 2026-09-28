# AuditCollectors.psm1 — funzioni di raccolta dati per PC Audit (tutto read-only)

function Get-AuditHardware {
    [CmdletBinding()] param()
    $cs    = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios  = Get-CimInstance Win32_BIOS           -ErrorAction SilentlyContinue
    $cpu   = Get-CimInstance Win32_Processor      -ErrorAction SilentlyContinue
    $bb    = Get-CimInstance Win32_BaseBoard      -ErrorAction SilentlyContinue
    $ram   = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $gpu   = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $net   = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')

    $totalRam = 0
    foreach ($r in $ram) { if ($r.Capacity) { $totalRam += [int64]$r.Capacity } }

    function _safe([object]$v) { if ($null -eq $v) { '' } else { ([string]$v).Trim() } }

    return [pscustomobject]@{
        Manufacturer = _safe $cs.Manufacturer
        Model        = _safe $cs.Model
        Serial       = _safe $bios.SerialNumber
        BiosVersion  = _safe $bios.SMBIOSBIOSVersion
        BiosDate     = if ($bios.ReleaseDate -is [datetime]) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } elseif ($bios.ReleaseDate) { try { [Management.ManagementDateTimeConverter]::ToDateTime([string]$bios.ReleaseDate).ToString('yyyy-MM-dd') } catch { [string]$bios.ReleaseDate } } else { '' }
        BaseBoard    = ((_safe $bb.Manufacturer) + ' ' + (_safe $bb.Product)).Trim()
        CPU          = ($cpu | ForEach-Object {
            $name = _safe $_.Name
            "$name [$($_.NumberOfCores)C/$($_.NumberOfLogicalProcessors)T @ $($_.MaxClockSpeed)MHz]"
        }) -join "; "
        RamTotalGB   = [math]::Round($totalRam / 1GB, 2)
        RamModules   = @($ram | ForEach-Object {
            $cap   = if ($_.Capacity) { [math]::Round([int64]$_.Capacity / 1GB, 1) } else { '?' }
            $mfr   = _safe $_.Manufacturer; if (-not $mfr) { $mfr = '?' }
            $sp    = if ($_.Speed) { $_.Speed } else { '?' }
            $pn    = _safe $_.PartNumber; if (-not $pn) { $pn = '?' }
            "${cap}GB $mfr @ ${sp}MHz ($pn)"
        })
        GPU          = ($gpu | ForEach-Object {
            $name = _safe $_.Name
            $vram = if ($_.AdapterRAM) { [math]::Round([int64]$_.AdapterRAM / 1GB, 2) } else { '?' }
            "$name [${vram}GB]"
        }) -join "; "
        Disks        = @($disks | ForEach-Object {
            $sizeGB = if ($_.Size) { [math]::Round($_.Size / 1GB, 0) } else { '?' }
            $health = _safe $_.HealthStatus
            $media  = _safe $_.MediaType
            $bus    = _safe $_.BusType
            $fn     = _safe $_.FriendlyName
            "$fn [$media, ${sizeGB}GB, Health=$health, Bus=$bus]"
        })
        NetAdapters  = @($net | ForEach-Object {
            $name = _safe $_.Name
            $mac  = _safe $_.MacAddress
            $sp   = _safe $_.LinkSpeed
            "$name [$mac, $sp]"
        })
    }
}

function Get-AuditOS {
    [CmdletBinding()] param()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cv = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    # Stato attivazione
    $licStatusMap = @{0='Unlicensed'; 1='Licensed'; 2='OOB Grace'; 3='OOT Grace'; 4='Non-Genuine Grace'; 5='Notification'; 6='Extended Grace'}
    $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.PartialProductKey -and $_.Name -like '*Windows*' } | Select-Object -First 1
    $licStatus = if ($lic) { $licStatusMap[[int]$lic.LicenseStatus] } else { 'Unknown' }

    # Ultimo update installato
    $lastUpdate = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1

    # Tempo accensione
    $bootTime = $os.LastBootUpTime
    $uptime = if ($bootTime) { (Get-Date) - $bootTime } else { $null }

    return [pscustomobject]@{
        Caption       = $os.Caption
        Version       = $os.Version
        Build         = $cv.CurrentBuild
        UBR           = $cv.UBR
        Edition       = $cv.EditionID
        DisplayVersion= $cv.DisplayVersion
        InstallDate   = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
        Architecture  = $os.OSArchitecture
        Language      = $os.OSLanguage
        ComputerName  = $env:COMPUTERNAME
        Domain        = (Get-CimInstance Win32_ComputerSystem).Domain
        LicenseStatus = $licStatus
        LastBoot      = if ($bootTime) { $bootTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        UptimeDays    = if ($uptime) { [math]::Round($uptime.TotalDays, 1) } else { 0 }
        LastHotFix    = if ($lastUpdate) { "$($lastUpdate.HotFixID) ($($lastUpdate.InstalledOn.ToString('yyyy-MM-dd')))" } else { 'N/D' }
    }
}

function Get-AuditSecurity {
    [CmdletBinding()] param()
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # BitLocker (richiede admin per recovery key)
    $bde = $null
    try { $bde = @(Get-BitLockerVolume -ErrorAction Stop) } catch { $bde = @() }

    $bdeData = $bde | ForEach-Object {
        $rk = $null
        if ($isAdmin) {
            $kp = $_.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
            if ($kp) { $rk = $kp.RecoveryPassword }
        }
        [pscustomobject]@{
            Mount       = $_.MountPoint
            Status      = $_.ProtectionStatus
            Encryption  = $_.EncryptionMethod
            Percentage  = $_.EncryptionPercentage
            RecoveryKey = if ($isAdmin) { $rk } else { '(richiede admin)' }
        }
    }

    # Antivirus (root\SecurityCenter2)
    $av = @()
    try {
        $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop |
            Select-Object @{n='Name';e={$_.displayName}}, @{n='State';e={'0x{0:X}' -f $_.productState}})
    } catch { }

    # Firewall
    $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)

    # Secure Boot
    $secureBoot = $null
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $secureBoot = $null }

    # TPM
    $tpm = $null
    try { $tpm = Get-Tpm -ErrorAction Stop } catch { $tpm = $null }

    return [pscustomobject]@{
        IsAdmin    = $isAdmin
        BitLocker  = $bdeData
        Antivirus  = $av
        Firewall   = $fw
        SecureBoot = $secureBoot
        TPM        = if ($tpm) {
            [pscustomobject]@{
                Present     = $tpm.TpmPresent
                Ready       = $tpm.TpmReady
                Enabled     = $tpm.TpmEnabled
                Activated   = $tpm.TpmActivated
                Owned       = $tpm.TpmOwned
                ManufacturerVersion = $tpm.ManufacturerVersion
            }
        } else { $null }
    }
}

function Get-AuditNetwork {
    [CmdletBinding()] param()
    $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin)

    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses } |
        Select-Object InterfaceAlias, @{n='Servers';e={$_.ServerAddresses -join ', '}})

    $route = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
        Select-Object InterfaceAlias, NextHop, RouteMetric)

    $shares   = @(Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath, RemotePath, Status)
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, DriverName, PortName, Type, ShareName)

    return [pscustomobject]@{
        IPAddresses = $ip
        DNS         = $dns
        Gateway     = $route
        SmbMappings = $shares
        Printers    = $printers
    }
}

function Get-AuditUsers {
    [CmdletBinding()] param()
    $local    = @(Get-LocalUser  -ErrorAction SilentlyContinue | Select-Object Name, Enabled, LastLogon, Description)
    $admins   = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | Select-Object Name, ObjectClass, PrincipalSource)
    $profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special } |
        Select-Object @{n='Path';e={$_.LocalPath}}, @{n='LastUse';e={if ($_.LastUseTime) { $_.LastUseTime.ToString('yyyy-MM-dd') } else {''}}}, Loaded)

    return [pscustomobject]@{
        LocalUsers     = $local
        Administrators = $admins
        Profiles       = $profiles
        CurrentUser    = $env:USERNAME
    }
}

function Get-AuditSoftware {
    [CmdletBinding()] param()
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = @()
    foreach ($p in $regPaths) {
        $apps += @(Get-ItemProperty $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
            Select-Object @{n='Name';e={$_.DisplayName}},
                          @{n='Version';e={$_.DisplayVersion}},
                          @{n='Publisher';e={$_.Publisher}},
                          @{n='InstallDate';e={$_.InstallDate}})
    }
    $apps = $apps | Sort-Object Name -Unique

    return [pscustomobject]@{
        Count = $apps.Count
        Apps  = $apps
    }
}

function Invoke-FullAudit {
    [CmdletBinding()] param([scriptblock]$Progress = $null)

    $steps = @(
        @{ Name='Hardware'; Cmd={ Get-AuditHardware } },
        @{ Name='Sistema';  Cmd={ Get-AuditOS } },
        @{ Name='Sicurezza';Cmd={ Get-AuditSecurity } },
        @{ Name='Rete';     Cmd={ Get-AuditNetwork } },
        @{ Name='Utenti';   Cmd={ Get-AuditUsers } },
        @{ Name='Software'; Cmd={ Get-AuditSoftware } }
    )

    $result = [ordered]@{ Timestamp = (Get-Date); ComputerName = $env:COMPUTERNAME; User = $env:USERNAME }
    $i = 0
    foreach ($s in $steps) {
        $i++
        if ($Progress) { & $Progress $i $steps.Count $s.Name }
        try {
            $result[$s.Name] = & $s.Cmd
        } catch {
            $result[$s.Name] = [pscustomobject]@{ Error = $_.Exception.Message }
        }
    }
    return [pscustomobject]$result
}

Export-ModuleMember -Function Get-AuditHardware, Get-AuditOS, Get-AuditSecurity, Get-AuditNetwork, Get-AuditUsers, Get-AuditSoftware, Invoke-FullAudit
