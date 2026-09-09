#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Demarre les VMs du lab ServiceDesk selon un profil d'execution.

.DESCRIPTION
    L'hote ne dispose que de 16 Go : toutes les VMs ne peuvent pas tourner
    ensemble. Le script applique les profils definis au cadrage du projet et
    refuse de demarrer si la RAM disponible est insuffisante.

    DC01 demarre TOUJOURS en premier, et le script attend qu'il reponde avant
    de lancer les autres. Raison : les clients ont besoin du DNS et de
    l'authentification du domaine des leur demarrage. Un client qui demarre
    sans DC disponible met en cache un echec, journalise des erreurs, et peut
    ouvrir une session avec des informations d'identification mises en cache au
    lieu d'une vraie authentification - ce qui faussera vos diagnostics.

.PARAMETER LabProfile
    A  : DC01 + CLI01                 (~6,5 Go) - usage quotidien
    B  : DC01 + CLI01 + CLI02         (~10 Go)  - GPO, droits, comparaisons
    C  : DC01 + CLI01 + SRV-LNX01     (~8 Go)   - ticketing GLPI
    DC : DC01 seul                    (~2 Go)   - travail sur l'annuaire

.PARAMETER VMName
    Liste explicite de VMs, qui remplace le profil.

.PARAMETER DCTimeoutSeconds
    Delai d'attente de la disponibilite de DC01. Defaut : 180.

.PARAMETER SkipDCWait
    Ne pas attendre DC01 (utile quand aucun systeme n'est encore installe).

.EXAMPLE
    .\Start-SDLab.ps1
    Demarre le profil A : DC01 puis CLI01.

.EXAMPLE
    .\Start-SDLab.ps1 -LabProfile DC
    Demarre uniquement le controleur de domaine.

.NOTES
    Projet : ServiceDesk Lab
    Pensez a fermer BlueStacks et les navigateurs lourds avant de demarrer le lab.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Profil')]
param(
    [Parameter(ParameterSetName = 'Profil')]
    [ValidateSet('A', 'B', 'C', 'DC')]
    [string] $LabProfile = 'A',

    [Parameter(ParameterSetName = 'Explicite', Mandatory)]
    [string[]] $VMName,

    [ValidateRange(30, 900)]
    [int] $DCTimeoutSeconds = 180,

    [switch] $SkipDCWait
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Profils d'execution - voir docs/00-analyse-phase0.md
# ---------------------------------------------------------------------------
$profiles = @{
    'A'  = @('DC01', 'CLI01')
    'B'  = @('DC01', 'CLI01', 'CLI02')
    'C'  = @('DC01', 'CLI01', 'SRV-LNX01')
    'DC' = @('DC01')
}

$targets = if ($PSCmdlet.ParameterSetName -eq 'Explicite') { $VMName } else { $profiles[$LabProfile] }

Write-Host ''
Write-Host '=== Demarrage du lab ServiceDesk ===' -ForegroundColor Cyan
if ($PSCmdlet.ParameterSetName -eq 'Profil') {
    Write-Host ("  Profil : {0}" -f $LabProfile)
}
Write-Host ("  VMs    : {0}" -f ($targets -join ', '))

# ---------------------------------------------------------------------------
# Controle de la RAM disponible
# ---------------------------------------------------------------------------
$freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB

$neededGB = 0
foreach ($name in $targets) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq 'Off') { $neededGB += $vm.MemoryStartup / 1GB }
}

Write-Host ("  RAM libre : {0:N1} Go   |   requise au demarrage : {1:N1} Go" -f $freeGB, $neededGB)

if ($neededGB -gt 0 -and $freeGB -lt ($neededGB + 1)) {
    Write-Host ''
    Write-Warning ("RAM insuffisante : {0:N1} Go libres pour {1:N1} Go requis (+1 Go de marge)." -f $freeGB, $neededGB)
    Write-Host '  Fermez BlueStacks, les navigateurs et les VMs inutiles, puis relancez.' -ForegroundColor Cyan
    Write-Host '  Ou demarrez un profil plus leger : -LabProfile DC' -ForegroundColor Cyan
    Write-Host ''
    return
}

Write-Host ''

# ---------------------------------------------------------------------------
# DC01 en premier, puis attente de sa disponibilite
# ---------------------------------------------------------------------------
function Start-LabVM {
    param([string] $Name)

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Host ("{0,-12} inexistante, ignoree." -f $Name) -ForegroundColor DarkGray
        return $false
    }
    if ($vm.State -eq 'Running') {
        Write-Host ("{0,-12} deja demarree." -f $Name) -ForegroundColor DarkGray
        return $true
    }

    # $PSCmdlet n'existe pas dans une fonction non avancee : on s'appuie sur
    # $WhatIfPreference, qui est herite de la portee du script appelant.
    if ($WhatIfPreference) {
        Write-Host ("{0,-12} serait demarree (WhatIf)." -f $Name) -ForegroundColor DarkGray
        return $false
    }

    Start-VM -Name $Name
    Write-Host ("{0,-12} demarree." -f $Name) -ForegroundColor Green
    return $true
}

if ($targets -contains 'DC01') {

    $null = Start-LabVM -Name 'DC01'

    if (-not $SkipDCWait -and (Get-VM -Name DC01 -ErrorAction SilentlyContinue).State -eq 'Running') {

        Write-Host '             attente de la disponibilite de DC01...' -NoNewline

        $elapsed = 0
        $ready   = $false

        while (-not $ready -and $elapsed -lt $DCTimeoutSeconds) {

            Start-Sleep -Seconds 5
            $elapsed += 5

            # Le composant d'integration "Pulsation" (Heartbeat) passe a OkApplicationsHealthy
            # quand le systeme d'invite a fini de demarrer ses services.
            $hb = Get-VMIntegrationService -VMName DC01 -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'Heartbeat|Pulsation' }

            if ($hb -and $hb.PrimaryStatusDescription -like 'Ok*') { $ready = $true }
        }

        if ($ready) { Write-Host (" pret ({0} s)." -f $elapsed) -ForegroundColor Green }
        else        { Write-Host (" pas de reponse apres {0} s (systeme non installe ?)." -f $elapsed) -ForegroundColor Yellow }
    }
}

# ---------------------------------------------------------------------------
# Les autres VMs
# ---------------------------------------------------------------------------
foreach ($name in ($targets | Where-Object { $_ -ne 'DC01' })) {
    $null = Start-LabVM -Name $name
}

# ---------------------------------------------------------------------------
# Resume
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Etat du lab ===' -ForegroundColor Cyan
Get-VM | Sort-Object Name |
    Select-Object Name, State,
                  @{n='RAM assignee'; e={ '{0:N0} Mo' -f ($_.MemoryAssigned / 1MB) }},
                  Uptime |
    Format-Table -AutoSize

Write-Host ("RAM libre sur l'hote : {0:N1} Go" -f ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB))
Write-Host ''
Write-Host 'Ouvrir une console :  vmconnect.exe localhost DC01' -ForegroundColor DarkGray
Write-Host ''
