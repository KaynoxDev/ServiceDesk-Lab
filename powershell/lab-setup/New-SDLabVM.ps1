#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Cree les machines virtuelles du lab ServiceDesk, pretes a installer.

.DESCRIPTION
    Script IDEMPOTENT : une VM absente est creee, une VM deja presente et eteinte
    voit simplement sa configuration reappliquee (les cmdlets Set-* ne changent rien
    si la VM est deja conforme). Une VM allumee n'est jamais touchee.
    Cela permet de rattraper une execution precedente interrompue.

    Chaque VM est creee en Generation 2 (firmware UEFI), avec :
      - memoire dynamique bornee (indispensable avec 16 Go sur l'hote) ;
      - Secure Boot active, avec le modele de certificat adapte a l'OS ;
      - une puce TPM virtuelle pour les VMs Windows (obligatoire pour Windows 11) ;
      - l'ISO d'installation monte et place en premier peripherique de demarrage ;
      - les instantanes automatiques DESACTIVES et le type d'instantane en Production ;
      - aucun demarrage automatique avec l'hote.

    Le script ne DEMARRE pas les VMs : l'installation reste une operation manuelle,
    volontairement, car c'est une competence a acquerir.

.PARAMETER VM
    VMs a creer : DC01, CLI01, CLI02, SRV-LNX01, ou All. Defaut : All.
    Creez DC01 en premier si vous voulez avancer progressivement.

.PARAMETER VMPath
    Dossier racine des VMs. Defaut : A:\VMs

.PARAMETER IsoPath
    Dossier contenant les ISO d'installation. Defaut : C:\ISO

.PARAMETER SwitchName
    Commutateur virtuel auquel relier les VMs. Defaut : LAB-Internal

.EXAMPLE
    .\New-SDLabVM.ps1 -VM DC01
    Cree uniquement le controleur de domaine.

.EXAMPLE
    .\New-SDLabVM.ps1 -WhatIf
    Montre ce qui serait cree, sans rien faire.

.NOTES
    Projet : ServiceDesk Lab - Phase 1
    Prerequis : le reseau du lab doit exister (New-SDLabNetwork.ps1).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('DC01', 'CLI01', 'CLI02', 'SRV-LNX01', 'All')]
    [string[]] $VM = 'All',

    [ValidateNotNullOrEmpty()]
    [string] $VMPath = 'A:\VMs',

    [ValidateNotNullOrEmpty()]
    [string] $IsoPath = 'C:\ISO',

    [ValidateNotNullOrEmpty()]
    [string] $SwitchName = 'LAB-Internal'
)

$ErrorActionPreference = 'Stop'

# Identifiant du composant d'integration "Interface de services d'invite".
# On travaille par identifiant car les noms de ces composants sont TRADUITS :
#   anglais  : Guest Service Interface
#   francais : Interface de services d'invite
# Un script base sur le nom echoue des qu'il change de langue de systeme.
$GuestServiceInterfaceId = '6C09BB55-D683-4DA0-8931-C9BF705F6480'

# ---------------------------------------------------------------------------
# Specifications des VMs
#
# SecureBootTemplate :
#   MicrosoftWindows                  -> OS Windows
#   MicrosoftUEFICertificateAuthority -> distributions Linux signees par l'autorite
#                                        UEFI de Microsoft (Debian, Ubuntu, RHEL...)
#   Utiliser le modele Windows pour Debian empeche le demarrage.
# ---------------------------------------------------------------------------
$specs = [ordered]@{

    'DC01' = @{
        Role               = 'Controleur de domaine - AD DS, DNS, DHCP, fichiers, impression'
        CpuCount           = 2
        StartupMemory      = 2GB
        MinimumMemory      = 1GB
        MaximumMemory      = 4GB
        DiskSize           = 60GB
        IsoPattern         = '*SERVER_EVAL*'
        SecureBootTemplate = 'MicrosoftWindows'
        EnableTpm          = $true
    }

    'CLI01' = @{
        Role               = 'Poste utilisateur - Jean Dupont'
        CpuCount           = 2
        StartupMemory      = 4GB
        MinimumMemory      = 1GB
        MaximumMemory      = 6GB
        DiskSize           = 60GB
        IsoPattern         = '*CLIENTENTERPRISEEVAL*'
        SecureBootTemplate = 'MicrosoftWindows'
        EnableTpm          = $true
    }

    'CLI02' = @{
        Role               = 'Poste utilisateur - Marie Martin'
        CpuCount           = 2
        StartupMemory      = 4GB
        MinimumMemory      = 1GB
        MaximumMemory      = 6GB
        DiskSize           = 60GB
        IsoPattern         = '*CLIENTENTERPRISEEVAL*'
        SecureBootTemplate = 'MicrosoftWindows'
        EnableTpm          = $true
    }

    'SRV-LNX01' = @{
        Role               = 'Serveur GLPI - ticketing et inventaire de parc'
        CpuCount           = 2
        StartupMemory      = 1536MB
        MinimumMemory      = 512MB
        MaximumMemory      = 2GB
        DiskSize           = 20GB
        IsoPattern         = 'debian-*-netinst.iso'
        SecureBootTemplate = 'MicrosoftUEFICertificateAuthority'
        EnableTpm          = $false
    }
}

