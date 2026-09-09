# ServiceDesk Lab

**Environnement Active Directory monté chez moi pour pratiquer le support informatique N1 :
incidents réalistes, diagnostic méthodique, procédures documentées et automatisation PowerShell.**

> 🚧 Projet en construction — voir [Avancement](#avancement).

---

## Pourquoi ce projet

Je suis en reconversion vers les métiers du support informatique. Plutôt que d'aligner des
certifications théoriques, j'ai choisi de reconstruire chez moi l'infrastructure d'une petite
entreprise, d'y provoquer de vraies pannes, et de les résoudre en appliquant une méthodologie
de diagnostic rigoureuse.

L'objectif n'est pas de monter un lab pour le plaisir de monter un lab. Chaque brique répond à
une question précise : *est-ce utile à un technicien Service Desk au quotidien ?*

---

## Architecture

```
        INTERNET
            |
   [ Box / routeur ]
            |
   +------------------------+
   |  HOTE Hyper-V          |
   |  NAT + passerelle      |
   |  192.168.10.1          |
   +-----------+------------+
               |  vSwitch "LAB-Internal"  --  192.168.10.0/24
   +-----------+---------------+---------------+
   |           |               |               |
[DC01]      [CLI01]         [CLI02]      [SRV-LNX01]
.10 fixe    DHCP            DHCP         .20 fixe
```

| Machine | Rôle | OS |
|---|---|---|
| **DC01** | Active Directory, DNS, DHCP, partages, impression | Windows Server 2025 |
| **CLI01 / CLI02** | Postes utilisateurs joints au domaine | Windows 11 Enterprise |
| **SRV-LNX01** | GLPI — ticketing et inventaire de parc | Debian 13 |

Domaine : `sdlab.lan` · Réseau isolé en `192.168.10.0/24` · Sortie Internet par NAT.

Détail complet : [`docs/00-analyse-phase0.md`](docs/00-analyse-phase0.md) et
[`docs/architecture/inventaire.md`](docs/architecture/inventaire.md).

---

## Ce que contient le dépôt

| Dossier | Contenu |
|---|---|
| `docs/` | Architecture, procédures, arbres de diagnostic, méthodologie |
| `powershell/` | Module **SDToolkit** — diagnostic et remédiation, séparés strictement |
| `scenarios/` | Pannes reproductibles : énoncé, corrigé, scripts `break` / `restore` |
| `tickets/` | Tickets rédigés au format ITIL sur les incidents résolus |
| `app/` | Application WPF regroupant les outils de diagnostic |
| `reports/` | Exemples de rapports de support générés |

---

## Compétences travaillées

**Active Directory** — installation AD DS, OU, utilisateurs, groupes, GPO, délégation,
réinitialisation de mot de passe, déverrouillage de compte, jonction de postes au domaine.

**Réseau** — IPv4, DHCP (étendues, baux, réservations), DNS (zones, forwarders, cache),
routage, partages SMB, diagnostic avec `ipconfig`, `ping`, `tracert`, `nslookup`, `Test-NetConnection`.

**Poste de travail** — services, processus, observateur d'événements, stratégies locales,
profils, droits, stockage, déploiement logiciel.

**Support & ITIL** — qualification d'incident, priorisation impact × urgence, escalade,
respect des SLA, rédaction de tickets, clôture.

**Automatisation** — PowerShell (modules, pipeline, `ShouldProcess`), tests Pester, Git.

---

## Méthodologie de diagnostic

Chaque incident du dépôt est traité selon la même séquence :

```
comprendre -> reproduire -> collecter -> identifier les symptomes -> emettre des hypotheses
-> tester -> identifier la cause -> corriger -> retester -> documenter -> cloturer
```

---

## Avancement

- [x] **Phase 0** — Analyse et architecture
- [x] **Phase 1** — Mise en place du HomeLab *(réseau virtuel + NAT, 4 VMs provisionnées)*
- [ ] **Phase 2** — Windows Server + Active Directory
- [ ] **Phase 3** — Postes clients Windows 11
- [ ] **Phase 4** — Réseau, partages, impression
- [ ] **Phase 4B** — GLPI et inventaire de parc
- [ ] **Phase 5** — Bibliothèque de scénarios d'incidents
- [ ] **Phase 6** — Module PowerShell SDToolkit
- [ ] **Phase 7** — Application graphique
- [ ] **Phase 8** — Génération de rapports
- [ ] **Phase 9** — Documentation
- [ ] **Phase 10** — Portfolio

---

## Sécurité et confidentialité

Ce dépôt est public et ne contient **que des données fictives** : les utilisateurs, postes,
adresses et incidents sont inventés pour les besoins du lab. Aucun mot de passe, aucun secret,
aucune donnée réelle de machine n'y figure — voir [`.gitignore`](.gitignore).

Les scripts sont séparés en deux familles : **diagnostic** en lecture seule, et **remédiation**
qui modifie le système. Toute fonction de remédiation implémente `-WhatIf` et `-Confirm`.

---

## Licence

MIT
