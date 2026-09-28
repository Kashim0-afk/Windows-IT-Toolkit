# 02-PrinterScanner

Scopre le stampanti di rete tramite probe TCP e identifica marca/modello, per facilitare l'installazione manuale (non automatica).

## Cosa fa

- Auto-rileva la subnet del PC (IPv4 non virtuale).
- Permette di specificare un range IP (es. `192.168.1.1-254`).
- Probe TCP veloce sulle porte stampanti: `9100` (RAW), `631` (IPP), `515` (LPD), `80`/`443` (admin web). Nessun probe SNMP (porta 161).
- Per ogni device che risponde, prova a leggere il banner HTTP per identificare il produttore (HP/Brother/Canon/Epson/Xerox/Lexmark/Kyocera/Konica Minolta/Ricoh/Samsung/OKI).
- Mostra lista risultati con IP, hostname, produttore, porte aperte.
- Esporta risultati in CSV.

## Cosa NON fa (di proposito)

- **Non scarica driver da internet** automaticamente.
- **Non installa code di stampa.** La discovery non aggiunge stampanti al sistema: l'installazione resta un'azione manuale del tecnico.
- **Non fa SNMP probe attivo** invasivo (solo TCP connect + HTTP banner, "rumore" minimo).

Doppio click su una stampante trovata → apre l'interfaccia web di amministrazione del device (`http`/`https`, sola consultazione), da cui il tecnico può proseguire con l'installazione manuale tramite il **Universal Print Driver** del produttore.

## Requisiti

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+
- Connessione alla rete da scansionare

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat`

## Output

- Log: `data/logs/printer-scanner.log`
- Audit: `data/audit/audit-YYYYMM.jsonl`
- Report CSV: `data/reports/printers-<timestamp>.csv`

## Note operative

- **Autorizzazione richiesta:** non eseguire scan su reti di clienti senza preavviso scritto. Alcuni IDS/firewall aziendali segnalano scan TCP come attività sospetta.
- Timeout per porta: 250ms (configurabile in GUI).
- Scan sequenziale per ora; v2 prevede runspace pool per parallelismo.

## Rollback

Nessuno: discovery è puramente read-only sulla rete (nessuna modifica sui device).

---

## English

### 02-PrinterScanner

Discovers network printers via TCP probing and identifies make/model, to make manual (not automatic) installation easier.

#### What it does

- Auto-detects the PC's subnet (non-virtual IPv4).
- Lets you specify an IP range (e.g. `192.168.1.1-254`).
- Fast TCP probe on printer ports: `9100` (RAW), `631` (IPP), `515` (LPD), `80`/`443` (web admin). No SNMP probe (port 161).
- For each responding device, tries to read the HTTP banner to identify the manufacturer (HP/Brother/Canon/Epson/Xerox/Lexmark/Kyocera/Konica Minolta/Ricoh/Samsung/OKI and others), with a MAC/OUI fallback.
- Shows a result list with IP, hostname, manufacturer, MAC and open ports.
- Exports results to CSV.

#### What it does NOT do (by design)

- **Does not download drivers from the internet** automatically.
- **Does not install print queues.** Discovery does not add printers to the system: installation remains a manual action by the technician.
- **Does not perform invasive active SNMP probing** (only TCP connect + HTTP banner, minimal "noise").

Double-clicking a discovered printer opens the device's web administration interface (`http`/`https`, read-only), from which the technician can proceed with manual installation using the manufacturer's **Universal Print Driver**.

#### Requirements

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+
- Connectivity to the network being scanned

#### Getting started

1. `setup.bat` (first time)
2. `start.bat`

#### Output

- Log: `data/logs/printer-scanner.log`
- Audit: `data/audit/audit-YYYYMM.jsonl`
- CSV report: `data/reports/printers-<timestamp>.csv`

#### Operational notes

- **Authorisation required:** do not scan client networks without written notice. Some corporate IDS/firewalls flag TCP scans as suspicious activity.
- Per-port timeout: 250ms.
- The scan is sequential for now; a runspace pool for parallelism is planned for v2.

#### Rollback

None: discovery is purely read-only on the network (no changes to the devices).
