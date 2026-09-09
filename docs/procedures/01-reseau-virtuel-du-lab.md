# Procédure 01 — Mise en place du réseau virtuel du lab

| | |
|---|---|
| **Objectif** | Créer un réseau isolé pour les VMs du lab, avec accès Internet par NAT |
| **Durée** | ~10 minutes |
| **Prérequis** | Windows 11 Pro, Hyper-V activé, droits administrateur complets |
| **Script** | [`powershell/lab-setup/New-SDLabNetwork.ps1`](../../powershell/lab-setup/New-SDLabNetwork.ps1) |
| **Démontage** | [`powershell/lab-setup/Remove-SDLabNetwork.ps1`](../../powershell/lab-setup/Remove-SDLabNetwork.ps1) |

---

## 1. Topologie

```
        INTERNET
            |
   [ Box : 192.168.1.1 ]
            |
   +-------------------------------------------+
   |  HOTE                                     |
   |                                           |
   |  Ethernet            vEthernet            |
   |  192.168.1.193       (LAB-Internal)       |
   |       ^              192.168.10.1         |
   |       |                    ^              |
   |       +---- NAT: LAB-NAT --+              |
   |            192.168.10.0/24                |
   +----------------------------+--------------+
                                |
              +=================+==============+
              |  vSwitch "LAB-Internal"        |
              |  type Internal                 |
              +==+==========+==========+=======+
                 |          |          |
              [DC01]     [CLI01]   [SRV-LNX01]
               .10        DHCP        .20
```

## 2. Plan d'adressage

