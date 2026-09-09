#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Supprime le reseau virtuel du lab ServiceDesk (NAT, adresse hote, commutateur).

.DESCRIPTION
    Demonte ce que New-SDLabNetwork.ps1 a construit, dans l'ordre inverse :
    regle pare-feu, NAT, adresse de la carte hote, puis commutateur virtuel.

    Utile pour repartir d'un etat propre, ou pour retester l'idempotence du script
    de creation.

    Ce script MODIFIE la configuration reseau de l'hote : il demande donc
    confirmation (ConfirmImpact High). Utilisez -WhatIf pour voir sans agir,
    ou -Confirm:$false pour l'enchainer dans un script.

.PARAMETER SwitchName
    Nom du commutateur virtuel a supprimer. Defaut : LAB-Internal

.PARAMETER NatName
    Nom de la regle NAT a supprimer. Defaut : LAB-NAT

.EXAMPLE
    .\Remove-SDLabNetwork.ps1 -WhatIf
    Montre ce qui serait supprime, sans rien toucher.

.EXAMPLE
    .\Remove-SDLabNetwork.ps1
    Supprime le reseau du lab, avec confirmation.

.NOTES
    Projet : ServiceDesk Lab - Phase 1
    ATTENTION : supprimer le commutateur deconnecte toutes les VMs qui y sont reliees.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $SwitchName = 'LAB-Internal',

    [ValidateNotNullOrEmpty()]
    [string] $NatName = 'LAB-NAT',

    [ValidateNotNullOrEmpty()]
    [string] $FirewallRuleName = 'LAB-Internal - ICMPv4 Echo Request (entrant)'
)

$ErrorActionPreference = 'Stop'
$adapterName = "vEthernet ($SwitchName)"

# Avertissement si des VMs utilisent encore le commutateur
$attached = Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue |
            Where-Object SwitchName -eq $SwitchName

if ($attached) {
    $names = ($attached.VMName | Sort-Object -Unique) -join ', '
    Write-Warning "Ces VMs sont reliees a '$SwitchName' et perdront le reseau : $names"
}

# --- 1/4 Regle pare-feu ------------------------------------------------------
Write-Host '[1/4] Regle pare-feu ICMP' -ForegroundColor Yellow
$fw = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
if ($fw) {
    if ($PSCmdlet.ShouldProcess($FirewallRuleName, 'Supprimer la regle pare-feu')) {
        $fw | Remove-NetFirewallRule -Confirm:$false
        Write-Host '      Supprimee.' -ForegroundColor Green
    }
}
else { Write-Host '      Absente, rien a faire.' -ForegroundColor DarkGray }

# --- 2/4 NAT -----------------------------------------------------------------
Write-Host '[2/4] Regle NAT' -ForegroundColor Yellow
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($nat) {
    if ($PSCmdlet.ShouldProcess($NatName, 'Supprimer la regle NAT')) {
        Remove-NetNat -Name $NatName -Confirm:$false
        Write-Host '      Supprimee.' -ForegroundColor Green
    }
}
else { Write-Host '      Absente, rien a faire.' -ForegroundColor DarkGray }

# --- 3/4 Adresse de la carte hote -------------------------------------------
Write-Host '[3/4] Adresse de la carte hote' -ForegroundColor Yellow
$adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
if ($adapter) {
    $ips = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike '169.254.*' }
    if ($ips) {
        if ($PSCmdlet.ShouldProcess($adapterName, 'Retirer les adresses IPv4')) {
            $ips | Remove-NetIPAddress -Confirm:$false
            Write-Host '      Retirees.' -ForegroundColor Green
        }
    }
    else { Write-Host '      Aucune adresse fixe, rien a faire.' -ForegroundColor DarkGray }
}
else { Write-Host '      Carte absente, rien a faire.' -ForegroundColor DarkGray }

# --- 4/4 Commutateur virtuel -------------------------------------------------
Write-Host '[4/4] Commutateur virtuel' -ForegroundColor Yellow
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch) {
    if ($PSCmdlet.ShouldProcess($SwitchName, 'Supprimer le commutateur virtuel')) {
        Remove-VMSwitch -Name $SwitchName -Force
        Write-Host '      Supprime.' -ForegroundColor Green
    }
}
else { Write-Host '      Absent, rien a faire.' -ForegroundColor DarkGray }

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Reseau du lab demonte.' -ForegroundColor Green
    Write-Host ''
}
