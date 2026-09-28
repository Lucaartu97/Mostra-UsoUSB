<#
.SINOPSI
    Mostra quali programmi, processi e finestre stanno usando una chiavetta USB
    (o qualsiasi unità), per capire cosa impedisce la "Rimozione sicura".

.USO
    .\Mostra-UsoUSB.ps1              -> chiede quale unità rimovibile analizzare
    .\Mostra-UsoUSB.ps1 -Unita D     -> analizza direttamente D:
    .\Mostra-UsoUSB.ps1 -Unita D -Chiudi   -> al termine propone di chiudere i processi trovati

.NOTE
    - Non servono tool esterni: usa l'API "Restart Manager" di Windows per i file aperti.
    - Se nella stessa cartella dello script (o nel PATH) c'è handle.exe di Sysinternals,
      viene usato anche quello: trova pure i processi che hanno solo la "cartella corrente"
      sulla chiavetta (es. un cmd/PowerShell aperto in D:\), cosa che Restart Manager non vede.
    - Esegui come Amministratore per vedere anche i processi di sistema/altri utenti.
#>

[CmdletBinding()]
param(
    [string]$Unita,
    [switch]$Chiudi,
    [int]$MaxFile = 20000
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Titolo($testo) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Host " $testo" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 1. Scelta dell'unità
# ---------------------------------------------------------------------------
if (-not $Unita) {
    $rimovibili = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2"
    if (-not $rimovibili) {
        Write-Host "Nessuna unità rimovibile trovata. Specifica -Unita <lettera>." -ForegroundColor Yellow
        return
    }
    if (@($rimovibili).Count -eq 1) {
        $Unita = $rimovibili.DeviceID
    } else {
        Write-Host "Unità rimovibili trovate:"
        $rimovibili | ForEach-Object { Write-Host ("  {0}  {1}  ({2:N0} MB)" -f $_.DeviceID, $_.VolumeName, ($_.Size / 1MB)) }
        $Unita = Read-Host "Quale unità vuoi analizzare? (es. D)"
    }
}

$Unita = $Unita.Trim().TrimEnd(':', '\').ToUpper()
if ($Unita.Length -ne 1) { Write-Host "Lettera unità non valida: '$Unita'" -ForegroundColor Red; return }
$Root = "$Unita`:\"
if (-not (Test-Path $Root)) { Write-Host "L'unità $Root non esiste o non è accessibile." -ForegroundColor Red; return }

$disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Unita`:'"
Write-Titolo "Analisi unità $Root  [$($disco.VolumeName)]  $(Get-Date -Format 'HH:mm:ss')"

# Raccolta dei PID trovati: PID -> insieme di motivi
$trovati = @{}
function Add-Trovato([int]$ProcId, [string]$Motivo) {
    if ($ProcId -le 0) { return }
    if (-not $trovati.ContainsKey($ProcId)) { $trovati[$ProcId] = New-Object System.Collections.Generic.List[string] }
    if (-not $trovati[$ProcId].Contains($Motivo)) { $trovati[$ProcId].Add($Motivo) }
}

# ---------------------------------------------------------------------------
# 2. Finestre di Esplora file aperte sull'unità
# ---------------------------------------------------------------------------
Write-Titolo "Finestre di Esplora file aperte su $Root"
$shell = New-Object -ComObject Shell.Application
$finestre = @()
foreach ($w in $shell.Windows()) {
    $url = $w.LocationURL
    if ($url) {
        $percorso = [Uri]::UnescapeDataString($url) -replace '^file:///', '' -replace '/', '\'
        if ($percorso -like "$Unita`:*") {
            $finestre += [pscustomobject]@{ PID = $w.HWND; Percorso = $percorso }
            Add-Trovato (Get-Process explorer | Select-Object -First 1).Id "Finestra Esplora file su $percorso"
        }
    }
}
if ($finestre) { $finestre | ForEach-Object { Write-Host "  [Esplora file]  $($_.Percorso)" -ForegroundColor Yellow } }
else { Write-Host "  Nessuna." -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 3. Processi il cui eseguibile si trova sull'unità
# ---------------------------------------------------------------------------
Write-Titolo "Programmi avviati DALL'unità $Root"
$daUnita = Get-Process | Where-Object { $_.Path -like "$Unita`:*" }
if ($daUnita) {
    $daUnita | ForEach-Object {
        Write-Host ("  PID {0,-7} {1,-25} {2}" -f $_.Id, $_.ProcessName, $_.Path) -ForegroundColor Yellow
        Add-Trovato $_.Id "Eseguibile su $($_.Path)"
    }
} else { Write-Host "  Nessuno." -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 4. Processi con DLL/moduli caricati dall'unità
# ---------------------------------------------------------------------------
Write-Titolo "Processi con DLL o moduli caricati da $Root"
$conModuli = 0
foreach ($p in Get-Process) {
    $mod = $p.Modules | Where-Object { $_.FileName -like "$Unita`:*" }
    if ($mod) {
        $conModuli++
        Write-Host ("  PID {0,-7} {1}" -f $p.Id, $p.ProcessName) -ForegroundColor Yellow
        $mod | ForEach-Object { Write-Host "            $($_.FileName)" -ForegroundColor DarkYellow }
        Add-Trovato $p.Id "Modulo caricato: $(($mod | Select-Object -First 1).FileName)"
    }
}
if ($conModuli -eq 0) { Write-Host "  Nessuno." -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 5. Processi con la riga di comando che cita l'unità (es. "app.exe D:\file.txt")
# ---------------------------------------------------------------------------
Write-Titolo "Processi con l'unità $Root nella riga di comando"
$cmdLine = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "(?i)$Unita`:\\" -and $_.ExecutablePath -notlike "$Unita`:*" }
if ($cmdLine) {
    $cmdLine | ForEach-Object {
        Write-Host ("  PID {0,-7} {1,-25} {2}" -f $_.ProcessId, $_.Name, $_.CommandLine) -ForegroundColor Yellow
        Add-Trovato ([int]$_.ProcessId) "Riga di comando: $($_.CommandLine)"
    }
} else { Write-Host "  Nessuno." -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 6. File aperti sull'unità (API Restart Manager, nativa di Windows)
# ---------------------------------------------------------------------------
Write-Titolo "Processi che tengono aperti file su $Root (Restart Manager)"

if (-not ('UsbCheck.RM' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace UsbCheck {
public static class RM {
    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
}
}
"@
}

function Get-ProcessiCheUsanoFile([string[]]$Files) {
    $risultato = @()
    $sessione = 0
    $chiave = [Guid]::NewGuid().ToString()
    if ([UsbCheck.RM]::RmStartSession([ref]$sessione, 0, $chiave) -ne 0) { return $risultato }
    try {
        if ([UsbCheck.RM]::RmRegisterResources($sessione, [uint32]$Files.Count, $Files, 0, $null, 0, $null) -ne 0) { return $risultato }
        $needed = [uint32]0; $count = [uint32]0; $reasons = [uint32]0
        $rc = [UsbCheck.RM]::RmGetList($sessione, [ref]$needed, [ref]$count, $null, [ref]$reasons)
        if ($rc -eq 234 -and $needed -gt 0) {   # ERROR_MORE_DATA
            $count = $needed
            $info = New-Object 'UsbCheck.RM+RM_PROCESS_INFO[]' $count
            $rc = [UsbCheck.RM]::RmGetList($sessione, [ref]$needed, [ref]$count, $info, [ref]$reasons)
            if ($rc -eq 0) { $risultato = $info[0..($count - 1)] }
        }
    } finally { [UsbCheck.RM]::RmEndSession($sessione) | Out-Null }
    return $risultato
}

Write-Host "  Enumerazione file su $Root ..." -ForegroundColor DarkGray
$fileList = @(Get-ChildItem -Path $Root -Recurse -File -Force | Select-Object -First $MaxFile -ExpandProperty FullName)
Write-Host "  $($fileList.Count) file da controllare$(if ($fileList.Count -ge $MaxFile) { " (limite -MaxFile raggiunto)" })." -ForegroundColor DarkGray

$rmTrovati = @{}
$batch = 500
for ($i = 0; $i -lt $fileList.Count; $i += $batch) {
    $fine = [Math]::Min($i + $batch, $fileList.Count) - 1
    $pezzo = $fileList[$i..$fine]
    $procs = Get-ProcessiCheUsanoFile $pezzo
    if ($procs) {
        # Ripeto file per file solo sul blocco che ha dato risultati, per sapere QUALE file
        foreach ($f in $pezzo) {
            foreach ($pi in (Get-ProcessiCheUsanoFile @($f))) {
                $id = $pi.Process.dwProcessId
                if (-not $rmTrovati.ContainsKey($id)) { $rmTrovati[$id] = @{ Nome = $pi.strAppName; File = New-Object System.Collections.Generic.List[string] } }
                $rmTrovati[$id].File.Add($f)
                Add-Trovato $id "File aperto: $f"
            }
        }
    }
}
if ($rmTrovati.Count) {
    foreach ($id in $rmTrovati.Keys) {
        $nomeProc = (Get-Process -Id $id).ProcessName
        Write-Host ("  PID {0,-7} {1}  ({2})" -f $id, $nomeProc, $rmTrovati[$id].Nome) -ForegroundColor Yellow
        $rmTrovati[$id].File | ForEach-Object { Write-Host "            $_" -ForegroundColor DarkYellow }
    }
} else { Write-Host "  Nessun file aperto rilevato." -ForegroundColor Green }

# ---------------------------------------------------------------------------
# 7. (Opzionale) handle.exe di Sysinternals: vede anche cartelle correnti e handle di directory
# ---------------------------------------------------------------------------
Write-Titolo "Handle aperti su $Root (handle.exe Sysinternals, se presente)"
$handleExe = Join-Path $PSScriptRoot 'handle.exe'
if (-not (Test-Path $handleExe)) { $handleExe = Join-Path $PSScriptRoot 'handle64.exe' }
if (-not (Test-Path $handleExe)) { $handleExe = (Get-Command handle.exe, handle64.exe | Select-Object -First 1).Source }

if ($handleExe -and (Test-Path $handleExe)) {
    $out = & $handleExe -accepteula -nobanner "$Unita`:\" 2>$null
    $righe = $out | Where-Object { $_ -match '^\s*(\S+)\s+pid:\s*(\d+)\s+type:\s*(\w+)\s+(.*?)\s*:\s*(.+)$' -or $_ -match '^(\S+)\s+pid:\s*(\d+)\s+type:\s*(\w+)\s+\S+\s+(\S+):\s+(.+)$' }
    if ($out -match 'No matching handles found') { Write-Host "  Nessun handle trovato." -ForegroundColor Green }
    elseif ($out) {
        foreach ($r in $out) {
            if ($r -match 'pid:\s*(\d+)') {
                Write-Host "  $r" -ForegroundColor Yellow
                Add-Trovato ([int]$Matches[1]) "Handle (handle.exe): $r"
            }
        }
        Write-Host "  (Nota: i processi con solo la 'cartella corrente' sulla chiavetta compaiono qui come 'type: File' su una directory.)" -ForegroundColor DarkGray
    } else { Write-Host "  Nessun output (prova a eseguire come Amministratore)." -ForegroundColor DarkGray }
} else {
    Write-Host "  handle.exe non trovato: salto. Per un controllo ancora più completo scaricalo da" -ForegroundColor DarkGray
    Write-Host "  https://learn.microsoft.com/sysinternals/downloads/handle e mettilo accanto a questo script." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 8. Riepilogo
# ---------------------------------------------------------------------------
Write-Titolo "RIEPILOGO: processi che bloccano $Root"
if ($trovati.Count -eq 0) {
    Write-Host "  Nessun processo rilevato. Se l'espulsione fallisce ancora, i sospetti tipici sono:" -ForegroundColor Green
    Write-Host "   - antivirus / Windows Defender in scansione, Indicizzazione di Windows (SearchIndexer)"
    Write-Host "   - un prompt cmd/PowerShell/terminale con la cartella corrente sulla chiavetta"
    Write-Host "   - anteprima/miniature di Esplora file, sincronizzazione cloud (OneDrive, ecc.)"
    Write-Host "   - eseguire lo script come Amministratore mostra anche i processi di sistema"
} else {
    $riepilogo = foreach ($id in $trovati.Keys) {
        $p = Get-Process -Id $id
        [pscustomobject]@{
            PID      = $id
            Processo = if ($p) { $p.ProcessName } else { '(terminato)' }
            Finestra = if ($p -and $p.MainWindowTitle) { $p.MainWindowTitle } else { '' }
            Motivi   = ($trovati[$id] -join ' | ')
        }
    }
    $riepilogo | Sort-Object Processo | Format-Table -AutoSize -Wrap

    if ($Chiudi) {
        foreach ($r in ($riepilogo | Where-Object { $_.Processo -notin 'explorer', 'System', 'svchost', '(terminato)' })) {
            $risposta = Read-Host "Chiudere $($r.Processo) (PID $($r.PID))? [s/N]"
            if ($risposta -match '^[sS]') {
                Stop-Process -Id $r.PID -Force
                Write-Host "  Chiuso PID $($r.PID)." -ForegroundColor Green
            }
        }
        if ($riepilogo.Processo -contains 'explorer') {
            Write-Host "  Per Esplora file: chiudi manualmente le finestre aperte sulla chiavetta (non termino explorer.exe)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Suggerimento: rilancia con -Chiudi per terminare i processi uno a uno (con conferma)." -ForegroundColor DarkGray
    }
}
Write-Host ""
