# 08-BackupVerifier

Verifica lo stato dei principali sistemi di backup installati. Read-only puro.

## Cosa fa

Controlla, in best-effort:
- **Macrium Reflect** — log XML in `%ProgramData%\Macrium\Reflect\Logs\`. Estrae status ultimo job.
- **Veeam Agent** — Event Log Windows (`Veeam Agent` o provider `Veeam Endpoint Backup Service`). Ultimo evento, livello (Errore/Warning/OK).
- **Acronis** — solo detection installazione in v1 (parsing SQLite TODO v2).
- **Windows Server Backup** — `Get-WBJob -Previous 5` (solo su Windows Server con feature installata).

Ogni sistema viene mostrato con: rilevato sì/no, stato ultimo job, timestamp, dettaglio.

## Cosa NON fa (di proposito)

- Non avvia, sospende, modifica o cancella backup.
- Non scrive nei job esistenti.
- Non monta backup (TODO v2 con conferma esplicita).

## Schedulazione automatica (TODO v2)

Possibile integrazione futura: lancio via Task Scheduler ogni mattina, output via SMTP al tecnico.

## Output

- `data/reports/backup-check-<timestamp>.txt`
- `data/audit/audit-YYYYMM.jsonl`
- `data/logs/backup-verifier.log`

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → verifica automatica all'apertura

## Rollback

Nessuno: read-only.

---

## English

Checks the status of the main backup systems installed on the machine. Strictly read-only.

### What it does

Best-effort inspection of:
- **Macrium Reflect** — XML logs in `%ProgramData%\Macrium\Reflect\Logs\`. Extracts the last job status.
- **Veeam Agent** — Windows Event Log (`Veeam Agent` log, or the `Veeam Endpoint Backup Service` provider). Reports the *worst* event in the window (not just the most recent), so an informational entry logged right after a failure cannot mask a failed backup.
- **Acronis** — installation detection only in v1 (SQLite log parsing is planned for v2).
- **Windows Server Backup** — `Get-WBJob -Previous 5` (only on Windows Server with the feature installed).

Each system is shown with: detected yes/no, last job status, timestamp, and detail. A failed job is highlighted with both colour and text.

### What it does NOT do (by design)

- Never starts, pauses, modifies, or deletes backups.
- Never writes to existing jobs.
- Never mounts backups (planned for v2, with explicit confirmation).

### Requirements

- Windows with PowerShell 5.1+ and .NET Framework 4.
- Administrator rights are **not** required (pure read-only tool).

### Usage

1. Run `setup.bat` once (checks prerequisites).
2. Run `start.bat` → the check runs automatically on open.
3. Optionally export a plain-text report with **Export TXT**.

### Output

- `data/reports/backup-check-<timestamp>.txt`
- `data/audit/audit-YYYYMM.jsonl`
- `data/logs/backup-verifier.log`

### Warnings

- The TXT report lists which backup systems exist, whether they work, and where their logs live — exactly the reconnaissance that precedes a ransomware attack. It is written with a restricted ACL (owner + SYSTEM + Administrators); treat and store it accordingly.
- Backup-software logs under `%ProgramData%` are treated as untrusted input: XML is parsed with DTD and external entities disabled (XXE/SSRF/zip-bomb hardening).

### Rollback

None: read-only.
