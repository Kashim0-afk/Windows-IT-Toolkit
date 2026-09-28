# 10-GDPRScanner

Scansiona cartelle locali alla ricerca di dati personali italiani con **validazione checksum** (no falsi positivi). Read-only puro.

## Cosa fa

Cerca con regex + checksum:
- **Codice Fiscale** (16 char + checksum letterale).
- **Partita IVA** (11 cifre + algoritmo standard).
- **IBAN** (qualsiasi nazione, validazione mod 97).
- **Carta di credito** (Luhn).
- **Email** (regex, no checksum standard).

I risultati vengono mostrati con esempi **mascherati** (es. `RS***********501Z`) per non esporre i dati direttamente nella GUI / report.

## File supportati

- `.txt`, `.csv`, `.log`, `.ini`, `.json`, `.xml`, `.html`/`.htm`, `.eml` — lettura diretta
- `.docx` — parsing tramite ZIP + XML (`word/document.xml`)
- `.xlsx` — parsing tramite ZIP + XML (`xl/sharedStrings.xml` + `xl/worksheets/sheet*.xml`)
- `.pdf` — TODO v2 (richiede libreria esterna)
- `.msg` (Outlook) — TODO v2

Skip automatico file > 50 MB.

## Cosa NON fa

- Non modifica file scansionati.
- Non legge contenuto fuori dalla cartella scelta.
- Non trasmette dati sulla rete.
- Non salva in chiaro: report HTML/CSV ha solo esempi mascherati.

## Output

- `data/reports/gdpr-<timestamp>.html` — report stilizzato con sintesi
- `data/reports/gdpr-<timestamp>.csv` — formato strutturato (per import in Excel)
- `data/audit/audit-YYYYMM.jsonl`

## Implicazioni operative

Durante lo scan, il tool è "data processor" temporaneo. Best practice:
- Esegui solo con consenso scritto del cliente.
- Cancella i report dopo l'uso o cifrali con 7z.
- Non lasciare il PC con report aperto.

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → seleziona cartella → "Avvia scansione"

## Rollback

Nessuno: read-only.

---

## English

Scans local folders for Italian personal data using **regex + checksum validation** (to suppress false positives). Strictly read-only.

### What it does

Detects, with regex plus checksum where applicable:
- **Codice Fiscale** (16 chars + control-character checksum, including *omocodia* letter substitutions).
- **Partita IVA** (11 digits + standard Luhn-style checksum).
- **IBAN** (any country, mod-97 validation).
- **Credit card** (Luhn, 13–19 digits).
- **Email** (regex; no standard checksum exists).

Findings are shown with **masked** examples (e.g. `********1Z`) so raw data is never exposed in the GUI or reports.

### Supported files

- `.txt`, `.csv`, `.log`, `.ini`, `.json`, `.xml`, `.html`/`.htm`, `.eml` — read directly.
- `.docx` — parsed via ZIP + XML (`word/document.xml`); runs within a paragraph are joined without separators so a code split across `<w:t>` runs is still detected.
- `.xlsx` — parsed via ZIP + XML (`xl/sharedStrings.xml` + `xl/worksheets/sheet*.xml`), handling shared strings, inline strings, and formula results.
- `.pdf`, `.msg` — planned for v2.
- Files larger than 50 MB are skipped and **counted as not-verified** (not treated as clean).

### What it does NOT do

- Never modifies scanned files.
- Never reads outside the chosen folder (junctions/symlinks are not followed; every path is contained under the selected root).
- Never sends data over the network.
- Never stores data in clear text: HTML/CSV reports contain only masked examples.

### Requirements

- Windows with PowerShell 5.1+ and .NET Framework 4.
- Administrator rights are **not** required (pure read-only tool).

### Usage

1. Run `setup.bat` once (checks prerequisites).
2. Run `start.bat` → choose a folder → select data types → **Start scan**.
3. Export results as **HTML** or **CSV** if needed.

### Output

- `data/reports/gdpr-<timestamp>.html` — styled report with a summary.
- `data/reports/gdpr-<timestamp>.csv` — structured format (for import into Excel).
- `data/audit/audit-YYYYMM.jsonl`

### Operational implications

During a scan the tool acts as a temporary data processor. Best practice:
- Run only with the client's written consent.
- Delete reports after use, or encrypt them (e.g. with 7-Zip).
- Do not leave the machine unattended with a report open.
- Reports list the exact paths of files containing personal data — a map of what to exfiltrate. They are written with a restricted ACL (owner + SYSTEM + Administrators); if the ACL cannot be applied, the tool warns you.

### Not-verified accounting

The result distinguishes *clean* from *not verified*: password-protected or corrupt Office files, oversized files, unreadable files, and inaccessible folders are counted separately and reported in the status bar and log — so "no personal data found" is never a half-truth.

### Rollback

None: read-only.
