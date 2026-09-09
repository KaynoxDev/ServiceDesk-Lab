#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Cree le reseau virtuel du lab ServiceDesk : commutateur interne, passerelle hote et NAT.

.DESCRIPTION
    Script IDEMPOTENT : il peut etre relance autant de fois que necessaire sans erreur
    et sans dupliquer d'objet. Il verifie l'existant avant chaque action.

    Il realise quatre operations :
      1. Creation d'un commutateur virtuel Hyper-V de type Internal.
      2. Attribution de l'adresse de passerelle a la carte virtuelle de l'hote
         (vEthernet (<SwitchName>)) creee automatiquement avec le commutateur.
      3. Creation d'une regle NAT pour donner l'acces Internet aux VMs du lab.
      4. Classement du reseau en Prive + regle pare-feu autorisant le ping
         depuis le seul reseau du lab, pour que la passerelle soit testable.

    ATTENTION : aucune passerelle par defaut n'est definie sur la carte virtuelle.
    Cette carte EST la passerelle du lab ; lui en attribuer une creerait une seconde
    route par defaut sur l'hote et casserait sa connexion Internet.

.PARAMETER SwitchName
    Nom du commutateur virtuel. Defaut : LAB-Internal

.PARAMETER NatName
    Nom de la regle NAT. Defaut : LAB-NAT

.PARAMETER GatewayIP
    Adresse de la carte virtuelle de l'hote, qui sert de passerelle au lab.
    Defaut : 192.168.10.1

.PARAMETER PrefixLength
    Longueur du prefixe reseau. Defaut : 24 (soit 255.255.255.0)

.EXAMPLE
    .\New-SDLabNetwork.ps1
    Cree le reseau avec les valeurs par defaut.

.EXAMPLE
    .\New-SDLabNetwork.ps1 -WhatIf
    Affiche ce qui serait fait, sans rien modifier.

.NOTES
    Projet  : ServiceDesk Lab - Phase 1
    Requiert : Windows 11 Pro avec Hyper-V, droits administrateur complets.
               L'appartenance au groupe "Administrateurs Hyper-V" ne suffit pas :
               New-NetIPAddress et New-NetNat touchent la pile reseau de Windows.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string] $SwitchName = 'LAB-Internal',

    [ValidateNotNullOrEmpty()]
    [string] $NatName = 'LAB-NAT',

    [ipaddress] $GatewayIP = '192.168.10.1',

    [ValidateRange(8, 30)]
    [int] $PrefixLength = 24,

    [ValidateNotNullOrEmpty()]
    [string] $FirewallRuleName = 'LAB-Internal - ICMPv4 Echo Request (entrant)'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Fonction interne : calcule l'adresse reseau a partir d'une IP et d'un prefixe
# Exemple : 192.168.10.1 /24  ->  192.168.10.0/24
# ---------------------------------------------------------------------------
function Get-NetworkPrefix {
    param(
        [Parameter(Mandatory)] [ipaddress] $IPAddress,
        [Parameter(Mandatory)] [int]       $PrefixLength
    )

    # Les octets d'une IP sont en big-endian, BitConverter attend du little-endian
    $bytes = $IPAddress.GetAddressBytes()
    [array]::Reverse($bytes)
    $ipAsInt = [BitConverter]::ToUInt32($bytes, 0)

    # Masque : les <PrefixLength> bits de poids fort a 1
    $maskAsInt = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $PrefixLength))

    # ET binaire entre l'IP et le masque = adresse reseau
    $netAsInt = $ipAsInt -band $maskAsInt

    $netBytes = [BitConverter]::GetBytes($netAsInt)
    [array]::Reverse($netBytes)

    return '{0}/{1}' -f ([ipaddress]$netBytes).IPAddressToString, $PrefixLength
}

# ---------------------------------------------------------------------------
# Preparation
# ---------------------------------------------------------------------------
$networkPrefix = Get-NetworkPrefix -IPAddress $GatewayIP -PrefixLength $PrefixLength
$adapterName   = "vEthernet ($SwitchName)"

Write-Host ''
Write-Host '=== Configuration cible ===' -ForegroundColor Cyan
Write-Host ("  Commutateur  : {0} (Internal)" -f $SwitchName)
Write-Host ("  Carte hote   : {0}" -f $adapterName)
Write-Host ("  Passerelle   : {0}/{1}" -f $GatewayIP, $PrefixLength)
Write-Host ("  Reseau       : {0}" -f $networkPrefix)
Write-Host ("  NAT          : {0}" -f $NatName)
Write-Host ''

