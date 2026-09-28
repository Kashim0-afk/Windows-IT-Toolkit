# 09-Decrapifier

Rimozione bloatware da Windows 11 in base a profili JSON curati. **Anteprima sempre read-only**, applicazione **richiede admin + backup automatico**.

## Cosa fa (v1)

- Carica profilo JSON da `data/profiles/<nome>.json` (default: `default.json`).
- **Anteprima:** scansiona AppX installati, identifica quelli nella whitelist del profilo, mostra cosa verrebbe rimosso e cosa è già assente.
- **Applica (admin):** backup `Get-AppxPackage` + `Get-AppxProvisionedPackage` in `data/backups/appx-state-<timestamp>/`, poi `Remove-AppxPackage` per ogni target. Log di ogni rimozione (success/fail) in audit trail.

## Profilo `default.json`

Lista conservativa di Microsoft consumer apps tipiche di Win11 fresh install:
3DBuilder, BingNews, BingWeather, GetHelp, Getstarted, MicrosoftOfficeHub, SolitaireCollection, MixedReality.Portal, OneConnect, People, Print3D, Skype, FeedbackHub, YourPhone, ZuneMusic, ZuneVideo, Teams, Clipchamp, GamingApp, Xbox*, WindowsCommunicationsApps (Mail/Calendar), PowerAutomateDesktop.

**Esclude esplicitamente:** Calculator, Photos, Edge, Store, Camera (utili anche in ambienti aziendali).

Puoi creare profili custom (es. `studio.json`, `cantiere.json`) copiando `default.json` e modificando la lista.

## Cosa NON fa (v1, TODO v2)

- **Registry tweaks** (telemetry, Cortana, Edge Bing/Copilot rimozione) — richiedono backup `reg export` per chiave + studio impatto. Tracciato come task.
- **OneDrive** disable/configure.
- **Office Click-to-Run** install via ODT.
- **Software base** install via winget (lista hardcoded da definire).
- **Rinomina PC** secondo convenzione studio.
- **Pattern wildcard** sull'eliminazione: per design SOLO whitelist esatte.

## Garanzie do-no-harm

- **Mai pattern wildcard** sull'eliminazione: solo `Name -eq` esatto.
- **Backup automatico** prima di ogni rimozione.
- **Conferma esplicita** con elenco di cosa verrà fatto.
- **Audit log** di ogni step (`apply.step` per ogni AppX).
- L'anteprima è disponibile sempre, anche senza admin: si può controllare il piano prima di richiedere admin.

## Rollback

Per ripristinare un'AppX rimossa:
```powershell
$bk = "data\backups\appx-state-XXXX"
$pkg = Import-Clixml "$bk\appx-installed.xml" | Where-Object Name -eq 'Microsoft.YourPhone'
Add-AppxPackage -Path $pkg.InstallLocation\Appxmanifest.xml -Register
```

Oppure reinstall da Microsoft Store.

## Output

- `data/logs/decrapifier.log`
- `data/audit/audit-YYYYMM.jsonl`
- `data/backups/appx-state-<timestamp>/` (pre-modifica)

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → preview automatica
3. Per applicare: lanciare con "Esegui come amministratore"

---

## English

Removes Windows 11 bloatware based on curated JSON profiles. **Preview is always read-only**; applying changes **requires administrator rights and takes an automatic backup first**.

### What it does (v1)

- Loads a JSON profile from `data/profiles/<name>.json` (default: `default.json`).
- **Preview:** scans installed AppX packages, matches them against the profile whitelist, and shows what would be removed and what is already absent. Available without admin, so the plan can be reviewed before elevating.
- **Apply (admin):** backs up `Get-AppxPackage` + `Get-AppxProvisionedPackage` to `data/backups/appx-state-<timestamp>/`, then runs `Remove-AppxPackage` for each target. Every removal (success/fail) is written to the audit trail. The operation can be cancelled between packages.
- **Restore:** re-registers the most recent backup, both per-user packages and provisioned packages, when their files are still on disk.

### Safety guarantees (do-no-harm)

- **Never uses wildcards** for removal: exact `Name -eq` matches only (enforced by the profile validator, which rejects `*`/`?`).
- **Hardcoded critical-package blacklist** (Store, Edge, .NET/VCLibs/WinAppRuntime frameworks, Security UI, login brokers, shell hosts, etc.): even if a profile lists one of these, it is filtered out before removal, and re-checked immediately before each `Remove-AppxPackage`.
- **Automatic backup** before any removal.
- **Explicit confirmation** with the list of what will happen.
- **Audit log** of every step.
- Restore validates that each package's install location lies under a trusted system root before re-registering (the backup folder is treated as untrusted input) and caps backup file size against oversized-XML memory exhaustion.

### Profiles

- `default.json` — conservative Microsoft consumer apps typical of a fresh Win11 install (3DBuilder, Bing News/Weather/Search, GetHelp, Solitaire, MixedReality Portal, People, Print3D, Skype, Feedback Hub, Zune Music/Video, Clipchamp, the Xbox suite, etc.). Explicitly **keeps** Calculator, Photos, Edge, Store, Camera, Notepad.
- `aggressive.json` — also targets apps that some users need (Mail/Calendar, consumer Teams, Power Automate, Phone Link, Maps). Use **only** after confirming with the client that these apps are unused.
- Create custom profiles by copying `default.json`; do not edit `default.json` in place. The `data/profiles/*.json` files are tracked configuration and ship with the tool.

### Requirements

- Windows 11 with PowerShell 5.1+ and .NET Framework 4.
- **Administrator rights required** to Apply or Restore (Preview works as a standard user). The tool prompts to elevate at startup.

### Not in v1 (planned for v2)

Registry tweaks, OneDrive configuration, Office Click-to-Run install, winget base-software install, PC rename, wildcard removal (deliberately excluded — exact whitelist only).

### Output

- `data/logs/decrapifier.log`
- `data/audit/audit-YYYYMM.jsonl`
- `data/backups/appx-state-<timestamp>/` (pre-change state)

### Rollback

Use **Restore last backup** in the tool, or restore manually:
```powershell
$bk = "data\backups\appx-state-XXXX"
$pkg = Import-Clixml "$bk\appx-installed.xml" | Where-Object Name -eq 'Microsoft.YourPhone'
Add-AppxPackage -Path $pkg.InstallLocation\Appxmanifest.xml -Register
```
Or reinstall from the Microsoft Store.
