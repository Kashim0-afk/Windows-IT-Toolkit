# 07-SpoolerDoctor

Diagnosi e fix problemi di stampa. Diagnosi read-only, riparazione **con backup pre-modifica obbligatorio** e conferma esplicita.

## Cosa fa

### Modalità Diagnosi (read-only, no admin richiesto)

All'apertura mostra automaticamente:
- **Stato servizio Spooler** (Running/Stopped + StartType).
- **Stampanti installate** (nome, driver, porta, tipo, stato).
- **Job in coda** per ogni stampante.
- **Driver orfani** (driver installati non assegnati a nessuna stampante).
- **Conteggio file** nella spool dir (`%SystemRoot%\System32\spool\PRINTERS`).

### Modalità Risolvi (richiede admin)

Sequenza con backup + conferme:
1. **Avviso se ci sono job in coda** (verranno cancellati).
2. **Conferma operazione** (dialog Sì/No).
3. **Backup automatico** stato spooler in `data/backups/spooler-state-<timestamp>/` (printers.xml, drivers.xml, ports.xml).
4. **Stop spooler**.
5. **Svuota PRINTERS** (opzionale, attivo di default).
6. **Rimozione driver orfani** (opzionale, disattivato di default — più rischioso).
7. **Restart spooler**.
8. **Re-diagnosi** automatica.

## Cosa NON fa

- Non rimuove stampanti.
- Non rimuove driver in uso.
- Non opera senza conferma esplicita.
- Non opera senza backup.

## Test stampa

Bottone "Pagina di prova" → seleziona una stampante → lancia la pagina di prova nativa Windows.

## Rollback

Per ripristinare lo stato pre-modifica:
```powershell
$bk = "data\backups\spooler-state-XXXX"
Import-Clixml "$bk\printers.xml" | ForEach-Object { Add-Printer -Name $_.Name -DriverName $_.DriverName -PortName $_.PortName }
```

## Output

- `data/logs/spooler-doctor.log`
- `data/audit/audit-YYYYMM.jsonl` (ogni step della riparazione viene auditato)
- `data/backups/spooler-state-<timestamp>/` (backup pre-riparazione)

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → diagnosi automatica
3. Per riparare: lanciare con "Esegui come amministratore"

---

## English

Diagnose and fix printing problems. Diagnosis is read-only; repair requires a **mandatory pre-change backup** and explicit confirmation.

### Diagnosis mode (read-only, no admin required)

On launch it automatically shows:
- **Spooler service status** (Running/Stopped + StartType).
- **Installed printers** (name, driver, port, type, status).
- **Queued jobs** per printer.
- **Orphan drivers** (installed drivers not assigned to any printer).
- **File count** in the spool dir (`%SystemRoot%\System32\spool\PRINTERS`).

### Repair mode (requires admin)

Sequence with backup + confirmations:
1. **Warning if there are queued jobs** (they will be deleted).
2. **Operation confirmation** (Yes/No dialog).
3. **Automatic backup** of the spooler state to `data/backups/spooler-state-<timestamp>/` (printers.xml, drivers.xml, ports.xml).
4. **Stop spooler**.
5. **Empty PRINTERS** (optional, on by default).
6. **Remove orphan drivers** (optional, off by default — riskier; system drivers such as Microsoft Print To PDF are always excluded via a blacklist).
7. **Restart spooler** (always restarted, even if a previous step failed).
8. Automatic **re-diagnosis**.

The exact list of drivers to be removed is shown in the confirmation dialog, and only that approved set is removed. Orphan-driver removal can be cancelled between drivers; stop/empty/restart are intentionally not interruptible so the print system is never left broken.

### What it does NOT do

- It does not remove printers.
- It does not remove drivers in use.
- It never operates without explicit confirmation.
- It never operates without a backup.

### Test print

"Test page" button → select a printer → launches the native Windows test page. The printer name is validated against a character allowlist before use (a printer published by a hostile print server could otherwise inject switches into an elevated process).

### Requirements

- Windows PowerShell 5.1+ and .NET Framework 4 (verified by `setup.bat`).
- Administrator rights required for the "Repair" action; diagnosis works as a standard user.

### Output & sensitive data

- `data/logs/spooler-doctor.log`
- `data/audit/audit-YYYYMM.jsonl` (every repair step is audited)
- `data/backups/spooler-state-<timestamp>/` (pre-repair backup)

The backup XML files contain print-server names, UNC shares and TCP/IP port addresses — a map of the customer's print/network setup. They are written with a restricted NTFS ACL and excluded from git.

### Rollback

To restore the pre-change state:
```powershell
$bk = "data\backups\spooler-state-XXXX"
Import-Clixml "$bk\printers.xml" | ForEach-Object { Add-Printer -Name $_.Name -DriverName $_.DriverName -PortName $_.PortName }
```
