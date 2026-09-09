# Procédure 02 — Création des machines virtuelles

| | |
|---|---|
| **Objectif** | Provisionner les VMs du lab, prêtes à recevoir leur système |
| **Durée** | ~5 minutes (hors installation des OS) |
| **Prérequis** | Réseau du lab créé ([procédure 01](01-reseau-virtuel-du-lab.md)), ISO présents dans `C:\ISO` |
| **Script** | [`powershell/lab-setup/New-SDLabVM.ps1`](../../powershell/lab-setup/New-SDLabVM.ps1) |

---

## 1. Spécifications retenues

| VM | Rôle | vCPU | RAM min / démarrage / max | Disque | TPM | Modèle Secure Boot |
|---|---|---|---|---|---|---|
| **DC01** | AD DS, DNS, DHCP, fichiers, impression | 2 | 1 / 2 / 4 Go | 60 Go | Oui | `MicrosoftWindows` |
| **CLI01** | Poste — Jean Dupont | 2 | 1 / 4 / 6 Go | 60 Go | Oui | `MicrosoftWindows` |
| **CLI02** | Poste — Marie Martin | 2 | 1 / 4 / 6 Go | 60 Go | Oui | `MicrosoftWindows` |
| **SRV-LNX01** | GLPI | 2 | 0,5 / 1,5 / 2 Go | 20 Go | Non | `MicrosoftUEFICertificateAuthority` |

Toutes en **Génération 2**, reliées au commutateur `LAB-Internal`, disques dynamiques.

## 2. Exécution

```powershell
cd A:\technicien\powershell\lab-setup

.\New-SDLabVM.ps1 -WhatIf                      # simulation
.\New-SDLabVM.ps1 -VM DC01,CLI01,SRV-LNX01     # création
.\New-SDLabVM.ps1                              # All, y compris CLI02
```

Le script ne démarre pas les VMs : l'installation reste manuelle.

## 3. Points techniques et justifications

### Génération 2 obligatoire

Windows 11 exige **TPM 2.0 et Secure Boot**. Une VM Génération 1 utilise un BIOS hérité,
techniquement incapable de Secure Boot. La génération se choisit à la création et **ne se
convertit pas** : une erreur ici impose de recréer la VM.

### Le TPM virtuel et l'ordre des opérations

```powershell
Set-VMKeyProtector -VMName $name -NewLocalKeyProtector   # 1. d'abord
Enable-VMTPM -VMName $name                               # 2. ensuite
```

Le TPM virtuel stocke des secrets (clés BitLocker, attestation). Hyper-V exige un
**protecteur de clé** — le matériel cryptographique qui chiffre l'état du TPM virtuel — avant
d'autoriser son activation.

Sans cette étape, `Enable-VMTPM` renvoie un laconique **« Échec de l'opération »** sans indiquer
la cause. Vérifié empiriquement sur une VM jetable.

### Modèle Secure Boot adapté à l'OS

| Modèle | Usage |
|---|---|
| `MicrosoftWindows` | Systèmes Windows |
| `MicrosoftUEFICertificateAuthority` | Distributions Linux signées par l'autorité UEFI de Microsoft (Debian, Ubuntu, RHEL) |

Utiliser le modèle Windows pour Debian produit un **écran noir au démarrage, sans message
d'erreur** : le chargeur de démarrage de Debian est signé par l'autorité UEFI de Microsoft,
pas par la clé Windows.

### Mémoire dynamique bornée

Hyper-V ajuste la mémoire en cours d'exécution : une VM au repos restitue sa mémoire inutilisée,
et la réclame quand elle travaille. Sans bornes, une seule VM peut affamer l'hôte.

Le démarrage de CLI01/CLI02 est fixé à **4 Go** parce que l'installateur de Windows 11 refuse de
démarrer en dessous. La mémoire redescendra d'elle-même après l'installation.

### Trois réglages discrets mais déterminants

| Réglage | Raison |
|---|---|
| `-AutomaticCheckpointsEnabled $false` | Hyper-V client crée un instantané **à chaque démarrage** de VM par défaut : le disque gonfle et les points de restauration volontaires se noient dans des instantanés parasites |
| `-CheckpointType Production` | Le type *Standard* fige aussi la **mémoire vive** ; restaurer un contrôleur de domaine dans cet état provoque un **USN rollback**, une désynchronisation d'Active Directory très difficile à réparer. *Production* utilise VSS dans l'invité, comme une vraie sauvegarde |
| `-AutomaticStartAction Nothing` | Avec 16 Go sur l'hôte, des VMs qui démarrent avec Windows rendent le poste inutilisable plusieurs minutes |

### Composant d'intégration « Interface de services d'invité »

Active `Copy-VMFile`, qui dépose un fichier dans la VM **sans passer par le réseau** —
indispensable quand le réseau de la VM a justement été cassé pour un scénario.

On le cible par **identifiant** (`6C09BB55-D683-4DA0-8931-C9BF705F6480`) et non par nom, car les
noms des composants d'intégration sont **traduits** :

| Langue | Nom |
|---|---|
| Anglais | `Guest Service Interface` |
| Français | `Interface de services d'invité` |

```powershell
Enable-VMIntegrationService -VMName X -Name 'Guest Service Interface'
# -> Aucun composant d'integration ne porte le nom specifie.
```

### Résolution des ISO par motif

