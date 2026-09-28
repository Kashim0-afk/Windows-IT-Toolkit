# 06-NetworkTriage

Diagnosi guidata problemi di rete con verdetto interpretato in italiano. Read-only puro.

## Cosa fa

Esegue in sequenza:
1. **Configurazione IP** locale (interfaccia, IP, mask).
2. **Gateway** ping.
3. **DNS interno** (primo DNS configurato): risoluzione di `www.microsoft.com`.
4. **DNS esterno** ping a 8.8.8.8 e 1.1.1.1.
5. **Risoluzione DNS pubblica** (default DNS Windows).
6. **HTTP** test a `msftconnecttest.com` (lo stesso che usa Windows per detection captive portal).
7. **HTTPS** test a `microsoft.com`.
8. **Proxy WinINET** stato.

Per ogni test fallito, suggerisce in italiano dove probabilmente sta il problema (es. "Il DNS configurato non risolve. Prova a impostare 8.8.8.8 o riavvia il router.").

Verdetto finale: primo problema rilevato + numero test falliti.

## Cosa NON fa

- Non modifica la configurazione di rete.
- Non disconnette / reconnects adapter.
- Non resetta DNS, gateway o proxy.

Se ti serve azione, hai bottoni rapidi che aprono Network Settings o lanciano `ipconfig /all` in nuova finestra.

## Output

- `data/logs/network-triage.log`
- `data/audit/audit-YYYYMM.jsonl`
- `data/reports/triage-<timestamp>.txt` (export TXT)

## Avvio

1. `setup.bat` (prima volta)
2. `start.bat` → click "Avvia diagnosi"

## Rollback

Nessuno: read-only.

---

## English

Guided network diagnostics with a plain-language verdict. Purely read-only.

### What it does

Runs, in sequence:
1. **Local IP configuration** (interface, IP, mask).
2. **Gateway** ping.
3. **Internal DNS** (first configured DNS): resolves `www.microsoft.com`.
4. **External DNS** ping to 8.8.8.8 and 1.1.1.1.
5. **Public DNS resolution** (Windows default DNS).
6. **HTTP** test to `msftconnecttest.com` (the same endpoint Windows uses for captive-portal detection).
7. **HTTPS** test to `microsoft.com` (negotiates TLS 1.2 to avoid false failures).
8. **WinINET proxy** status.

For each failed test it suggests, in plain language, where the problem likely is. The final verdict shows the first problem detected plus the number of failed tests.

### What it does NOT do

- It does not change the network configuration.
- It does not disconnect/reconnect adapters.
- It does not reset DNS, gateway or proxy.

Quick action buttons open Network Settings or launch `ipconfig /all` in a new window.

### Requirements

- Windows PowerShell 5.1+ and .NET Framework 4 (verified by `setup.bat`).
- No administrator rights required (read-only).

### Usage

1. `setup.bat` (first run).
2. `start.bat` → click "Run diagnostics".

### Output & sensitive data

- `data/logs/network-triage.log`
- `data/audit/audit-YYYYMM.jsonl`
- `data/reports/triage-<timestamp>.txt` (TXT export)

The TXT report and logs contain the internal IP, gateway, DNS servers, WinINET proxy, username and computer name — effectively a **map of the internal network**. They are written with a restricted NTFS ACL (current user + SYSTEM + Administrators) and are excluded from git. Handle and share them with care.

### Rollback

None: read-only.