# ---------------------------------------------------------------------------
# Controles prealables
# ---------------------------------------------------------------------------
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Le commutateur '$SwitchName' n'existe pas. Lancez d'abord New-SDLabNetwork.ps1."
}

if (-not (Test-Path $IsoPath)) { throw "Dossier d'ISO introuvable : $IsoPath" }

if (-not (Test-Path $VMPath)) {
    if ($PSCmdlet.ShouldProcess($VMPath, 'Creer le dossier des VMs')) {
        New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
    }
}

$targets = if ($VM -contains 'All') { @($specs.Keys) } else { $VM }

# Estimation de l'espace necessaire (les disques sont dynamiques : ~20 Go reels
# par VM Windows installee, ~8 Go pour Debian, + les instantanes)
$drive = (Split-Path $VMPath -Qualifier).TrimEnd(':')
$free  = (Get-Volume -DriveLetter $drive).SizeRemaining / 1GB

Write-Host ''
Write-Host '=== Provisionnement des VMs du lab ===' -ForegroundColor Cyan
Write-Host ("  Destination   : {0}  ({1:N1} Go libres)" -f $VMPath, $free)
Write-Host ("  Commutateur   : {0}" -f $SwitchName)
Write-Host ("  VMs demandees : {0}" -f ($targets -join ', '))
Write-Host ''

$summary = @()

