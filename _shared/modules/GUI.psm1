# GUI.psm1 — helper WPF/XAML per tool UTILITIES
# Carica una MainWindow.xaml, restituisce il Window e una hashtable dei controlli x:Name

function Import-XamlWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$XamlPath,
        [string]$ThemePath = $null
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

    if (-not (Test-Path $XamlPath)) { throw "XAML non trovato: $XamlPath" }

    # 1. Carica tema PRIMA del Window XAML — necessario perché StaticResource
    #    viene risolto durante il parsing e cerca le risorse in Application.Resources.
    if ($ThemePath -and (Test-Path $ThemePath)) {
        if ([System.Windows.Application]::Current -eq $null) {
            $null = New-Object System.Windows.Application
        }
        $app = [System.Windows.Application]::Current

        $themeRaw = Get-Content $ThemePath -Raw -Encoding UTF8
        $themeRaw = $themeRaw -replace 'mc:Ignorable="[^"]*"', ''
        [xml]$themeXml = $themeRaw
        $themeReader = New-Object System.Xml.XmlNodeReader $themeXml
        $theme = [Windows.Markup.XamlReader]::Load($themeReader)

        # Evita doppio merge in caso di riavvio nella stessa sessione PS
        $alreadyHas = $false
        foreach ($d in $app.Resources.MergedDictionaries) {
            if ($d.Contains('AccentBrush')) { $alreadyHas = $true; break }
        }
        if (-not $alreadyHas) {
            $app.Resources.MergedDictionaries.Add($theme)
        }
    }

    # 2. Carica Window XAML
    $raw = Get-Content $XamlPath -Raw -Encoding UTF8
    $raw = $raw -replace 'mc:Ignorable="[^"]*"', ''
    $raw = $raw -replace 'x:Class="[^"]*"', ''

    [xml]$xaml = $raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # 2b. Icona della finestra.
    # Non si puo' usare Icon="..." nello XAML: XamlReader carica da stringa,
    # senza BaseUri, quindi un percorso relativo non verrebbe risolto. La
    # impostiamo qui, ricavandola dal numero del tool (cartella NN-Nome).
    # Senza icona tutti e 10 i tool appaiono in Alt+Tab con l'icona generica di
    # PowerShell e diventano indistinguibili quando sono aperti insieme.
    try {
        $projectDir = Split-Path -Parent (Split-Path -Parent $XamlPath)   # ...\NN-Nome
        $toolFolder = Split-Path -Leaf $projectDir
        if ($toolFolder -match '^(\d{2})-') {
            $iconPath = Join-Path (Split-Path -Parent $projectDir) ("_shared\assets\icons\tool-{0}.ico" -f $matches[1])
            if (Test-Path $iconPath) {
                # Si sceglie il frame PIU' GRANDE del .ico: BitmapFrame::Create
                # restituirebbe il primo (16x16), che nella barra applicazioni e
                # in Alt+Tab verrebbe ingrandito e risulterebbe sgranato.
                $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                    (New-Object System.Uri($iconPath)),
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $best = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
                if ($best) { $window.Icon = $best }
            }
        }
    } catch {
        # Un'icona mancante non deve impedire l'apertura del tool.
    }

    # 3. Raccogli tutti i controlli con x:Name
    $controls = @{}
    $named = $xaml.SelectNodes("//*[@*[local-name()='Name']]")
    foreach ($node in $named) {
        $name = $null
        foreach ($attr in $node.Attributes) {
            if ($attr.LocalName -eq 'Name') { $name = $attr.Value; break }
        }
        if ($name) {
            $ctrl = $window.FindName($name)
            if ($ctrl) { $controls[$name] = $ctrl }
        }
    }

    return [pscustomobject]@{ Window = $window; Controls = $controls }
}

function Invoke-OnUI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($Window.Dispatcher.CheckAccess()) { & $Action }
    else { $Window.Dispatcher.Invoke($Action) }
}

function Show-MessageBox {
    param(
        [string]$Message,
        [string]$Title = "UTILITIES",
        [ValidateSet('OK','OKCancel','YesNo','YesNoCancel')][string]$Buttons = 'OK',
        [ValidateSet('None','Information','Warning','Error','Question')][string]$Icon = 'Information'
    )
    Add-Type -AssemblyName PresentationFramework
    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

# Set-AdminBanner: applica stile + testo a un controllo Border+TextBlock dichiarato in XAML.
#
# Required = $true  -> rosso bloccante: il tool richiede admin per la funzione principale
# Required = $false -> giallo: alcune feature (es. BitLocker key) richiedono admin
#
# I tool read-only puri (01, 02, 06, 08, 10) non chiamano questa funzione: per loro c'e'
# Set-ReadOnlyBanner che mostra una banda verde "Read-only - non richiede admin".
function Set-AdminBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$BannerBorder,
        [Parameter(Mandatory)]$BannerText,
        [bool]$IsAdmin,
        [bool]$Required,
        [string]$ToolName = 'Questo tool'
    )
    $resKey = if ($IsAdmin) { 'AdminBannerOk' } elseif ($Required) { 'AdminBannerError' } else { 'AdminBannerWarn' }
    $style  = $Window.TryFindResource($resKey)
    if ($style) { $BannerBorder.Style = $style }

    if ($IsAdmin) {
        $BannerText.Text = "Eseguito come AMMINISTRATORE. Tutte le funzioni sono disponibili."
    } elseif ($Required) {
        $BannerText.Text = "ATTENZIONE: $ToolName richiede privilegi di AMMINISTRATORE per funzionare correttamente. Le azioni distruttive sono disabilitate. Premi 'Riavvia come amministratore' qui accanto."
    } else {
        $BannerText.Text = "Esecuzione come UTENTE standard. Alcune informazioni avanzate (es. chiave di ripristino BitLocker, profili WiFi di tutti gli utenti) non saranno disponibili."
    }
}

