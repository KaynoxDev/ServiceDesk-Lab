# Réflexes de diagnostic — fiche de révision

> Connaissances opérationnelles rencontrées en construisant le lab, classées par utilité
> réelle au support N1. À réviser avant un entretien.

---

## 1. L'échelle de diagnostic réseau

On remonte du plus bas vers le plus haut, et **on s'arrête au premier échec**. Inutile de tester
le DNS si la carte réseau est désactivée.

| # | Question | Commande | Si ça échoue, chercher… |
|---|---|---|---|
| 1 | La carte est-elle active ? | `Get-NetAdapter` | câble, pilote, carte désactivée |
| 2 | Ai-je une IP valide ? | `ipconfig /all` | `169.254.x.x` → **le DHCP ne répond pas** |
| 3 | Ma passerelle répond-elle ? | `ping <passerelle>` | réseau local, switch, VLAN |
| 4 | Est-ce que je sors du réseau ? | `ping 1.1.1.1` | routage, NAT, pare-feu |
| 5 | La résolution de noms marche-t-elle ? | `nslookup google.com` | **le DNS** |
| 6 | Le service visé répond-il ? | `Test-NetConnection -Port 443` | proxy, filtrage applicatif |

**Conséquence directe :** « je n'ai plus Internet » n'est pas un diagnostic, c'est un symptôme.
Si l'étape 4 passe et que seule l'étape 5 échoue, le problème est le DNS — et les sites ne
s'ouvrent pas parce que leurs *noms* ne se résolvent plus.

C'est pourquoi, dans ce lab, la **passerelle** (`192.168.10.1`) et le **DNS** (`192.168.10.10`)
sont deux machines différentes : sans cette séparation, une panne de routage et une panne de
résolution auraient les mêmes symptômes.

---

## 2. `169.254.x.x` — l'indice le plus rentable du métier

Une carte qui ne reçoit aucune réponse du DHCP s'attribue elle-même une adresse en
`169.254.x.x` : c'est l'**APIPA** (*Automatic Private IP Addressing*).

> `169.254.x.x` signifie : *« j'ai demandé une adresse au DHCP et je n'ai reçu aucune réponse. »*

Ce que cela **élimine** immédiatement : la carte réseau fonctionne, la pile TCP/IP fonctionne,
Windows fonctionne.

Ce qu'il reste à chercher : câble, port du switch désactivé, mauvais VLAN, serveur DHCP arrêté,
étendue DHCP épuisée, relais DHCP absent.

---

## 3. Le masque de sous-réseau est un ET binaire

```
IP      192.168.10.1    =  11000000.10101000.00001010.00000001
Masque  255.255.255.0   =  11111111.11111111.11111111.00000000
ET      ------------------------------------------------------
Réseau  192.168.10.0    =  11000000.10101000.00001010.00000000
```

La machine calcule ainsi son propre réseau, puis compare celui de la destination. Même réseau →
elle émet directement ; réseau différent → elle passe par la passerelle.

**Panne typique :** un masque erroné fait calculer un mauvais réseau. La machine croit que la
destination est locale, n'envoie jamais le paquet à la passerelle, et l'utilisateur constate
« j'ai une IP mais pas d'Internet ».

---

## 4. Un `ping` ne prouve pas ce qu'on croit

| Observation | Ce que ça ne prouve PAS |
|---|---|
| `ping` échoue | Que la machine est éteinte ou injoignable — un pare-feu peut simplement ignorer ICMP |
| `ping` répond | Que le service fonctionne — la machine répond, mais son DNS, SMB ou serveur web peut être arrêté |

**Règle : tester le service, pas la machine.**

```powershell
Test-NetConnection -ComputerName dc01 -Port 53     # DNS
Test-NetConnection -ComputerName dc01 -Port 445    # partage de fichiers
Test-NetConnection -ComputerName dc01 -Port 389    # LDAP / Active Directory
```

Ports à connaître : **53** DNS · **80/443** web · **88** Kerberos · **135** RPC ·
**389/636** LDAP/LDAPS · **445** SMB · **3389** Bureau à distance.

---

## 5. Le TTL révèle le système distant

| TTL observé | Système probable |
|---|---|
| 128 (ou un peu moins) | Windows |
| 64 (ou un peu moins) | Linux / Unix / équipement réseau |

Le TTL décroît d'une unité par routeur traversé : un `TTL=125` indique un Windows à trois sauts.

---

## 6. Le jeton d'accès — la vraie raison du « reconnectez-vous »

L'appartenance aux groupes d'un utilisateur est inscrite dans son **jeton d'accès**, construit
**une seule fois, à l'ouverture de session**. Windows n'y ajoute jamais un groupe rétroactivement.

