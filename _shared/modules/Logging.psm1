# Logging.psm1 — sistema di log unificato per tutti i tool UTILITIES
# Uso:
#   Initialize-AppLog -Path "data\logs\app.log" -UICallback { param($lvl,$msg) ... }
#   Write-AppLog -Level Info -Message "..."

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:LogPath = $null
$script:UICallback = $null

function Initialize-AppLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$UICallback = $null
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # I log contengono percorsi operativi, nome utente e nome PC: dati personali
    # e ricognizione utile. Su PC multi-utente vanno letti solo dal proprietario.
    if ($dir) { $null = Protect-FileOwnerOnly -Path $dir }
    # Anche il FILE, non solo la cartella: irrigidire la directory non retroagisce
    # sulle ACE esplicite di un log creato prima dell'hardening, e questi file
    # esistono gia' su ogni installazione in uso.
    if (Test-Path -LiteralPath $Path) { $null = Protect-FileOwnerOnly -Path $Path }
    $script:LogPath = $Path
    $script:UICallback = $UICallback
    "=== Sessione $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | User: $env:USERNAME | PC: $env:COMPUTERNAME ===" |
        Out-File -FilePath $Path -Append -Encoding UTF8
}

function Write-AppLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Info','Warning','Error','Success','Debug')]
        [string]$Level = 'Info',
        [Parameter(Mandatory)][string]$Message
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    if ($script:LogPath) {
        try { $line | Out-File -FilePath $script:LogPath -Append -Encoding UTF8 } catch { }
    }

    if ($script:UICallback) {
        try { & $script:UICallback $Level $Message } catch { }
    }

    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
        'Debug'   { 'DarkGray' }
    }
    Write-Host $line -ForegroundColor $color
}

Export-ModuleMember -Function Initialize-AppLog, Write-AppLog
