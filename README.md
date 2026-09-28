# Windows IT Toolkit

**10 utility con interfaccia grafica per il lavoro IT quotidiano su Windows 10/11.** Pensate per tecnici e sistemisti: nessuna dipendenza da installare, funzionano offline, sicure per impostazione predefinita.

🇬🇧 [Read this in English](#english)

---

## Perché

Il lavoro di un IT specialist è fatto di attività ripetitive: aggiornare driver, censire un PC, recuperare le chiavi prima di un reinstall, migrare un profilo, diagnosticare la rete, sistemare la coda di stampa. Questo toolkit le raccoglie in dieci strumenti con la stessa interfaccia, gli stessi principi di sicurezza e zero setup.

- **Zero dipendenze.** Solo PowerShell 5.1 + WPF, presenti su ogni Windows 10/11. Niente runtime da installare, funziona anche su una macchina appena formattata e offline.
- **Sicuri per impostazione predefinita.** Dove possibile i tool sono **read-only**. Le operazioni che modificano il sistema chiedono conferma, elevano i privilegi solo quando serve e registrano tutto.
- **Tracciabili.** Ogni tool scrive un **audit log con catena di hash** (`_shared/modules/Audit.psm1`): ogni voce include l'hash della precedente, quindi una manomissione si nota. Utile per assistenza e conformità.
- **Attenti ai dati.** Gli output con dati sensibili (chiavi, password WiFi, export di profili) restano in locale, in cartelle escluse dal versionamento, con file protetti a livello di ACL (owner-only).

## Gli strumenti

| # | Tool | Cosa fa | Modifica il sistema? |
|---|------|---------|----------------------|
| 01 | **DriverUpdater** | Censisce i driver e rileva il tool OEM (Dell/HP/Lenovo…) per l'aggiornamento | No (solo scansione) |
| 02 | **PrinterScanner** | Trova stampanti in rete e suggerisce il driver | No |
| 03 | **PCAudit** | Report HTML completo dell'hardware e del software del PC | No (read-only) |
| 04 | **KeyRecovery** | Recupera chiave Windows OEM, stato licenza e profili WiFi prima di un reinstall | No (read-only) |
| 05 | **ProfileMigrator** | Esporta profilo Outlook, browser, stampanti e mappe di rete tra due PC | Sì (export/import) |
| 06 | **NetworkTriage** | Diagnosi di rete guidata (DNS, gateway, connettività) | No |
| 07 | **SpoolerDoctor** | Risolve i problemi tipici della coda di stampa | Sì (servizio spooler) |
| 08 | **BackupVerifier** | Verifica i log di Macrium / Veeam / Acronis e segnala i backup falliti | No |
| 09 | **Decrapifier** | Debloat e configurazione post-installazione, guidato da profili | Sì (rimozione app) |
| 10 | **GDPRScanner** | Cerca dati personali su disco (codice fiscale, IBAN, carte, email…) | No (read-only) |

I tool che modificano il sistema chiedono sempre conferma e, dove ha senso, offrono un rollback.

## Come si usa

Nessun terminale, nessun comando da ricordare:

1. Doppio click su **`setup.bat`** (solo la prima volta) — verifica i prerequisiti.
2. Doppio click su **`start.bat`** — apre la GUI del tool.

## Architettura

```
UTILITIES/
├── _shared/                Codice comune a tutti i tool
│   ├── modules/            Common (admin, ACL), Logging, GUI (WPF), Audit (hash-chain)
│   └── assets/             Tema WPF + icone
├── NN-NomeTool/
│   ├── README.md           Documentazione del singolo tool (IT + EN)
│   ├── setup.bat           Verifica prerequisiti
│   ├── start.bat           Avvio con bypass execution policy
│   ├── src/
│   │   ├── Main.ps1        Entry point: carica la XAML e collega gli eventi
│   │   ├── MainWindow.xaml Interfaccia
│   │   └── modules/        Logica del tool (.psm1)
│   └── data/               Output/log/audit — SEMPRE esclusi dal repo
└── README.md
```

Ogni tool ha lo stesso scheletro e riusa i moduli condivisi, così l'esperienza è coerente e la manutenzione semplice.

## Requisiti

- Windows 10 o 11
- PowerShell 5.1+ (preinstallato)
- .NET Framework 4.7+ (preinstallato su Win10/11)
- Privilegi di amministratore solo per le operazioni che modificano il sistema

## Sicurezza e uso responsabile

Strumenti da **usare solo su sistemi propri o per cui si ha autorizzazione** (es. PC di un cliente in assistenza). Alcuni tool trattano dati sensibili (KeyRecovery, ProfileMigrator, GDPRScanner): conserva gli output in modo cifrato e cancellali quando non servono. Le cartelle `data/` non vengono mai versionate.

## Licenza

[MIT](LICENSE) © 2026 Matteo Zordan

---

<a name="english"></a>

# Windows IT Toolkit

**10 GUI utilities for day-to-day IT work on Windows 10/11.** Built for technicians and sysadmins: nothing to install, works offline, safe by default.

## Why

An IT specialist's day is full of repetitive tasks: update drivers, inventory a PC, recover keys before a reinstall, migrate a profile, diagnose the network, fix the print queue. This toolkit bundles them into ten tools that share one interface, the same safety principles and zero setup.

- **Zero dependencies.** Just PowerShell 5.1 + WPF, present on every Windows 10/11. No runtime to install; works on a freshly imaged, offline machine.
- **Safe by default.** Where possible the tools are **read-only**. System-changing actions ask for confirmation, elevate only when needed, and log everything.
- **Auditable.** Every tool writes a **hash-chained audit log** (`_shared/modules/Audit.psm1`): each entry embeds the hash of the previous one, so tampering is detectable — useful for support and compliance.
- **Data-aware.** Sensitive output (keys, WiFi passwords, profile exports) stays local, in folders excluded from version control, in ACL-protected owner-only files.

## The tools

| # | Tool | What it does | Changes the system? |
|---|------|--------------|---------------------|
| 01 | **DriverUpdater** | Inventories drivers and detects the OEM tool (Dell/HP/Lenovo…) to update them | No (scan only) |
| 02 | **PrinterScanner** | Finds network printers and suggests the driver | No |
| 03 | **PCAudit** | Full HTML report of the PC hardware and software | No (read-only) |
| 04 | **KeyRecovery** | Recovers Windows OEM key, license state and WiFi profiles before a reinstall | No (read-only) |
| 05 | **ProfileMigrator** | Exports Outlook profile, browsers, printers and network drives between two PCs | Yes (export/import) |
| 06 | **NetworkTriage** | Guided network diagnostics (DNS, gateway, connectivity) | No |
| 07 | **SpoolerDoctor** | Fixes common print-spooler problems | Yes (spooler service) |
| 08 | **BackupVerifier** | Parses Macrium / Veeam / Acronis logs and flags failed backups | No |
| 09 | **Decrapifier** | Post-install debloat and configuration, driven by profiles | Yes (app removal) |
| 10 | **GDPRScanner** | Scans the disk for personal data (tax code, IBAN, cards, emails…) | No (read-only) |

System-changing tools always ask for confirmation and, where it makes sense, offer a rollback.

## How to use it

No terminal, no commands to remember:

1. Double-click **`setup.bat`** (first time only) — checks prerequisites.
2. Double-click **`start.bat`** — opens the tool's GUI.

## Architecture

Each tool shares the same skeleton (`setup.bat`, `start.bat`, `src/Main.ps1`, `src/MainWindow.xaml`, `src/modules/*.psm1`) and reuses the shared modules in `_shared/` (admin/ACL helpers, logging, WPF GUI, hash-chained audit). Runtime output lives in each tool's `data/` folder, which is never committed.

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built in)
- .NET Framework 4.7+ (built in on Win10/11)
- Administrator rights only for system-changing actions

## Security and responsible use

Use these tools **only on systems you own or are authorized to service** (e.g. a client's PC). Some tools handle sensitive data (KeyRecovery, ProfileMigrator, GDPRScanner): keep their output encrypted and delete it when no longer needed. The `data/` folders are never version-controlled.

## License

[MIT](LICENSE) © 2026 Matteo Zordan
