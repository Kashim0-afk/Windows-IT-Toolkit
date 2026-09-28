# 05-ProfileMigrator

Esporta dati profilo utente per migrazione tra PC. **v1: solo export**, l'import sarà v2.

## Cosa fa (v1)

Esporta in una cartella destinazione (default: `Migration-<computer>-<timestamp>` sul **Desktop** dell'utente; modificabile con "Sfoglia"). Se scegli una cartella preesistente, l'export crea comunque una sottocartella `Migration-*` dedicata per non alterare i permessi di quella cartella.

- **Outlook:** registry profili (`HKCU\...\Outlook\Profiles\*` via `reg export`), signatures (`%APPDATA%\Microsoft\Signatures`), elenco PST (no copia per ridurre dimensione export — copia manuale o robocopy esterno).
- **Browser:** bookmark di Chrome ed Edge (solo bookmark); per Firefox `places.sqlite`, che include preferiti **e la cronologia completa di navigazione**.
- **Mappature SMB:** export Clixml di `Get-SmbMapping`.
- **WiFi:** profili XML, opzionalmente con password in chiaro (`netsh wlan export profile key=clear`).
- **Stampanti:** export Clixml di `Get-Printer` + `Get-PrinterPort`.

Manifest `manifest.json` riassume cosa è stato esportato.

## ⚠️ Dati sensibili — leggere prima di consegnare l'export

La cartella di export contiene **dati personali e credenziali in chiaro**:

- **Password WiFi (PSK) in chiaro** negli XML, se spunti "con le password in chiaro".
- **Profili e account Outlook** (server, indirizzi, blob di configurazione) nei `.reg`.
- **Cronologia di navigazione** completa (Firefox `places.sqlite`).
- **Mappa della rete interna** (share UNC, unità mappate) nelle mappature SMB.

Precauzioni applicate dal tool e a carico del tecnico:

- Il tool **irrigidisce l'ACL NTFS** della cartella (accesso solo a utente corrente + SYSTEM + Administrators) e avvisa se non ci riesce.
- Su **USB FAT32/exFAT le ACL non esistono**: le password restano leggibili da chiunque colleghi il supporto. Il tool lo segnala; **cifra l'export** (7-Zip con password) o usa un volume NTFS.
- Non lasciare l'export su PC condivisi; **cancellalo** dopo la migrazione.
- L'export finisce fuori dal repository (Desktop/USB). Come rete di sicurezza il `.gitignore` esclude comunque `Migration-*/`, `**/WiFi/*.xml`, `manifest.json` e `**/data/exports/`.

## Cosa NON fa (v1)

- **Import sul PC destinazione** (TODO v2).
- Non copia automaticamente PST (file potenzialmente molto grandi). Solo lista path.
- Non migra account 365 / OST (vanno ricreati con account Microsoft sulla destinazione).
- Non sovrascrive senza conferma.

## TODO v2

- Pacchetto cifrato 7z con password.
- Funzione "Importa da pacchetto" sul PC destinazione.
- Wizard a passi guidati (sorgente → trasporto → destinazione).
- Inclusione PST opzionale con check spazio.

## Cosa NON sostituisce

DiskGenius (clone disco) per migrazione hardware identico. Questo tool serve quando il PC destinazione ha **già un OS preinstallato** e si vuole solo trasferire dati utente.

## Output

- Cartella destinazione (scelta dall'utente)
- `data/audit/audit-YYYYMM.jsonl`
- `data/logs/profile-migrator.log`

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → seleziona destinazione + categorie → "Esporta"

## Rollback

Tool read-only sulla SORGENTE: non modifica nulla sul PC corrente. La destinazione viene scritta — se serve annullare, basta cancellare la cartella destinazione.

---

## English

Exports a user profile for migration between PCs. **v1: export only**, import is planned for v2.

### What it does (v1)

Exports to a destination folder (default: `Migration-<computer>-<timestamp>` on the user's **Desktop**; changeable via "Browse"). If you pick an existing folder, the export still creates a dedicated `Migration-*` subfolder so it never alters that folder's permissions.

- **Outlook:** profile registry keys (`HKCU\...\Outlook\Profiles\*` via `reg export`), signatures (`%APPDATA%\Microsoft\Signatures`), and a list of PST files (not copied, to keep the export small — copy them manually or with robocopy).
- **Browser:** Chrome and Edge bookmarks (bookmarks only); for Firefox, `places.sqlite`, which includes bookmarks **and the full browsing history**.
- **SMB mappings:** Clixml export of `Get-SmbMapping`.
- **WiFi:** profile XML files, optionally with cleartext passwords (`netsh wlan export profile key=clear`).
- **Printers:** Clixml export of `Get-Printer` + `Get-PrinterPort`.

A `manifest.json` summarizes what was exported.

### Requirements

- Windows PowerShell 5.1+ and .NET Framework 4 (verified by `setup.bat`).
- Administrator rights are optional: without them the tool still works, but WiFi profiles for *all* users and some system registry keys are unavailable.

### Usage

1. `setup.bat` (first run).
2. `start.bat` → choose the destination + categories → "Export".
3. Use "Preview" to see what would be exported without writing any file (read-only).

### ⚠️ Sensitive data — read before handing over the export

The export folder contains **personal data and cleartext credentials**:

- **Cleartext WiFi passwords (PSK)** in the XML files, if you tick "with cleartext passwords".
- **Outlook profiles and accounts** (servers, addresses, configuration blobs) in the `.reg` files.
- **Full browsing history** (Firefox `places.sqlite`).
- **Internal network map** (UNC shares, mapped drives) in the SMB mappings.

Safeguards applied by the tool and by the technician:

- The tool **hardens the folder's NTFS ACL** (access limited to the current user + SYSTEM + Administrators) and warns if it cannot.
- On **FAT32/exFAT USB drives there are no ACLs**: passwords stay readable by anyone who plugs the drive in. The tool flags this — **encrypt the export** (7-Zip with a password) or use an NTFS volume.
- Do not leave the export on shared PCs; **delete it** after the migration.
- The export lands outside the repository (Desktop/USB). As a safety net the `.gitignore` still excludes `Migration-*/`, `**/WiFi/*.xml`, `manifest.json` and `**/data/exports/`.

### What it does NOT do (v1)

- Import on the destination PC (planned for v2).
- Automatically copy PST files (potentially very large) — it only lists their paths.
- Migrate Microsoft 365 / OST accounts (recreate them with the Microsoft account on the destination).
- Overwrite without confirmation.

### Rollback

Read-only on the SOURCE: it changes nothing on the current PC. Only the destination is written — to undo, delete the destination folder.