Conséquences pratiques :

- ajouter un utilisateur à un groupe **ne change rien** tant qu'il ne s'est pas reconnecté ;
- ouvrir un nouveau terminal **ne suffit pas** : tout processus hérite du jeton de la session ;
- il faut **fermer la session et la rouvrir** (ou redémarrer).

> *« Déconnectez-vous et reconnectez-vous »* n'est pas une formule magique : pour tout ce qui
> touche aux droits, aux groupes et aux GPO utilisateur, c'est **la** manipulation techniquement
> nécessaire. Savoir l'expliquer change la perception qu'on a de vous.

---

## 7. Moindre privilège : il existe presque toujours un groupe dédié

Question piège classique : *« l'utilisateur doit installer une imprimante / gérer des VMs /
sauvegarder des fichiers, on le passe administrateur local ? »*

**Non.** Windows fournit des groupes intégrés qui accordent exactement le droit nécessaire :

| Groupe | SID | Droit accordé |
|---|---|---|
| Administrateurs | `S-1-5-32-544` | Tout — à éviter |
| Utilisateurs | `S-1-5-32-545` | Usage standard |
| Opérateurs de sauvegarde | `S-1-5-32-551` | Sauvegarder/restaurer sans lire le contenu |
| Utilisateurs du Bureau à distance | `S-1-5-32-555` | Ouvrir une session RDP |
| Administrateurs Hyper-V | `S-1-5-32-578` | Gérer les VMs sans être admin de la machine |

---

## 8. Les noms d'objets Windows sont traduits, les identifiants non

C'est une source d'échec fréquente dans les scripts.

| Objet | Anglais | Français |
|---|---|---|
| Groupe intégré | `Hyper-V Administrators` | `Administrateurs Hyper-V` |
| Composant d'intégration | `Guest Service Interface` | `Interface de services d'invité` |

Un script qui cible par **nom** casse dès qu'il rencontre un poste dans une autre langue.
Un script qui cible par **SID** ou **GUID** fonctionne partout.

```powershell
# fragile
Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member $u

# robuste : on résout le nom localisé À PARTIR du SID
$grp = Get-LocalGroup -SID 'S-1-5-32-578'
Add-LocalGroupMember -Group $grp -Member $u
```

**Piège associé :** sur une machine dont le **nom d'ordinateur est identique au nom d'utilisateur**
(`KAY\Kay`), le nom nu `Kay` n'est pas résoluble — l'autorité de sécurité locale trouve deux
candidats. D'où l'intérêt des conventions de nommage de parc (`PC-COMPTA-01`, `LT-DUPONT-J`) :
elles évitent cette classe entière de pannes.

---

## 9. Méthode : les messages d'erreur mentent

Cas réel rencontré : `Add-LocalGroupMember` renvoie
*« Le membre KAY\Kay n'a pas été trouvé **dans** le groupe »* — une formulation de **suppression**,
sur une opération d'**ajout**. Le message est incohérent avec l'action demandée.

Deux règles en découlent :

1. **Vérifier les faits soi-même** plutôt que de faire confiance au libellé de l'erreur :
   le groupe existe-t-il ? le compte existe-t-il ? est-il résoluble ?
2. **Quand deux outils indépendants échouent de la même façon, la cause est dans leur entrée
   commune, pas dans les outils.** Ici `Add-LocalGroupMember` et `net localgroup` échouaient
   tous les deux : la donnée était en cause, pas les commandes.

---

## 10. Vérifier une source avant de l'installer

```powershell
(Get-FileHash 'C:\ISO\image.iso' -Algorithm SHA256).Hash
```

À comparer au hash publié par l'éditeur. Coût : 5 secondes. Évite de découvrir une image
corrompue après 40 minutes d'installation, et détecte une altération de la source.

**Associé :** la stratégie d'exécution `RemoteSigned` bloque les scripts **téléchargés** non
signés, grâce au marqueur `Zone.Identifier` que Windows ajoute aux fichiers venant d'Internet.
`Unblock-File` le retire — après avoir lu le script.

---

## Méthodologie générale — les 11 étapes

Appliquée à chaque incident du dépôt :

```
1. comprendre le probleme          7. identifier la cause
2. reproduire                      8. corriger
3. collecter les informations      9. retester
4. identifier les symptomes       10. documenter
5. emettre des hypotheses         11. cloturer le ticket
6. tester les hypotheses
```

Les étapes les plus souvent sautées sont la **2** (reproduire) et la **9** (retester). Ce sont
aussi celles qui génèrent les réouvertures de ticket.
