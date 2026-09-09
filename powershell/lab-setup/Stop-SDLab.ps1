#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Arrete proprement les VMs du lab ServiceDesk, pour liberer la RAM de l'hote.

.DESCRIPTION
    Arrete les VMs dans l'ordre inverse de leur dependance : les clients d'abord,
    le controleur de domaine en dernier. Un client qui perd son DC en cours de
    session journalise des erreurs d'authentification inutiles.

    L'arret est TOUJOURS gracieux (Stop-VM), jamais une coupure d'alimentation :
    Active Directory est une base de donnees transactionnelle, la couper
    brutalement peut corrompre NTDS.dit.

    Les VMs sans systeme installe ne repondent pas a la demande d'arret : elles
    sont signalees, et seul -Force les eteint.

.PARAMETER VMName
    VMs a arreter, dans l'ordre. Defaut : CLI02, CLI01, SRV-LNX01, DC01.

.PARAMETER TimeoutSeconds
    Delai accorde a chaque VM pour s'arreter. Defaut : 180.

.PARAMETER Force
    Coupe l'alimentation des VMs qui n'ont pas repondu dans le delai.
    A n'utiliser que sur une VM sans systeme installe, ou reellement bloquee.

.EXAMPLE
    .\Stop-SDLab.ps1
    Arrete toutes les VMs du lab proprement.

.EXAMPLE
    .\Stop-SDLab.ps1 -VMName CLI01
    Arrete uniquement CLI01.

.NOTES
    Projet : ServiceDesk Lab
    Le reseau virtuel et le NAT ne sont PAS demontes : ils ne consomment rien
    et DC01 en a besoin au prochain demarrage.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $VMName = @('CLI02', 'CLI01', 'SRV-LNX01', 'DC01'),

    [ValidateRange(30, 900)]
    [int] $TimeoutSeconds = 180,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '=== Arret du lab ServiceDesk ===' -ForegroundColor Cyan

$before = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
Write-Host ("  RAM libre avant : {0} Go" -f $before)
Write-Host ''

$pending = @()

foreach ($name in $VMName) {

    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Host ("{0,-12} inexistante, ignoree." -f $name) -ForegroundColor DarkGray
        continue
    }

    if ($vm.State -eq 'Off') {
        Write-Host ("{0,-12} deja arretee." -f $name) -ForegroundColor DarkGray
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($name, 'Arreter proprement la VM')) { continue }

    Write-Host ("{0,-12} arret en cours..." -f $name) -NoNewline

    # Stop-VM demande au systeme d'invite de s'arreter via le composant
    # d'integration "Arret". Sans systeme installe, personne ne repond.
    Stop-VM -Name $name -ErrorAction SilentlyContinue

    $elapsed = 0
    while ((Get-VM -Name $name).State -ne 'Off' -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
    }

    if ((Get-VM -Name $name).State -eq 'Off') {
        Write-Host (" arretee ({0} s)." -f $elapsed) -ForegroundColor Green
    }
    else {
        Write-Host ' PAS ARRETEE.' -ForegroundColor Yellow
        $pending += $name
    }
}

# --- VMs recalcitrantes ----------------------------------------------------
if ($pending) {

    Write-Host ''
    Write-Warning ("Ces VMs n'ont pas repondu a la demande d'arret : {0}" -f ($pending -join ', '))
    Write-Host '  Causes possibles :' -ForegroundColor DarkGray
    Write-Host '    - aucun systeme installe (la VM ne peut pas repondre)' -ForegroundColor DarkGray
    Write-Host '    - installation en cours' -ForegroundColor DarkGray
    Write-Host '    - systeme bloque' -ForegroundColor DarkGray

    if (-not $Force) {
        Write-Host ''
        Write-Host '  Relancez avec -Force pour couper leur alimentation.' -ForegroundColor Cyan
        Write-Host '  ATTENTION : ne le faites JAMAIS sur un controleur de domaine' -ForegroundColor Yellow
        Write-Host '  dont le systeme fonctionne : risque de corruption de NTDS.dit.' -ForegroundColor Yellow
    }
    else {
        foreach ($name in $pending) {
            if ($PSCmdlet.ShouldProcess($name, "COUPER L'ALIMENTATION (risque de perte de donnees)")) {
                Stop-VM -Name $name -TurnOff -Force
                Write-Host ("{0,-12} alimentation coupee." -f $name) -ForegroundColor Yellow
            }
        }
    }
}

# --- Resume ----------------------------------------------------------------
Write-Host ''
Write-Host '=== Etat final ===' -ForegroundColor Cyan
Get-VM | Sort-Object Name |
    Select-Object Name, State, @{n='RAM assignee'; e={ '{0:N0} Mo' -f ($_.MemoryAssigned / 1MB) }} |
    Format-Table -AutoSize

Start-Sleep -Seconds 2
$after = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
Write-Host ("RAM libre : {0} Go  ->  {1} Go   (+{2} Go)" -f $before, $after, [math]::Round($after - $before, 1)) -ForegroundColor Green
Write-Host ''
Write-Host 'Le reseau virtuel du lab reste en place : il ne consomme rien.' -ForegroundColor DarkGray
Write-Host ''
