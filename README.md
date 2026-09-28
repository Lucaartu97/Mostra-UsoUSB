# Mostra-UsoUSB

Script PowerShell per scoprire **quali programmi, processi e finestre stanno usando una chiavetta USB** e impediscono la "Rimozione sicura dell'hardware".

Quando Windows mostra il messaggio *"Dispositivo attualmente in uso. Chiudere tutti i programmi o le finestre che potrebbero utilizzare il dispositivo e riprovare"*, questo script ti dice esattamente **chi** è il colpevole e **perché**.

Non richiede tool esterni: usa solo PowerShell e l'API **Restart Manager** integrata in Windows.

## Requisiti

- Windows 10 / 11
- Windows PowerShell 5.1 (preinstallato) o PowerShell 7+
- Facoltativo: [`handle.exe`](https://learn.microsoft.com/sysinternals/downloads/handle) di Sysinternals per un controllo ancora più completo (vedi sotto)

## Utilizzo

Apri PowerShell nella cartella dello script ed esegui:

```powershell
# Rileva automaticamente la chiavetta (chiede quale, se ce n'è più di una)
.\Mostra-UsoUSB.ps1

# Analizza direttamente l'unità D:
.\Mostra-UsoUSB.ps1 -Unita D

# Al termine propone di chiudere i processi trovati, uno a uno, con conferma
.\Mostra-UsoUSB.ps1 -Unita D -Chiudi
```

Se PowerShell blocca l'esecuzione degli script:

```powershell
powershell -ExecutionPolicy Bypass -File .\Mostra-UsoUSB.ps1 -Unita D
```

Esegui come **Amministratore** per vedere anche i processi di sistema e di altri utenti.

### Parametri

| Parametro  | Descrizione                                                                                   | Default |
|------------|-----------------------------------------------------------------------------------------------|---------|
| `-Unita`   | Lettera dell'unità da analizzare (es. `D` o `D:`). Se omessa, cerca le unità rimovibili.      | auto    |
| `-Chiudi`  | Al termine chiede, processo per processo, se terminarlo. `explorer.exe` non viene mai chiuso. | off     |
| `-MaxFile` | Numero massimo di file da controllare con Restart Manager. Alza il valore su chiavette grandi. | 20000   |

## Cosa controlla

Lo script esegue, in ordine, questi controlli e alla fine mostra un riepilogo con PID, nome del processo, titolo della finestra e motivo del blocco.

1. **Finestre di Esplora file** aperte su una cartella della chiavetta.
2. **Programmi avviati dalla chiavetta** (eseguibile che risiede sull'unità).
3. **DLL o moduli caricati** dalla chiavetta da qualsiasi processo.
4. **Riga di comando** che cita l'unità (es. un editor aperto su `D:\documento.txt`).
5. **File tenuti aperti**, tramite l'API Restart Manager di Windows: per ogni processo elenca i file coinvolti.
6. **Handle aperti** con `handle.exe`, se presente accanto allo script o nel `PATH`.

### Perché usare anche handle.exe

Restart Manager vede i *file* aperti, ma non le *cartelle*. Un prompt `cmd`, un terminale o una finestra PowerShell che ha semplicemente la cartella corrente sulla chiavetta (es. `D:\>`) blocca l'espulsione senza tenere aperto nessun file. Solo `handle.exe` riesce a rilevare questo caso.

Per abilitarlo, scarica `handle.exe` da Sysinternals e copialo nella stessa cartella dello script: verrà usato automaticamente.

## Esempio di output

```
======================================================================
 RIEPILOGO: processi che bloccano D:\
======================================================================

  PID Processo Finestra                        Motivi
  --- -------- --------                        ------
11904 Code     ROADMAP.md - Visual Studio Code Riga di comando: "...\Code.exe" "D:\code\ROADMAP.md"

  Suggerimento: rilancia con -Chiudi per terminare i processi uno a uno (con conferma).
```

## Se non trova nulla

Se lo script non rileva processi ma l'espulsione fallisce ancora, i sospetti tipici sono:

- antivirus o Windows Defender in scansione, indicizzazione di Windows (`SearchIndexer`)
- un `cmd` / PowerShell / terminale con la cartella corrente sulla chiavetta (serve `handle.exe`)
- anteprime e miniature di Esplora file, sincronizzazione cloud (OneDrive e simili)
- lo script non è stato eseguito come Amministratore

## Licenza

MIT