# Set-ReadOnlyExtrasBanner: per i tool READ-ONLY che da amministratore mostrano
# qualche dato in più (03-PCAudit, 04-KeyRecovery). Prima usavano il banner
# giallo di avviso, che su un tool che non modifica nulla è fuorviante: il
# tecnico vede un allarme dove non c'e' rischio. Blu informativo = "non modifico
# nulla, da admin vedo di più".
function Set-ReadOnlyExtrasBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$BannerBorder,
        [Parameter(Mandatory)]$BannerText,
        [bool]$IsAdmin,
        [string]$Extras = "chiave di ripristino BitLocker e profili WiFi di tutti gli utenti"
    )
    $resKey = if ($IsAdmin) { 'AdminBannerOk' } else { 'AdminBannerInfo' }
    $style  = $Window.TryFindResource($resKey)
    if ($style) { $BannerBorder.Style = $style }

    if ($IsAdmin) {
        $BannerText.Text = "Tool READ-ONLY, eseguito come AMMINISTRATORE: non modifica nulla del sistema e tutti i dati sono disponibili."
    } else {
        $BannerText.Text = "Tool READ-ONLY: non modifica nulla del sistema. Da amministratore raccoglie anche $Extras."
    }
}

# Get-FriendlyError: traduce le eccezioni .NET/PowerShell più comuni in una frase
# comprensibile. Il dettaglio tecnico resta nel log, non nella MessageBox: un
# messaggio come "Exception calling GetAccessControl with 0 arguments" non aiuta
# il tecnico a decidere cosa fare.
function Get-FriendlyError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $m = $Message
    $map = [ordered]@{
        'Access is denied|Accesso negato|UnauthorizedAccess' =
            "Accesso negato. Riprova con privilegi di amministratore."
        'RPC server is unavailable|server RPC non . disponibile' =
            "Un servizio di sistema non risponde (RPC). Riavvia il PC e riprova."
        'Invalid namespace|WMI|Provider load failure' =
            "Il servizio WMI di Windows non risponde. Riavvia il PC; se persiste il repository WMI potrebbe essere danneggiato."
        'timed out|timeout|Timeout' =
            "Operazione scaduta per timeout. La risorsa non risponde: riprova o riduci il perimetro."
        'Could not find file|Impossibile trovare il file|does not exist' =
            "File o percorso non trovato."
        'being used by another process|utilizzato da un altro processo' =
            "Il file è aperto in un altro programma. Chiudilo e riprova."
        'network path was not found|percorso di rete' =
            "Percorso di rete non raggiungibile. Verifica la connessione o i permessi sulla condivisione."
        'not recognized as|termine .* non . riconosciuto' =
            "Comando di sistema non disponibile su questo PC."
        'There is not enough space|spazio su disco' =
            "Spazio su disco insufficiente."
    }
    foreach ($pattern in $map.Keys) {
        if ($m -match $pattern) { return $map[$pattern] }
    }
    return "Errore imprevisto. Il dettaglio tecnico è stato salvato nel log del tool."
}

# Show-ErrorBox: messaggio comprensibile in primo piano, dettaglio tecnico in coda.
function Show-ErrorBox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Context = '',
        [string]$Title = 'Errore'
    )
    $friendly = Get-FriendlyError -Message $Message
    $head = if ($Context) { "$Context`n`n$friendly" } else { $friendly }
    return (Show-MessageBox -Message "$head`n`n--- Dettaglio tecnico ---`n$Message" -Title $Title -Icon Error)
}

# Set-EmptyState: mostra/nasconde un TextBlock di stato vuoto sopra una lista.
# Una ListView vuota e basta si legge come "caricamento fallito"; con una frase
# esplicita si legge come "controllato, tutto a posto".
function Set-EmptyState {
    [CmdletBinding()]
    param(
        $Placeholder,
        $ListControl,
        [int]$Count,
        [string]$Text = ''
    )
    if (-not $Placeholder) { return }
    if ($Count -le 0) {
        if ($Text) { $Placeholder.Text = $Text }
        $Placeholder.Visibility = 'Visible'
        if ($ListControl) { $ListControl.Visibility = 'Collapsed' }
    } else {
        $Placeholder.Visibility = 'Collapsed'
        if ($ListControl) { $ListControl.Visibility = 'Visible' }
    }
}

function Set-ReadOnlyBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$BannerBorder,
        [Parameter(Mandatory)]$BannerText,
        [string]$Detail = 'non modifica nulla del sistema'
    )
    $style = $Window.TryFindResource('AdminBannerOk')
    if ($style) { $BannerBorder.Style = $style }
    $BannerText.Text = "Tool READ-ONLY: $Detail. Non richiede privilegi di amministratore."
}

Export-ModuleMember -Function Import-XamlWindow, Invoke-OnUI, Show-MessageBox, Show-ErrorBox, `
                              Get-FriendlyError, Set-AdminBanner, Set-ReadOnlyBanner, `
                              Set-ReadOnlyExtrasBanner, Set-EmptyState