| Élément | Valeur |
|---|---|
| Réseau | `192.168.10.0/24` — masque `255.255.255.0` |
| Passerelle | `192.168.10.1` (carte virtuelle de l'hôte) |
| DNS du lab | `192.168.10.10` (DC01) |
| Plage DHCP | `192.168.10.100` → `192.168.10.150` |
| Commutateur | `LAB-Internal`, type *Internal* |
| NAT | `LAB-NAT` |

**Point clé :** la passerelle (`.1`, l'hôte) et le DNS (`.10`, DC01) sont **deux machines
distinctes**. C'est indispensable pour pouvoir simuler séparément une panne de routage et une
panne de résolution de noms.

## 3. Choix techniques et justifications

### Pourquoi un commutateur *Internal* et non *External*

| Type | Portée | Décision |
|---|---|---|
| External | VMs reliées au réseau physique du logement | ❌ Le serveur DHCP de DC01 répondrait à tout le réseau domestique → *rogue DHCP* |
| **Internal** | VMs + hôte, isolé du réseau physique | ✅ Retenu |
| Private | VMs entre elles, hôte exclu | ❌ Interdit le NAT et l'échange de fichiers avec l'hôte |

### Pourquoi ne pas réutiliser le `Default Switch` de Hyper-V

1. Son sous-réseau est régénéré aléatoirement par Windows → les IP fixes deviennent invalides.
2. Il n'est ni renommable ni configurable → aucun plan d'adressage documentable.
3. **Il embarque son propre serveur DHCP**, qui entrerait en concurrence avec celui de DC01.

### Contrôle préalable obligatoire

Avant d'attribuer `192.168.10.0/24`, vérifier que le préfixe n'est pas déjà utilisé par l'hôte :

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength
```

Deux réseaux identiques rendent le routage imprévisible. Le script effectue ce contrôle
automatiquement et s'arrête si un conflit est détecté.

### Aucune passerelle sur la carte virtuelle

`vEthernet (LAB-Internal)` **est** la passerelle du lab. Lui attribuer une passerelle par défaut
créerait une seconde route `0.0.0.0/0` sur l'hôte et casserait sa connexion Internet.

Vérification : il ne doit exister qu'**une seule** route par défaut.

```powershell
Get-NetRoute -DestinationPrefix '0.0.0.0/0'
```

### Profil réseau et pare-feu

Windows classe tout nouveau réseau en **Public**, profil le plus restrictif : l'hôte ignore alors
les pings venant du lab. Une VM testant sa passerelle concluerait à tort qu'elle est injoignable.

Le script classe donc le réseau en **Privé** et crée une règle pare-feu **ciblée** :
écho ICMPv4 entrant autorisé **depuis `192.168.10.0/24` uniquement**, et non depuis tous
les réseaux de la machine.

## 4. Exécution

En PowerShell **administrateur** (l'appartenance au groupe *Administrateurs Hyper-V* ne suffit
pas : `New-NetIPAddress` et `New-NetNat` modifient la pile réseau de Windows) :

```powershell
cd A:\technicien\powershell\lab-setup

.\New-SDLabNetwork.ps1 -WhatIf     # simulation
.\New-SDLabNetwork.ps1             # exécution
.\New-SDLabNetwork.ps1             # relance : doit afficher "rien a faire" partout
```

## 5. Vérifications

| Contrôle | Commande | Résultat attendu |
|---|---|---|
| Commutateur | `Get-VMSwitch -Name LAB-Internal` | `SwitchType = Internal` |
| Adresse hôte | `Get-NetIPAddress -InterfaceAlias 'vEthernet (LAB-Internal)' -AddressFamily IPv4` | `192.168.10.1/24`, origine `Manual` |
| NAT | `Get-NetNat` | `LAB-NAT → 192.168.10.0/24`, `Active = True` |
| Profil | `Get-NetConnectionProfile -InterfaceAlias 'vEthernet (LAB-Internal)'` | `NetworkCategory = Private` |
| Route par défaut | `Get-NetRoute -DestinationPrefix '0.0.0.0/0'` | **une seule** entrée |
| Internet hôte | `Test-Connection 1.1.1.1 -Count 2` | réponse |
| Passerelle | `ping 192.168.10.1` | réponse, `TTL=128` |

## 6. Dépannage

| Symptôme | Cause probable | Correctif |
|---|---|---|
| `Le terme New-VMSwitch n'est pas reconnu` | Module Hyper-V absent | Activer Hyper-V : `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All` |
| `Vous ne disposez pas de l'autorisation requise` | Session non élevée, ou hors du groupe Administrateurs Hyper-V | Élever la console ; pour le confort, ajouter le compte au groupe `S-1-5-32-578` puis **rouvrir la session** |
| La carte `vEthernet (...)` n'apparaît pas | Délai de création | Le script attend jusqu'à 10 s ; sinon vérifier l'état du commutateur |
| L'hôte perd Internet | Deux routes par défaut | Retirer la passerelle de la carte du lab : `Remove-NetRoute` |
| Le `ping` de la passerelle échoue depuis une VM | Profil Public, ou règle ICMP absente | Relancer le script (étape 4/4) |
| `Un NAT couvre deja ce prefixe` | NAT résiduel | `Get-NetNat` puis `Remove-NetNat -Name <nom>` |

## 7. Démontage

```powershell
.\Remove-SDLabNetwork.ps1 -WhatIf   # simulation
.\Remove-SDLabNetwork.ps1           # suppression, avec confirmation
```

Le script prévient nommément des VMs reliées au commutateur avant de le supprimer.

---

## Ce que cette procédure illustre

- **Un masque de sous-réseau est un ET binaire.** `192.168.10.1 AND 255.255.255.0 = 192.168.10.0`.
  Un masque erroné fait calculer une mauvaise adresse réseau à la machine, qui croit alors la
  destination locale et n'envoie jamais le paquet à la passerelle → *« j'ai une IP mais pas d'Internet »*.
- **`169.254.x.x` (APIPA) signifie « aucune réponse du DHCP ».** La carte et la pile TCP/IP
  fonctionnent ; c'est en amont qu'il faut chercher (câble, port, VLAN, étendue épuisée, service arrêté).
- **Un `ping` qui échoue ne prouve pas qu'une machine est injoignable**, et un `ping` qui répond
  ne prouve pas que le service fonctionne. Tester le service :
  `Test-NetConnection -ComputerName dc01 -Port 53`.
- **`TTL=128` indique un système Windows, `TTL=64` un système Linux.**
- **Une règle de pare-feu se restreint au strict nécessaire** : un protocole, un type, une source.