foreach ($name in $targets) {

    $spec = $specs[$name]
    Write-Host ("--- {0} : {1}" -f $name, $spec.Role) -ForegroundColor Yellow

    $existing = Get-VM -Name $name -ErrorAction SilentlyContinue
    $created  = $false

    # --- VM allumee : on ne reconfigure jamais a chaud --------------------
    if ($existing -and $existing.State -ne 'Off') {
        Write-Warning ("    {0} est dans l'etat '{1}'. Aucune modification." -f $name, $existing.State)
        $summary += [pscustomobject]@{ VM = $name; Action = 'IGNOREE'; Detail = "VM $($existing.State)" }
        continue
    }

    # --- Creation si absente ---------------------------------------------
    if (-not $existing) {

        # Resolution de l'ISO par motif : les noms Microsoft sont longs et
        # changent a chaque version, les ecrire en dur serait fragile.
        $iso = Get-ChildItem -Path $IsoPath -Filter *.iso -File |
               Where-Object Name -like $spec.IsoPattern |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

        if (-not $iso) {
            Write-Warning ("    Aucun ISO correspondant a '{0}' dans {1}. VM ignoree." -f $spec.IsoPattern, $IsoPath)
            $summary += [pscustomobject]@{ VM = $name; Action = 'IGNOREE'; Detail = "ISO manquant ($($spec.IsoPattern))" }
            continue
        }

        Write-Host ("    ISO : {0}" -f $iso.Name) -ForegroundColor DarkGray

        if (-not $PSCmdlet.ShouldProcess($name, 'Creer la machine virtuelle')) {
            $summary += [pscustomobject]@{ VM = $name; Action = 'SIMULEE'; Detail = $iso.Name }
            continue
        }

        $vhdPath = Join-Path $VMPath "$name\Virtual Hard Disks\$name.vhdx"

        New-VM -Name              $name `
               -Generation        2 `
               -MemoryStartupBytes $spec.StartupMemory `
               -Path              $VMPath `
               -NewVHDPath        $vhdPath `
               -NewVHDSizeBytes   $spec.DiskSize `
               -SwitchName        $SwitchName | Out-Null

        $created = $true
        Write-Host '    VM creee.' -ForegroundColor Green
    }
    else {
        Write-Host '    Existe deja : reapplication de la configuration.' -ForegroundColor DarkGray
        if (-not $PSCmdlet.ShouldProcess($name, 'Reappliquer la configuration')) {
            $summary += [pscustomobject]@{ VM = $name; Action = 'SIMULEE'; Detail = 'reconfiguration' }
            continue
        }
    }

    # =====================================================================
    #  Configuration appliquee DANS TOUS LES CAS (creation ou VM existante)
    #
    #  Les cmdlets Set-* sont naturellement idempotentes : les rejouer sur
    #  une VM deja conforme ne change rien. C'est ce qui permet de reparer
    #  une VM creee par une execution precedente interrompue, au lieu de la
    #  declarer "existante donc terminee" - un script idempotent garantit un
    #  ETAT, pas une existence.
    # =====================================================================

    # --- Processeur -------------------------------------------------------
    Set-VMProcessor -VMName $name -Count $spec.CpuCount

    # --- Memoire dynamique ------------------------------------------------
    # Sans bornes, une VM peut affamer l'hote. Le minimum permet a Hyper-V
    # de recuperer la memoire inutilisee quand la VM est au repos.
    Set-VMMemory -VMName $name `
                 -DynamicMemoryEnabled $true `
                 -MinimumBytes $spec.MinimumMemory `
                 -StartupBytes $spec.StartupMemory `
                 -MaximumBytes $spec.MaximumMemory

    # --- Secure Boot ------------------------------------------------------
    Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate $spec.SecureBootTemplate

    # --- TPM virtuel ------------------------------------------------------
    # Windows 11 refuse de s'installer sans TPM 2.0. En Hyper-V, activer le TPM
    # exige d'abord un "protecteur de cle" : c'est lui qui chiffre l'etat du TPM
    # virtuel. Sans cette etape, Enable-VMTPM renvoie un laconique
    # "Echec de l'operation", sans indiquer la cause.
    if ($spec.EnableTpm -and -not (Get-VMSecurity -VMName $name).TpmEnabled) {
        Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
        Enable-VMTPM -VMName $name
    }

    # --- Comportements de la VM -------------------------------------------
    # AutomaticCheckpointsEnabled : ACTIVE par defaut sur Hyper-V client.
    #   A desactiver : il cree un instantane a chaque demarrage, gonfle le disque
    #   et brouille la gestion manuelle des points de restauration du lab.
    # CheckpointType Production : utilise VSS dans l'invite pour un instantane
    #   coherent, au lieu de figer la memoire. Indispensable sur un controleur
    #   de domaine, ou restaurer un etat memoire provoque un USN rollback.
    # AutomaticStartAction Nothing : avec 16 Go, aucune VM ne doit demarrer
    #   automatiquement avec l'hote.
    Set-VM -Name $name `
           -AutomaticCheckpointsEnabled $false `
           -CheckpointType Production `
           -AutomaticStartAction Nothing `
           -AutomaticStopAction ShutDown `
           -Notes $spec.Role

    # --- Composant d'integration "Interface de services d'invite" ---------
    # Permet Copy-VMFile : deposer un fichier dans la VM SANS reseau, ce qui
    # est precieux quand on vient justement de casser son reseau.
    #
    # On cible par IDENTIFIANT et non par nom : les noms des composants
    # d'integration sont TRADUITS ("Guest Service Interface" en anglais,
    # "Interface de services d'invite" en francais). Un script base sur le nom
    # echoue des qu'il change de langue de systeme.
    $gsi = Get-VMIntegrationService -VMName $name |
           Where-Object { $_.Id -like "*$GuestServiceInterfaceId" }

    if (-not $gsi) {
        Write-Warning "    Composant d'integration $GuestServiceInterfaceId introuvable."
    }
    elseif (-not $gsi.Enabled) {
        Enable-VMIntegrationService -VMIntegrationService $gsi
    }

    # --- ISO et ordre de demarrage : uniquement a la creation -------------
    # On ne retouche jamais l'ordre de demarrage d'une VM existante : sur une
    # machine dont l'OS est deja installe, la faire redemarrer sur le DVD
    # relancerait l'installation.
    if ($created) {
        $dvd = Get-VMDvdDrive -VMName $name -ErrorAction SilentlyContinue
        if ($dvd) { Set-VMDvdDrive -VMName $name -Path $iso.FullName }
        else      { Add-VMDvdDrive -VMName $name -Path $iso.FullName }

        Set-VMFirmware -VMName $name -FirstBootDevice (Get-VMDvdDrive -VMName $name)
    }

    Write-Host '    Configuration appliquee.' -ForegroundColor Green
    $summary += [pscustomobject]@{
        VM     = $name
        Action = if ($created) { 'Creee' } else { 'Reconfiguree' }
        Detail = if ($created) { $iso.Name } else { 'configuration reappliquee' }
    }
}

# ---------------------------------------------------------------------------
# Resume
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Resume ===' -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if (-not $WhatIfPreference) {

    Write-Host '=== Etat des VMs ===' -ForegroundColor Cyan
    Get-VM | Sort-Object Name | ForEach-Object {
        $m = Get-VMMemory -VMName $_.Name
        $s = Get-VMSecurity -VMName $_.Name
        [pscustomobject]@{
            VM        = $_.Name
            Etat      = $_.State
            Gen       = $_.Generation
            vCPU      = $_.ProcessorCount
            'RAM min' = '{0:N0} Mo' -f ($m.Minimum / 1MB)
            'RAM dem' = '{0:N0} Mo' -f ($m.Startup / 1MB)
            'RAM max' = '{0:N0} Mo' -f ($m.Maximum / 1MB)
            TPM       = $s.TpmEnabled
            Reseau    = (Get-VMNetworkAdapter -VMName $_.Name).SwitchName
        }
    } | Format-Table -AutoSize

    $used = (Get-ChildItem $VMPath -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum / 1GB
    Write-Host ('Espace occupe par les VMs : {0:N1} Go   |   Libre sur {1}: {2:N1} Go' -f `
        $used, $drive, ((Get-Volume -DriveLetter $drive).SizeRemaining / 1GB))
    Write-Host ''
    Write-Host 'Les VMs ne sont pas demarrees. Installation manuelle :' -ForegroundColor Cyan
    Write-Host '  vmconnect.exe localhost DC01      puis  Start-VM -Name DC01'
    Write-Host ''
}
