# 03-PCAudit

Genera un report HTML completo del PC in 30-90 secondi. **Read-only puro** — nessuna modifica al sistema.

## Cosa fa

Raccoglie e visualizza in tab + esporta in HTML stilizzato:

- **Hardware:** produttore, modello, seriale, BIOS version+data, baseboard, CPU (core/thread/freq), RAM totale + moduli (size/marca/freq/PN), GPU (con VRAM), dischi (con HealthStatus + MediaType + BusType), adapter di rete fisici (con MAC + speed).
- **Sistema:** edizione Windows, build (con UBR), DisplayVersion, install date, architettura, lingua, licenza Windows (Licensed/OOB/etc.), uptime, ultimo HotFix.
- **Sicurezza:** BitLocker (status + percentuale + recovery key se admin), Antivirus (da SecurityCenter2), Firewall (3 profili), Secure Boot, TPM (presenza/ready/version).
- **Rete:** IP per interfaccia, DNS server, gateway/route, mappature SMB, stampanti installate.
- **Utenti:** utenti locali, membri Administrators, profili utente con LastUse.
- **Software:** programmi installati da registry uninstall (HKLM 32+64 bit), conteggio + tabella primi 100.

## Cosa NON fa

- Non modifica il sistema. Tutto read-only.
- Non invia dati su rete. Output esclusivamente locale in `data/reports/`.
- Non legge file utente o email.

## Limiti senza admin

Se lanciato senza privilegi amministrativi:
- BitLocker recovery key non disponibile (mostrato "(richiede admin)").
- Alcune info TPM/Secure Boot possono mancare.

L'app funziona comunque: essendo read-only, una banner informativa (blu) in alto segnala che da amministratore raccoglierebbe qualche dato in più (nessun avviso di rischio, perché non modifica nulla).

## Requisiti

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+

## Avvio

1. `setup.bat` (prima volta).
2. `start.bat` → GUI.
3. Premi "Esegui audit" per avviare la raccolta (richiede ~30-90s, gira in background senza bloccare la finestra).
4. Naviga le tab per i dettagli.
5. "Esporta HTML" salva un report stilizzato in `data/reports/audit-<computer>-<timestamp>.html`.

## Output

- `data/reports/audit-<computer>-<timestamp>.html` — report formattato
- `data/logs/pc-audit.log` — log sessione
- `data/audit/audit-YYYYMM.jsonl` — audit trail strutturato

## Rollback

Nessuno: tool completamente read-only.

---

## English

### 03-PCAudit

Generates a complete HTML report of the PC in 30-90 seconds. **Pure read-only** — no changes to the system.

#### What it does

Collects and shows in tabs + exports to styled HTML:

- **Hardware:** manufacturer, model, serial, BIOS version+date, baseboard, CPU (cores/threads/freq), total RAM + modules (size/brand/freq/PN), GPU (with VRAM), disks (with HealthStatus + MediaType + BusType), physical network adapters (with MAC + speed).
- **System:** Windows edition, build (with UBR), DisplayVersion, install date, architecture, language, Windows license (Licensed/OOB/etc.), uptime, last HotFix.
- **Security:** BitLocker (status + percentage + recovery key if admin), Antivirus (from SecurityCenter2), Firewall (3 profiles), Secure Boot, TPM (present/ready/version).
- **Network:** IP per interface, DNS servers, gateway/route, SMB mappings, installed printers.
- **Users:** local users, Administrators members, user profiles with LastUse.
- **Software:** programs installed from the registry uninstall keys (HKLM 32+64 bit), count + table of the first 100.

#### What it does NOT do

- Does not modify the system. Everything is read-only.
- Does not send data over the network. Output stays strictly local in `data/reports/`.
- Does not read user files or email.

#### Limits without admin

If launched without administrative privileges:
- BitLocker recovery key not available (shown as "(richiede admin)").
- Some TPM/Secure Boot info may be missing.

The app still works: being read-only, an informational banner (blue) at the top notes that running as administrator would collect a little more data (no risk warning, since it changes nothing).

#### Requirements

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+

#### Getting started

1. `setup.bat` (first time).
2. `start.bat` → GUI.
3. Press "Esegui audit" to start collection (~30-90s, runs in the background without freezing the window).
4. Browse the tabs for details.
5. "Esporta HTML" saves a styled report in `data/reports/audit-<computer>-<timestamp>.html`.

#### Output

- `data/reports/audit-<computer>-<timestamp>.html` — formatted report
- `data/logs/pc-audit.log` — session log
- `data/audit/audit-YYYYMM.jsonl` — structured audit trail

The HTML report is written with restricted NTFS permissions (owner + SYSTEM + Administrators) because it may contain the BitLocker recovery key in clear text; if the permissions cannot be applied, the tool asks for confirmation before saving.

#### Rollback

None: fully read-only tool.