# ---------------------------------------------------------------------------
# Controle prealable : le sous-reseau est-il deja utilise par l'hote ?
# Reflexe professionnel : ne jamais attribuer un plan d'adressage sans verifier
# qu'il est libre. Deux reseaux identiques rendent le routage imprevisible.
# ---------------------------------------------------------------------------
$conflict = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InterfaceAlias -ne $adapterName -and
        (Get-NetworkPrefix -IPAddress $_.IPAddress -PrefixLength $_.PrefixLength) -eq $networkPrefix
    }

if ($conflict) {
    $detail = ($conflict | ForEach-Object { "$($_.InterfaceAlias) = $($_.IPAddress)/$($_.PrefixLength)" }) -join ' ; '
    throw "Le reseau $networkPrefix est deja utilise par l'hote ($detail). Choisissez un autre plan d'adressage avec -GatewayIP."
}

# ---------------------------------------------------------------------------
# ETAPE 1/4 - Commutateur virtuel
# ---------------------------------------------------------------------------
Write-Host '[1/4] Commutateur virtuel' -ForegroundColor Yellow

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

if ($switch) {
    if ($switch.SwitchType -ne 'Internal') {
        throw "Le commutateur '$SwitchName' existe mais son type est '$($switch.SwitchType)' au lieu de 'Internal'. Supprimez-le ou choisissez un autre nom."
    }
    Write-Host "      Existe deja, rien a faire." -ForegroundColor DarkGray
}
else {
    if ($PSCmdlet.ShouldProcess($SwitchName, 'Creer un commutateur virtuel Internal')) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        Write-Host "      Cree." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# ETAPE 2/4 - Adresse de la carte virtuelle de l'hote
# La carte apparait une fraction de seconde apres la creation du commutateur :
# on attend activement plutot que de supposer qu'elle est deja la.
# ---------------------------------------------------------------------------
Write-Host '[2/4] Adresse de la carte hote' -ForegroundColor Yellow

$adapter = $null
for ($i = 1; $i -le 20; $i++) {
    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    if ($adapter) { break }
    Start-Sleep -Milliseconds 500
}

if (-not $adapter) {
    if ($WhatIfPreference) {
        Write-Host "      (mode WhatIf : la carte n'existe pas encore, etape ignoree)" -ForegroundColor DarkGray
    }
    else {
        throw "La carte '$adapterName' n'est pas apparue apres 10 secondes. Verifiez l'etat du commutateur."
    }
}
else {
    $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object IPAddress -eq $GatewayIP.IPAddressToString

    if ($existingIP) {
        Write-Host "      $GatewayIP deja configuree, rien a faire." -ForegroundColor DarkGray
    }
    else {
        # Une carte neuve porte une adresse APIPA (169.254.x.x) : on la retire
        # pour eviter de cumuler deux adresses sur la meme interface.
        $apipa = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -like '169.254.*' }

        if ($apipa -and $PSCmdlet.ShouldProcess($adapterName, 'Retirer l''adresse APIPA')) {
            $apipa | Remove-NetIPAddress -Confirm:$false
        }

        if ($PSCmdlet.ShouldProcess($adapterName, "Attribuer $GatewayIP/$PrefixLength")) {
            # Aucune -DefaultGateway : cette carte EST la passerelle du lab.
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                             -IPAddress     $GatewayIP.IPAddressToString `
                             -PrefixLength  $PrefixLength | Out-Null
            Write-Host "      $GatewayIP/$PrefixLength attribuee." -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# ETAPE 3/4 - NAT
# WinNAT n'autorise qu'une seule traduction par prefixe interne : on verifie
# donc aussi qu'aucun NAT portant un autre nom ne couvre deja notre reseau.
# ---------------------------------------------------------------------------
Write-Host '[3/4] Regle NAT' -ForegroundColor Yellow

$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue

if ($nat) {
    if ($nat.InternalIPInterfaceAddressPrefix -ne $networkPrefix) {
        throw "Le NAT '$NatName' existe mais couvre $($nat.InternalIPInterfaceAddressPrefix) au lieu de $networkPrefix. Supprimez-le avec Remove-NetNat."
    }
    Write-Host "      Existe deja, rien a faire." -ForegroundColor DarkGray
}
else {
    $other = Get-NetNat -ErrorAction SilentlyContinue |
             Where-Object InternalIPInterfaceAddressPrefix -eq $networkPrefix

    if ($other) {
        throw "Un NAT nomme '$($other.Name)' couvre deja $networkPrefix. Windows n'en autorise qu'un par prefixe."
    }

    if ($PSCmdlet.ShouldProcess($NatName, "Creer un NAT sur $networkPrefix")) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $networkPrefix | Out-Null
        Write-Host "      Cree." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# ETAPE 4/4 - Profil reseau et pare-feu
#
# Windows classe tout nouveau reseau en "Public" par defaut, le profil
# pare-feu le plus restrictif. Consequence : l'hote ignore les pings venant
# du lab. Une VM qui teste sa passerelle ("ping 192.168.10.1") conclurait a
# tort qu'elle est injoignable, alors que le routage et le NAT fonctionnent.
#
# On fait donc deux choses :
#   - classer le reseau du lab en "Prive" (reseau de confiance) ;
#   - ouvrir l'echo ICMPv4 entrant UNIQUEMENT depuis le reseau du lab,
#     plutot que d'activer la regle Windows generique qui l'ouvrirait a tous
#     les reseaux de la machine, reseau domestique inclus.
# ---------------------------------------------------------------------------
Write-Host '[4/4] Profil reseau et pare-feu' -ForegroundColor Yellow

$netProfile = Get-NetConnectionProfile -InterfaceAlias $adapterName -ErrorAction SilentlyContinue

if (-not $netProfile) {
    Write-Host '      Profil reseau indisponible (carte sans trafic), etape ignoree.' -ForegroundColor DarkGray
}
elseif ($netProfile.NetworkCategory -eq 'Private') {
    Write-Host '      Reseau deja classe Prive.' -ForegroundColor DarkGray
}
else {
    if ($PSCmdlet.ShouldProcess($adapterName, 'Classer le reseau en Prive')) {
        Set-NetConnectionProfile -InterfaceAlias $adapterName -NetworkCategory Private
        Write-Host ('      Reclasse de {0} en Prive.' -f $netProfile.NetworkCategory) -ForegroundColor Green
    }
}

$rule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue

if ($rule) {
    Write-Host '      Regle pare-feu ICMP deja presente.' -ForegroundColor DarkGray
}
else {
    if ($PSCmdlet.ShouldProcess($FirewallRuleName, "Autoriser l'echo ICMPv4 depuis $networkPrefix")) {
        New-NetFirewallRule -DisplayName   $FirewallRuleName `
                            -Description   'Lab ServiceDesk : permet aux VMs de tester la passerelle par ping.' `
                            -Direction     Inbound `
                            -Protocol      ICMPv4 `
                            -IcmpType      8 `
                            -RemoteAddress $networkPrefix `
                            -Action        Allow `
                            -Profile       Any `
                            -Enabled       True | Out-Null
        Write-Host ('      Regle creee : echo ICMPv4 autorise depuis {0} uniquement.' -f $networkPrefix) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Resume de l'etat final
# ---------------------------------------------------------------------------
if (-not $WhatIfPreference) {

    Write-Host ''
    Write-Host '=== Etat final ===' -ForegroundColor Cyan

    $sw  = Get-VMSwitch  -Name $SwitchName -ErrorAction SilentlyContinue
    $ad  = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    $ip  = if ($ad) { Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue } else { $null }
    $nt  = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    $pr  = Get-NetConnectionProfile -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
    $fw  = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Commutateur   = if ($sw) { "$($sw.Name) ($($sw.SwitchType))" } else { 'ABSENT' }
        CarteHote     = if ($ad) { "$($ad.Name) - $($ad.Status)" }     else { 'ABSENTE' }
        AdresseHote   = if ($ip) { ($ip | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ' } else { 'AUCUNE' }
        NAT           = if ($nt) { "$($nt.Name) -> $($nt.InternalIPInterfaceAddressPrefix)" } else { 'ABSENT' }
        ProfilReseau  = if ($pr) { $pr.NetworkCategory } else { 'INDISPONIBLE' }
        PareFeuPing   = if ($fw) { "$($fw.DisplayName) [$($fw.Enabled)]" } else { 'ABSENT' }
    } | Format-List

    Write-Host 'Reseau du lab pret.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Rappel du plan d''adressage :' -ForegroundColor Cyan
    Write-Host ('  Passerelle / NAT : {0}   (cet hote)' -f $GatewayIP)
    Write-Host  '  DC01  (AD/DNS/DHCP) : 192.168.10.10  fixe'
    Write-Host  '  SRV-LNX01 (GLPI)    : 192.168.10.20  fixe'
    Write-Host  '  CLI01 / CLI02       : 192.168.10.100-150  par DHCP'
    Write-Host ''
}
