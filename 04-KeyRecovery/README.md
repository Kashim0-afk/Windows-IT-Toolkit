# 04-KeyRecovery

Recupera chiavi e credenziali archiviate localmente prima di un reinstall/migrazione. **Read-only puro**, output solo locale.

## Cosa fa (v1)

- **Windows OEM Key (BIOS):** chiave originale di fabbrica embedded in BIOS via `SoftwareLicensingService.OA3xOriginalProductKey`. Sempre disponibile per PC OEM (Dell/HP/Lenovo/ASUS ecc.) preinstallati.
- **Windows DigitalProductId decoder (legacy):** decoder algoritmo standard. Per Windows 10/11 con licenza digitale può NON corrispondere alla licenza reale (Microsoft non archivia la chiave in plain text). Utile come fallback informativo.
- **Stato licenza Windows:** prodotto, partial key, status (Licensed/OOB Grace/etc.), channel.
- **Profili WiFi salvati:** SSID, autenticazione, cifratura, password (in chiaro) tramite `netsh wlan show profile name=X key=clear`.

Output:
- `data/reports/keys-<computer>-<timestamp>.json` — formato strutturato
- `data/reports/keys-<computer>-<timestamp>.txt` — formato leggibile

## Cosa NON fa (v1, TODO v2)

- **Office product key:** richiede parser specifico per MSI vs Click-to-Run. Office moderno (365/Click-to-Run) non ha chiave recuperabile (è legato all'account Microsoft).
- **Browser saved passwords:** richiedono accesso DPAPI specifico utente. Implementabile ma con consenso esteso e impatto sicurezza maggiore.
- **Cifratura output:** v2 aggiungerà output con password.

## Vincoli operativi

- **Consenso obbligatorio:** all'avvio del recovery viene chiesto consenso esplicito. Se "No", l'operazione viene annullata e auditata.
- **Audit log:** ogni concessione/negazione consenso e ogni esportazione vengono registrate in `data/audit/audit-YYYYMM.jsonl`.
- **Output locale:** mai trasmesso su rete. Resta in `data/reports/` finché l'utente non lo cancella.

## Requisiti

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → GUI

## Implicazioni GDPR / sicurezza

Tool che maneggia dati sensibili. Best practice:
- Dopo l'utilizzo, conserva il report cifrato (es. 7z con password) e cancella l'originale dalla cartella `data/reports/`.
- Non lasciare il PC con il report visibile.
- Valuta cancellazione automatica dopo X giorni per ridurre superficie di rischio.

## Rollback

Nessuno: tool completamente read-only.

---

## English

### 04-KeyRecovery

Recovers keys and credentials stored locally before a reinstall/migration. **Pure read-only**, local output only.

> **Legal / authorisation note:** this tool reads sensitive data (Windows product key, BitLocker recovery key, saved WiFi passwords in clear text). Use it **only on your own machines or on client machines with explicit, written consent from the owner.** On startup, an explicit consent dialog is shown; if declined, the operation is cancelled and audited.

#### What it does (v1)

- **Windows OEM Key (BIOS):** original factory key embedded in the BIOS via `SoftwareLicensingService.OA3xOriginalProductKey`. Always available on preinstalled OEM PCs (Dell/HP/Lenovo/ASUS, etc.).
- **Windows DigitalProductId decoder (legacy):** standard-algorithm decoder. For Windows 10/11 with a digital license it may NOT match the real license (Microsoft no longer stores the key in clear text). Useful as an informational fallback.
- **Windows license status:** product, partial key, status (Licensed/OOB Grace/etc.), channel.
- **Saved WiFi profiles:** SSID, authentication, cipher, password (in clear text) via `netsh wlan export profile ... key=clear`. The clear-text passwords are only returned when running as administrator; as a standard user the field reports that elevation is required.

Output:
- `data/reports/keys-<computer>-<timestamp>.json` — structured format
- `data/reports/keys-<computer>-<timestamp>.txt` — readable format

#### What it does NOT do (v1, TODO v2)

- **Office product key:** requires a specific parser for MSI vs Click-to-Run. Modern Office (365/Click-to-Run) has no recoverable key (it is tied to the Microsoft account).
- **Browser saved passwords:** require user-specific DPAPI access. Feasible but with broader consent and a larger security impact.
- **Output encryption:** v2 will add password-protected output.

#### Operational constraints

- **Consent mandatory:** on starting recovery, explicit consent is requested. If "No", the operation is cancelled and audited.
- **Audit log:** every consent grant/denial and every export is recorded in `data/audit/audit-YYYYMM.jsonl`.
- **Local output:** never transmitted over the network. It stays in `data/reports/` until the user deletes it. Report files are written with restricted NTFS permissions (owner + SYSTEM + Administrators); if that cannot be applied, the tool asks for confirmation before saving.

#### Requirements

- Windows 10/11
- PowerShell 5.1+
- .NET Framework 4.7+

#### Getting started

1. `setup.bat` (first time)
2. `start.bat` → GUI

#### GDPR / security implications

A tool that handles sensitive data. Best practices:
- After use, keep the report encrypted (e.g. 7z with a password) and delete the original from `data/reports/`.
- Do not leave the PC with the report visible.
- Consider automatic deletion after X days to reduce the risk surface.

#### Rollback

None: fully read-only tool.
