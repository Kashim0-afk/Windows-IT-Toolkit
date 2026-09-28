# 01-DriverUpdater

Scopre driver mancanti o problematici e indica come aggiornarli **dalle fonti ufficiali**.

## Cosa fa

- Scansiona i dispositivi del PC (`Get-PnpDevice`) — operazione **read-only**.
- Identifica quelli in stato `Error`, `Degraded`, `Unknown`.
- Riconosce il vendor del PC (Dell, HP, Lenovo, ASUS, Acer, MSI, Microsoft) e apre il link al tool OEM ufficiale.
- Apertura rapida di Windows Update e Gestione Dispositivi.
- Esporta un report CSV.

## Cosa NON fa (di proposito)

- **Non scarica driver da internet.** I driver vanno presi solo da Windows Update o dal tool OEM ufficiale, mai da fonti generiche o "compatibili forzati".
- **Non installa nulla automaticamente.**
- **Non modifica il sistema in alcun modo.**

È un tool diagnostico. L'installazione effettiva si fa via flusso OEM/Microsoft ufficiale.

## Requisiti

- Windows 10/11
- PowerShell 5.1+ (preinstallato)
- .NET Framework 4.7+ (preinstallato)

## Avvio

1. Prima volta: doppio click su `setup.bat` (verifica prerequisiti).
2. Sempre: doppio click su `start.bat` per aprire la GUI.

## Output

- Log sessione: `data/logs/driver-updater.log`
- Report CSV: `data/reports/driver-report-<timestamp>.csv`

## Rollback

Nessuno: il tool è completamente read-only.

---

## English

### 01-DriverUpdater

Discovers missing or malfunctioning drivers and shows how to update them **from official sources**.

#### What it does

- Scans the PC's devices (`Get-PnpDevice`) — a **read-only** operation.
- Identifies devices in `Error`, `Degraded` or `Unknown` state (real PnP problem codes).
- Recognises the PC vendor (Dell, HP, Lenovo, ASUS, Acer, MSI, Microsoft) and opens the link to the official OEM update tool.
- Quick shortcuts to Windows Update and Device Manager.
- Optional `winget upgrade` scan to list updatable applications (double-click a row to copy the `winget upgrade --id <Id>` command; "Update all" opens an elevated terminal running `winget upgrade --all`, never silently in the background).
- Exports a CSV report.

#### What it does NOT do (by design)

- **Does not download drivers from the internet.** Drivers should only come from Windows Update or the official OEM tool, never from generic or "force-compatible" sources.
- **Does not install anything automatically.**
- **Does not modify the system in any way.**

It is a diagnostic tool; the actual installation happens through the official OEM/Microsoft flow.

#### Requirements

- Windows 10/11
- PowerShell 5.1+ (preinstalled)
- .NET Framework 4.7+ (preinstalled)

#### Getting started

1. First time: double-click `setup.bat` (checks prerequisites).
2. Every time: double-click `start.bat` to open the GUI.

#### Output

- Session log: `data/logs/driver-updater.log`
- CSV report: `data/reports/driver-report-<timestamp>.csv`

#### Rollback

None: the tool is completely read-only.
