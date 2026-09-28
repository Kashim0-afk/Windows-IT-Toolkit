# Validators.psm1 — validatori con checksum per dati italiani

function Test-CodiceFiscale {
    param([string]$Cf)
    $Cf = $Cf.ToUpper().Trim()
    if ($Cf.Length -ne 16) { return $false }
    if ($Cf -notmatch '^[A-Z0-9]{16}$') { return $false }

    $oddVals = @{
        'A'=1;'B'=0;'C'=5;'D'=7;'E'=9;'F'=13;'G'=15;'H'=17;'I'=19;'J'=21;
        'K'=2;'L'=4;'M'=18;'N'=20;'O'=11;'P'=3;'Q'=6;'R'=8;'S'=12;'T'=14;
        'U'=16;'V'=10;'W'=22;'X'=25;'Y'=24;'Z'=23;
        '0'=1;'1'=0;'2'=5;'3'=7;'4'=9;'5'=13;'6'=15;'7'=17;'8'=19;'9'=21
    }
    $evenVals = @{
        'A'=0;'B'=1;'C'=2;'D'=3;'E'=4;'F'=5;'G'=6;'H'=7;'I'=8;'J'=9;
        'K'=10;'L'=11;'M'=12;'N'=13;'O'=14;'P'=15;'Q'=16;'R'=17;'S'=18;'T'=19;
        'U'=20;'V'=21;'W'=22;'X'=23;'Y'=24;'Z'=25;
        '0'=0;'1'=1;'2'=2;'3'=3;'4'=4;'5'=5;'6'=6;'7'=7;'8'=8;'9'=9
    }
    $sum = 0
    for ($i = 0; $i -lt 15; $i++) {
        $ch = [string]$Cf[$i]
        $pos = $i + 1
        if ($pos % 2 -eq 1) { $sum += $oddVals[$ch] } else { $sum += $evenVals[$ch] }
    }
    $expected = [char]($sum % 26 + [int][char]'A')
    return $Cf[15] -eq $expected
}

function Test-PartitaIva {
    param([string]$Piva)
    $Piva = $Piva.Trim()
    if ($Piva -notmatch '^\d{11}$') { return $false }
    $sum = 0
    for ($i = 0; $i -lt 11; $i++) {
        $d = [int][string]$Piva[$i]
        if ($i % 2 -eq 0) {
            $sum += $d
        } else {
            $d = $d * 2
            if ($d -gt 9) { $d -= 9 }
            $sum += $d
        }
    }
    return ($sum % 10) -eq 0
}

function Test-Iban {
    param([string]$Iban)
    $Iban = ($Iban -replace '\s','').ToUpper()
    if ($Iban -notmatch '^[A-Z]{2}\d{2}[A-Z0-9]+$') { return $false }
    if ($Iban.Length -lt 15 -or $Iban.Length -gt 34) { return $false }

    # Sposta primi 4 alla fine, sostituisci A=10..Z=35
    $rearranged = $Iban.Substring(4) + $Iban.Substring(0, 4)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $rearranged.ToCharArray()) {
        if ([char]::IsDigit($ch)) {
            $null = $sb.Append($ch)
        } else {
            $null = $sb.Append([int][char]$ch - [int][char]'A' + 10)
        }
    }
    $numStr = $sb.ToString()
    # Mod 97 su stringa lunga: chunk a chunk
    $remainder = 0
    foreach ($ch in $numStr.ToCharArray()) {
        $remainder = ($remainder * 10 + [int][string]$ch) % 97
    }
    return $remainder -eq 1
}

function Test-LuhnCard {
    param([string]$Number)
    $Number = ($Number -replace '[\s-]','')
    if ($Number -notmatch '^\d{13,19}$') { return $false }
    $sum = 0
    $alt = $false
    for ($i = $Number.Length - 1; $i -ge 0; $i--) {
        $d = [int][string]$Number[$i]
        if ($alt) {
            $d *= 2
            if ($d -gt 9) { $d -= 9 }
        }
        $sum += $d
        $alt = -not $alt
    }
    return ($sum % 10) -eq 0
}

function Mask-Sensitive {
    # La versione precedente conservava i primi 2 caratteri, gli ultimi 2 E la
    # lunghezza esatta. Su un codice fiscale i primi due caratteri sono le
    # consonanti del cognome, e nella stessa riga del report c'è il percorso
    # completo del file (tipicamente ...\Clienti\Rossi Mario\...): la
    # combinazione rende il dato re-identificabile. Ai sensi dell'art. 4(1)
    # GDPR quel report resta un dato personale pseudonimizzato, non anonimo.
    #
    # Ora: solo le ultime 2 cifre e lunghezza NORMALIZZATA, così il valore serve
    # a riconoscere il tipo di dato senza ricostruirlo.
    param([string]$Value, [int]$KeepEnd = 2)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value.Length -le $KeepEnd) { return ('*' * 8) }
    return ('*' * 8) + $Value.Substring($Value.Length - $KeepEnd)
}

Export-ModuleMember -Function Test-CodiceFiscale, Test-PartitaIva, Test-Iban, Test-LuhnCard, Mask-Sensitive