Les noms d'ISO Microsoft sont longs et changent à chaque version
(`26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`). Le script les
résout par motif (`*SERVER_EVAL*`) plutôt que de les écrire en dur : le lab reste reconstructible
après un nouveau téléchargement.

## 4. Vérifications

```powershell
Get-VM | Select-Object Name, State, Generation, ProcessorCount
Get-VMFirmware -VMName DC01 | Select-Object SecureBoot, SecureBootTemplate
Get-VMSecurity  -VMName DC01 | Select-Object TpmEnabled
Get-VMDvdDrive  -VMName DC01 | Select-Object Path
(Get-VMFirmware -VMName DC01).BootOrder
```

Résultats attendus sur chaque VM :

| Contrôle | Attendu |
|---|---|
| Génération | 2 |
| Secure Boot | `On`, avec le modèle correspondant à l'OS |
| TPM | `True` sur les VMs Windows, `False` sur Debian |
| Ordre de démarrage | **DVD → réseau → disque** |
| Instantanés automatiques | `False` |
| Type d'instantané | `Production` |
| Démarrage automatique | `Nothing` |
| Réseau | `LAB-Internal` |

## 5. Dépannage

| Symptôme | Cause | Correctif |
|---|---|---|
| `Echec de l'operation` sur `Enable-VMTPM` | Protecteur de clé absent | `Set-VMKeyProtector -NewLocalKeyProtector` d'abord |
| `Aucun composant d'integration ne porte le nom specifie` | Nom traduit | Cibler par identifiant |
| Écran noir au démarrage de Debian | Mauvais modèle Secure Boot | `Set-VMFirmware -SecureBootTemplate MicrosoftUEFICertificateAuthority` |
| Windows 11 refuse de s'installer | TPM ou Secure Boot absent, ou VM Génération 1 | Vérifier `Get-VMSecurity` ; une Gen 1 doit être recréée |
| La VM démarre sur un disque vide | Ordre de démarrage | `Set-VMFirmware -FirstBootDevice (Get-VMDvdDrive -VMName X)` |
| L'installateur Windows 11 ne démarre pas | Moins de 4 Go au démarrage | `Set-VMMemory -StartupBytes 4GB` |

## 6. Démarrer une installation

```powershell
vmconnect.exe localhost DC01
Start-VM -Name DC01
```

Ouvrir la console **avant** de démarrer : les VMs Génération 2 affichent brièvement
*« Press any key to boot from CD or DVD »*. Sans réaction, le firmware passe au périphérique
suivant et la VM s'arrête sur un disque vide.

---

## Exploitation quotidienne — démarrer et arrêter le lab

L'hôte dispose de 16 Go. **Ne jamais démarrer les quatre VMs simultanément.**

| Profil | VMs | RAM | Usage |
|---|---|---|---|
| `DC` | DC01 seul | ~2 Go | Travail sur l'annuaire |
| `A` — quotidien | DC01 + CLI01 | ~6,5 Go | 90 % du travail |
| `B` — multi-postes | DC01 + CLI01 + CLI02 | ~10 Go | GPO, droits, comparaisons |
| `C` — ticketing | DC01 + CLI01 + SRV-LNX01 | ~8 Go | GLPI |
| ✗ interdit | les quatre | ~12 Go + hôte | Swap, lab inutilisable |

Deux scripts appliquent cette règle :

```powershell
# Demarrer
.\Start-SDLab.ps1                    # profil A : DC01 puis CLI01
.\Start-SDLab.ps1 -LabProfile DC     # DC01 seul
.\Start-SDLab.ps1 -LabProfile C      # DC01 + CLI01 + GLPI

# Arreter
.\Stop-SDLab.ps1                     # arret gracieux de toutes les VMs
.\Stop-SDLab.ps1 -VMName CLI01       # une seule VM
```

[`Start-SDLab.ps1`](../../powershell/lab-setup/Start-SDLab.ps1) refuse de démarrer si la RAM
disponible est insuffisante, et **démarre toujours DC01 en premier** en attendant sa pulsation
avant de lancer les clients. Raison : un client qui démarre sans contrôleur de domaine disponible
ouvre une session avec des **informations d'identification mises en cache** au lieu d'une vraie
authentification — ce qui fausserait tous vos diagnostics.

### Arrêter une VM : trois méthodes, une seule correcte

| Méthode | Effet | Verdict sur un contrôleur de domaine |
|---|---|---|
| `Stop-VM` | Arrêt propre via le composant d'intégration *Arrêt* | ✅ **La seule correcte** |
| `Save-VM` | Écrit la RAM sur disque, comme une veille prolongée | ❌ Fige la mémoire ; au réveil l'horloge a dérivé et AD peut se désynchroniser |
| `Stop-VM -TurnOff` | Coupe l'alimentation virtuelle | ❌ Risque de corruption de `NTDS.dit` |

**Un contrôleur de domaine ne se met jamais en veille et ne se coupe jamais brutalement.** La base
Active Directory est transactionnelle : l'arrêter sauvagement équivaut à débrancher un serveur SQL.

### Ce qui continue de tourner après l'arrêt des VMs

Rien de significatif. Le commutateur virtuel, le NAT et le service `vmms` consomment quelques
dizaines de mégaoctets. **Ne jamais démonter le réseau du lab pour un arrêt quotidien** :
`Remove-SDLabNetwork.ps1` sert à repartir propre après un problème, pas à éteindre le lab.
