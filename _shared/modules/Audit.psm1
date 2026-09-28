# Audit.psm1 — audit log strutturato in formato JSON Lines (una riga per azione)
#
# Uso:
#   Initialize-AppAudit -AuditDir "data\audit" -AppName "01-DriverUpdater"
#   Write-AuditEntry -Action 'scan.start' -Target 'PnP devices' -Result Info
#   Write-AuditEntry -Action 'driver.install' -Target 'NIC' -Before {...} -After {...} -Result Success
#
# Output: data/audit/audit-YYYYMM.jsonl

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:AuditPath = $null
$script:AppName   = $null
$script:PrevHash  = $null

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Initialize-AppAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuditDir,
        [Parameter(Mandatory)][string]$AppName
    )
    if (-not (Test-Path $AuditDir)) {
        New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null
    }
    # L'audit registra cosa è stato fatto sul PC del cliente: va protetto dagli
    # altri utenti locali tanto quanto i report.
    $null = Protect-FileOwnerOnly -Path $AuditDir

    $script:AuditPath = Join-Path $AuditDir ("audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMM'))
    $script:AppName   = $AppName

    # Verifica la catena all'avvio: senza questa chiamata la hash-chain non
    # serviva a niente, perché nessuno la controllava mai. L'esito finisce nel
    # log del tool, non in un popup: non è un evento che deve bloccare il lavoro.
    if (Test-Path -LiteralPath $script:AuditPath) {
        try {
            $chk = Test-AppAuditChain -Path $script:AuditPath
            if (-not $chk.Valid -and (Get-Command Write-AppLog -ErrorAction SilentlyContinue)) {
                Write-AppLog -Level Warning -Message "Audit: catena di integrità incoerente alla riga $($chk.Line) - $($chk.Reason)"
            }
        } catch { }
    }

    # Hash-chain: riprende l'ultimo hash del file per concatenare la sessione
    # corrente. Una riga cancellata o alterata a posteriori rompe la catena e
    # diventa rilevabile con Test-AppAuditChain.
    $script:PrevHash = $null
    if (Test-Path -LiteralPath $script:AuditPath) {
        try {
            $lastLine = Get-Content -LiteralPath $script:AuditPath -Encoding UTF8 -Tail 1 -ErrorAction Stop
            if ($lastLine) { $script:PrevHash = Get-Sha256Hex $lastLine }
        } catch { }
    }

    Write-AuditEntry -Action 'session.start' -Target $AppName -Result 'Info' -Reason 'Sessione avviata'
}

function Test-AppAuditChain {
    # Verifica la hash-chain di un file di audit.
    #
    # COSA GARANTISCE E COSA NO — da leggere prima di darle peso:
    # rileva alterazioni ACCIDENTALI o non sofisticate (una riga modificata a
    # mano, un troncamento in mezzo, corruzione del file). NON è antimanomissione:
    # l'hash è SHA256 senza chiave segreta, quindi chi può scrivere il file può
    # ricalcolare l'intera catena in millisecondi. Non protegge nemmeno dal
    # troncamento delle righe FINALI, perché non esiste un'ancora esterna.
    # Per valore probatorio servirebbero HMAC con chiave non residente sul PC,
    # oppure spedizione append-only fuori dal PC.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "File audit non trovato: $Path" }
    $prev = $null
    $n = 0
    $legacy = 0
    $chainStarted = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $n++
        if (-not $line) { continue }
        try { $obj = $line | ConvertFrom-Json } catch {
            return [pscustomobject]@{ Valid = $false; Line = $n; Legacy = $legacy; Reason = 'JSON non valido' }
        }
        # Righe senza prevHash: ammesse SOLO in testa al file (scritte prima
        # dell'introduzione della hash-chain). Una riga priva di prevHash DOPO
        # che la catena è iniziata è una manomissione: bastava rimuovere il
        # campo da tutte le righe per ottenere Valid=$true.
        if (-not ($obj.PSObject.Properties.Name -contains 'prevHash')) {
            if ($chainStarted) {
                return [pscustomobject]@{ Valid = $false; Line = $n; Legacy = $legacy
                                          Reason = 'prevHash assente su una riga successiva all''inizio della catena (campo rimosso?)' }
            }
            $legacy++
            $prev = Get-Sha256Hex $line
            continue
        }
        $chainStarted = $true
        $recorded = $obj.prevHash
        if ($recorded -ne $prev) {
            return [pscustomobject]@{ Valid = $false; Line = $n; Legacy = $legacy; Reason = "prevHash atteso '$prev', trovato '$recorded'" }
        }
        $prev = Get-Sha256Hex $line
    }

    # Righe prive di hash-chain => NON VERIFICABILE, non "valido".
    # Un file da cui l'attaccante ha rimosso prevHash da tutte le righe è
    # indistinguibile da un file antecedente all'introduzione della catena:
    # nessuno schema autocontenuto può separarli. Dichiararlo integro sarebbe
    # una bugia, quindi si restituisce un esito esplicito di non verificabilità.
    if ($legacy -gt 0) {
        return [pscustomobject]@{
            Valid  = $false
            Line   = $n
            Legacy = $legacy
            Reason = "$legacy righe prive di hash-chain: file non verificabile (precedenti all'introduzione della catena, oppure campo rimosso)"
        }
    }
    return [pscustomobject]@{ Valid = $true; Line = $n; Legacy = $legacy; Reason = '' }
}

function Write-AuditEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        $Before = $null,
        $After  = $null,
        # NIENTE ValidateSet: i chiamanti inoltrano qui i livelli di log del
        # worker ('Error', 'Debug', 'Success'...) e un valore fuori set faceva
        # lanciare ParameterBindingValidationException DENTRO un handler
        # Add_Tick, cioè un crash WPF non gestito. L'audit non deve mai poter
        # far cadere l'app: normalizziamo invece di rifiutare.
        [string]$Result = 'Info',
        [string]$Reason = ''
    )
    if (-not $script:AuditPath) { return }

    $Result = switch ($Result) {
        'Success' { 'Success' }
        'Failure' { 'Failure' }
        'Warning' { 'Warning' }
        'Pending' { 'Pending' }
        'Info'    { 'Info' }
        'Error'   { 'Failure' }   # livello di log -> esito di audit
        'Debug'   { 'Info' }
        default   { 'Info' }
    }

    $entry = [ordered]@{
        ts       = (Get-Date).ToString('o')
        app      = $script:AppName
        user     = $env:USERNAME
        computer = $env:COMPUTERNAME
        action   = $Action
        target   = $Target
        before   = $Before
        after    = $After
        result   = $Result
        reason   = $Reason
        prevHash = $script:PrevHash
    }

    try {
        $line = $entry | ConvertTo-Json -Compress -Depth 8
        Add-Content -Path $script:AuditPath -Value $line -Encoding UTF8
        $script:PrevHash = Get-Sha256Hex $line
    } catch {
        # Audit non deve mai bloccare l'app
    }
}

function Close-AppAudit {
    if ($script:AuditPath) {
        Write-AuditEntry -Action 'session.end' -Target $script:AppName -Result 'Info' -Reason 'Sessione terminata'
    }
}

Export-ModuleMember -Function Initialize-AppAudit, Write-AuditEntry, Close-AppAudit, Test-AppAuditChain
