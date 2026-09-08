# PHASE 0 — Analyse & Architecture du projet "ServiceDesk Lab"

> Document de cadrage. Rédigé avant toute ligne de code.
> Cible : poste Technicien Service Desk — Econocom Bourges (18) — ~24 k€ brut/an.
> Machine hôte : Windows 11 Pro 26200, Intel i5-10400F (6c/12t), 15,9 Go RAM, C: 116 Go libres / A: 100 Go libres.

---

## 1. Analyse de l'objectif réel

L'objectif affiché est « construire un HomeLab ». L'objectif **réel** est différent et il faut le garder en tête à chaque décision :

> Transformer une absence d'expérience professionnelle en **preuve de compétence vérifiable en 45 minutes d'entretien**.

Conséquences directes sur le projet :

| Ce qui est jugé en entretien | Poids | Ce que ça implique dans le projet |
|---|---|---|
| Méthode de diagnostic structurée | ★★★ | La méthodologie 11 étapes doit être visible dans CHAQUE ticket |
| Vocabulaire ITIL (incident / demande / problème, SLA, escalade N1→N2) | ★★★ | Le modèle de ticket doit être ITIL, pas inventé |
| Gestes AD du quotidien (reset MDP, déverrouillage, groupes) | ★★★ | Phase 2 est non négociable |
| Communication utilisateur (reformuler, rassurer, qualifier) | ★★★ | Chaque scénario contient un dialogue utilisateur |
| Réseau de base (IP, DNS, DHCP, passerelle) | ★★ | Phase 4 |
| Automatisation PowerShell | ★★ | Différenciateur fort à ce niveau de salaire |
| Application graphique C# | ★ | Effet « waouh », mais NE DOIT PAS manger le budget temps |

**Le piège principal à éviter** : le risque n°1 de ce projet est de passer 80 % du temps sur l'application WPF (la partie amusante) et d'arriver à l'entretien sans savoir déverrouiller un compte AD. Econocom recrute un technicien Service Desk, pas un développeur .NET. L'app est le bonus qui fait la différence *à compétences support égales*. La roadmap ci-dessous impose donc l'ordre : **lab → gestes métier → tickets → automatisation → app**.

Contexte employeur : Econocom est une ESN / société d'infogérance. Un Service Desk N1 chez eux = centre de services mutualisé, respect de SLA contractuels, outil de ticketing imposé (GLPI, EasyVista ou ServiceNow), process ITIL, escalade vers N2. Le projet doit refléter ça, pas un bricolage perso.

---

## 2. Compétences à acquérir — cartographie

Chaque compétence est reliée à la phase qui la produit et à la **preuve** qui la démontre au recruteur.

### 2.1 Windows poste de travail

| Compétence | Phase | Preuve portfolio |
|---|---|---|
| Installation & configuration d'un poste | 3 | Procédure documentée + captures |
| Comptes / profils / droits locaux | 3 | Scénarios 012, 013 |
| Services, processus, gestionnaire des tâches | 3 / 5 | Scénarios 007, 009 |
| Observateur d'événements | 3 / 6 | Fonction `Get-SDEventErrors` |
| Périphériques, Windows Update | 3 / 5 | Scénario 010 |
| Installation / désinstallation de logiciels (WinGet) | 3 / 5 | Scénario 011 + script de déploiement |
| Stockage, nettoyage disque | 5 | Scénario 008 + remédiation |
| Stratégies locales (gpedit / secpol) | 3 | Procédure |

### 2.2 Active Directory

| Compétence | Phase | Preuve |
|---|---|---|
| Installation AD DS, promotion DC, forêt/domaine | 2 | Procédure + schéma |
| OU, utilisateurs, groupes, ordinateurs | 2 | Script de peuplement (30 users fictifs) |
| Délégation de droits | 2 | Procédure « déléguer le reset MDP au N1 » |
| Verrouillage de compte / reset MDP | 2 / 5 | Scénario 002 — **le geste N1 le plus fréquent** |
| GPO (lecteurs réseau, fond d'écran, restrictions) | 2 / 4 | 4 GPO documentées |
| Scripts de connexion, lecteurs réseau | 2 / 4 | Scénario 004 |
| Jonction d'un poste au domaine | 3 | Scénario 014 |

### 2.3 Réseau

IPv4, masque, passerelle, DHCP (bail, étendue, réservation), DNS (A, PTR, forwarders, cache), `ipconfig`, `ping`, `tracert`, `nslookup`, `arp`, `route`, `netstat`, `Test-NetConnection`, partages SMB, ports courants (53, 80, 443, 445, 389, 3389). → Phases 1 et 4, prouvé par les scénarios 001, 005, 006, 015.

### 2.4 Support utilisateur & ITIL

Qualification d'appel, reformulation, questionnement fermé/ouvert, catégorisation, priorisation (impact × urgence), respect SLA, escalade, clôture avec accord utilisateur. → Phase 5, prouvé par 15 tickets rédigés.

### 2.5 Transverses

PowerShell (cmdlets, pipeline, objets, fonctions, modules, gestion d'erreurs, `ShouldProcess`), Git/GitHub, documentation technique, C#/WPF/MVVM. → Phases 6, 7, 9, 11.

---

## 3. Architecture cible

### 3.1 Choix de l'hyperviseur : Hyper-V

`HypervisorPresent = True` sur l'hôte : un hyperviseur tourne déjà (Hyper-V, WSL2 ou la sécurité VBS de Windows 11). Dans cet état, **VirtualBox et VMware Workstation fonctionnent en mode dégradé et instable**. Décision : **Hyper-V**, déjà inclus dans Windows 11 Pro, gratuit, et c'est l'hyperviseur Microsoft — cohérent avec un lab 100 % Windows Server.

Bénéfice pédagogique décisif : les **checkpoints** (instantanés). Ils permettent de casser volontairement une VM pour un scénario, puis de revenir en 30 secondes à l'état sain. Sans ça, la bibliothèque de scénarios n'est pas rejouable.

### 3.2 Topologie réseau

```
        INTERNET
            |
   [ Box / routeur maison ]
            |
   +------------------------+
   |  HOTE Windows 11 Pro   |
   |  i5-10400F / 16 Go     |
   |                        |
   |  New-NetNat  <-- NAT du lab vers Internet
   |  vEthernet (LAB-Internal) = 192.168.10.1  <-- PASSERELLE du lab
   +-----------+------------+
               |  vSwitch Hyper-V "LAB-Internal" (type Internal)
               |  Reseau 192.168.10.0/24
   +-----------+---------------+---------------+--------------+
   |           |               |               |              |
[DC01]      [CLI01]         [CLI02]      [SRV-LNX01]      (futures VM)
.10 fixe    DHCP .100+      DHCP .100+   .20 fixe
```

| VM | OS | Rôles | IP | vCPU | RAM (dyn.) | Disque |
|---|---|---|---|---|---|---|
| **DC01** | Windows Server 2025 Eval (Desktop Experience) | AD DS, DNS, DHCP, serveur de fichiers, serveur d'impression | 192.168.10.10 fixe | 2 | 2–3 Go | 60 Go dyn. |
| **CLI01** | Windows 11 Enterprise Eval | Poste utilisateur « Jean Dupont » | DHCP | 2 | 3–4 Go | 60 Go dyn. |
| **CLI02** | Windows 11 Enterprise Eval | Poste utilisateur « Marie Martin » | DHCP | 2 | 3–4 Go | 60 Go dyn. |
| **SRV-LNX01** | Debian 13 | GLPI (ticketing réel) + GLPI Agent | 192.168.10.20 fixe | 2 | 1,5 Go | 20 Go dyn. |

> **Décision validée** : GLPI fait partie du périmètre principal, pas des options. SRV-LNX01 est donc une VM obligatoire.

- Domaine AD : **`sdlab.lan`** — NetBIOS `SDLAB`.
  *Pourquoi pas `.local` ?* `.local` est réservé au mDNS (Bonjour/Avahi) et Microsoft le déconseille depuis Windows Server 2012. Savoir expliquer ça en entretien est un vrai point.
- Passerelle : **192.168.10.1** = carte virtuelle de l'hôte, avec `New-NetNat` pour la sortie Internet. Une seule carte réseau par VM → topologie réaliste, et on peut casser indépendamment la passerelle et le DNS.
- Étendue DHCP : 192.168.10.100 → 192.168.10.150, bail 8 h, option 003 = .1, option 006 = .10.
- DNS : DC01 fait autorité sur `sdlab.lan`, forwarders vers 1.1.1.1 / 8.8.8.8.

### 3.3 Budget RAM — la vraie contrainte

16 Go, dont ~5 Go pour l'hôte (Windows + VS Code + navigateur). Reste ~10–11 Go. **Toutes les VMs ne tourneront jamais en même temps.** On travaille par profils :

| Profil | VMs allumées | RAM | Usage |
|---|---|---|---|
| A — quotidien | DC01 + CLI01 | ~6,5 Go | 90 % du travail |
| B — multi-postes | DC01 + CLI01 + CLI02 | ~10 Go | GPO, droits, scénarios comparatifs |
| C — ticketing *(le plus fréquent à partir de la phase 4B)* | DC01 + CLI01 + SRV-LNX01 | ~8 Go | GLPI + scénarios |
| ✗ interdit | les 4 ensemble | ~12 Go | Swap, lab inutilisable |

Mémoire dynamique Hyper-V activée partout (min 1 Go / max 4 Go). CLI02 n'est créé qu'en phase 3.

SRV-LNX01 étant désormais obligatoire, le profil C devient le mode de travail courant : CLI02 ne sera allumé que ponctuellement (GPO, droits, scénarios comparatifs), et jamais en même temps que SRV-LNX01.

### 3.4 Budget disque

Disques dynamiques : ~20 Go réels par VM Windows après installation, + les checkpoints (~2–5 Go chacun). Total réaliste : **70 à 90 Go**. À placer sur **C: (116 Go libres)** ou A: (100 Go libres) — le disque le plus rapide si l'un des deux est un SSD. Règle : ne jamais descendre sous 25 Go libres sur le disque système.

### 3.5 Architecture logicielle (app + scripts)

Décision structurante : **les scripts PowerShell sont la source de vérité, l'application n'est qu'une façade.**

```
   +--------------------------------+
   |  ServiceDeskToolkit.App (WPF)  |   <- C# .NET 10 + MVVM
   |  Dashboard / modules / rapports|
   +---------------+----------------+
                   |  lance pwsh.exe -File <script> -AsJson
                   |  recupere du JSON sur stdout -> deserialisation
   +---------------v----------------+
   |  Module PowerShell SDToolkit   |   <- utilisable SEUL, sans l'app
   |  Get-SDSystemInfo, Test-SDNetwork, ...
   +--------------------------------+
```

Pourquoi ce découplage :

1. Les scripts restent exécutables sur n'importe quel poste client, sans installer l'app — c'est ce qu'on fait en vrai Service Desk (on ne déploie pas une app WPF sur le poste d'un utilisateur pour diagnostiquer).
2. Le recruteur peut lire et exécuter un script en 10 secondes ; il ne compilera pas une solution .NET.
3. Si l'app n'est pas finie avant l'entretien, le toolkit PowerShell reste 100 % démontrable. **Le projet ne peut pas échouer sur sa partie la plus risquée.**
4. Contrat d'échange unique (JSON) = testable avec Pester, versionnable, documentable.

Séparation **Diagnostic (lecture seule) / Remédiation (écriture)** imposée au niveau du code :

- deux dossiers distincts, deux préfixes de nommage ;
- toute fonction de remédiation déclare `[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]` et appelle `$PSCmdlet.ShouldProcess()` → `-WhatIf` et `-Confirm` gratuits et natifs ;
- dans l'app, le mode Remédiation est un onglet séparé, avec bandeau d'avertissement et double confirmation ;
- journalisation obligatoire de toute action de remédiation (qui, quoi, quand, résultat).

---

## 4. Logiciels nécessaires — tous gratuits ou libres

### Déjà présents sur l'hôte (vérifié)

Git 2.54 · GitHub CLI 2.97 · PowerShell 7 · VS Code · .NET SDK 10.0.303

### À installer

| Logiciel | Rôle | Licence / coût |
|---|---|---|
| Hyper-V | Hyperviseur | Inclus Windows 11 Pro |
| Windows Server 2025 **Evaluation** | DC01 | Gratuit 180 j (Evaluation Center) |
| Windows 11 Enterprise **Evaluation** | CLI01/CLI02 | Gratuit 90 j (Evaluation Center) |
| Debian 13 netinst | SRV-LNX01 / GLPI | Libre |
| GLPI + GLPI Agent | Ticketing & inventaire réels | Libre (GPL) — **très utilisé en France** |
| RSAT | Outils AD depuis CLI01 | Fonctionnalité Windows |
| Sysinternals Suite | Process Explorer, Autoruns, PsExec | Gratuit Microsoft |
| WinGet | Déploiement/désinstallation de logiciels | Inclus Windows |
| Wireshark *(optionnel)* | Analyse réseau | Libre |
| Visual Studio 2022 Community | Confort XAML/WPF | Gratuit (usage individuel) |
| NuGet : `WPF-UI`, `CommunityToolkit.Mvvm`, `LiveChartsCore` | UI Fluent, MVVM, graphiques | Libres (MIT) |
| PSScriptAnalyzer, Pester | Qualité + tests des scripts | Libres |
| Mermaid (dans le Markdown) | Schémas versionnés | Libre |
| gitleaks *(pre-commit)* | Empêche la fuite de secrets | Libre |

**Volume de téléchargement : ~11 Go d'ISO.** À lancer dès aujourd'hui, c'est le chemin critique.

### Choix de la techno d'interface : **WPF (.NET 10) + WPF-UI + CommunityToolkit.Mvvm**

| Option | Verdict |
|---|---|
| **WPF + WPF-UI** | ✅ **Retenu.** .NET 10 déjà installé, rendu Fluent/Windows 11 moderne, data binding mature, énorme documentation, écosystème Microsoft cohérent avec le poste |
| WinUI 3 | ❌ Packaging et outillage encore capricieux, pas de gain visible ici |
| Avalonia | ❌ Excellent, mais son intérêt est le multiplateforme — inutile pour un outil Service Desk Windows |
| WinForms | ❌ Rendu daté, exactement ce qu'il faut éviter |
| Web (Blazor/Electron) | ❌ Ajoute un runtime et une complexité de déploiement injustifiés |

Bonus entretien : WPF/MVVM est encore massivement présent dans les outils internes des ESN.

---

## 5. Structure GitHub proposée

Un **seul dépôt** (monorepo). Un projet éclaté en 5 dépôts donne l'impression de 5 projets inachevés.

```
ServiceDesk-Lab/
├── README.md                  <- vitrine : schema, GIF de demo, resultats chiffres
├── LICENSE                    <- MIT
├── CONTRIBUTING.md
├── CHANGELOG.md               <- format Keep a Changelog
├── SECURITY.md
├── .gitignore
├── .env.example
├── .github/
│   ├── workflows/ci.yml       <- PSScriptAnalyzer + Pester + build .NET
│   ├── ISSUE_TEMPLATE/incident.yml
│   └── pull_request_template.md
├── docs/
│   ├── 00-analyse-phase0.md
│   ├── architecture/          <- schemas Mermaid, plan d'adressage, inventaire
│   ├── procedures/            <- modes operatoires pas-a-pas (coeur du portfolio)
│   ├── troubleshooting/       <- arbres de decision par symptome
│   ├── methodologie/          <- les 11 etapes de diagnostic
│   └── portfolio/
├── powershell/
│   ├── SDToolkit/             <- le module (.psd1 / .psm1)
│   │   ├── Public/Diagnostics/
│   │   ├── Public/Remediation/
│   │   └── Private/
│   ├── lab-setup/             <- scripts de construction du lab (idempotents)
│   └── tests/                 <- Pester
├── app/
│   └── ServiceDeskToolkit/    <- solution WPF
├── scenarios/
│   └── 001-pas-internet/
│       ├── README.md          <- version ETUDIANT (enonce seul)
│       ├── SOLUTION.md        <- corrige detaille
│       ├── break.ps1          <- provoque la panne
│       ├── restore.ps1        <- remet en etat
│       └── ticket-INC-0001.md
├── tickets/                   <- tickets au format Markdown + index JSON
├── reports/                   <- exemples de rapports generes (donnees fictives)
└── screenshots/
```

Règle absolue : `reports/` et `screenshots/` ne contiennent **que des données fictives**. Aucun nom réel, aucune IP publique, aucun numéro de série de la vraie machine, aucun hash de mot de passe.

---

## 6. Roadmap

Hypothèse de travail : **~10 h/semaine**. À réviser selon la date de l'entretien.

| Phase | Contenu | Charge | Livrable qui prouve la phase |
|---|---|---|---|
| **0** | Analyse & architecture *(ce document)* | 2 h | `docs/00-analyse-phase0.md` |
| **1** | HomeLab : Hyper-V, vSwitch, NAT, ISO, VM vides | 6 h | Schéma réseau + script `New-SDLabSwitch.ps1` |
| **2** | Windows Server + AD DS + DNS + DHCP + OU/users/GPO | 12 h | Domaine `sdlab.lan` + 30 comptes fictifs + 4 GPO |
| **3** | Clients Windows 11, jonction domaine, RSAT, profils | 8 h | CLI01 + CLI02 dans le domaine, procédure documentée |
| **4** | Réseau : partages, lecteurs mappés, imprimante, tests | 8 h | 6 procédures réseau + plan d'adressage |
| **4B** | Debian + GLPI + authentification LDAP sur AD + GLPI Agent sur les postes | 8 h | GLPI fonctionnel, connexion avec un compte AD, inventaire auto des postes |
| **5** | 15 scénarios (énoncé + solution + break/restore + ticket **saisi dans GLPI**) | 20 h | `scenarios/` complet — **cœur du portfolio** |
| **6** | Module PowerShell SDToolkit (diag + remédiation + logs) | 20 h | Module publiable + tests Pester + CI verte |
| **7** | Application WPF (dashboard + modules) | 25 h | .exe démontrable + captures |
| **8** | Rapports HTML / JSON / TXT (+ PDF) | 8 h | 3 rapports d'exemple |
| **9** | Documentation complète | 8 h | `docs/` finalisé |
| **10** | Portfolio / README vitrine | 5 h | README avec GIF de démo |
| **11** | GitHub pro : branches, PR, tags, releases, Issues, Projects | 5 h | Historique Git propre + v1.0.0 |
| **12** | Préparation entretien Econocom | 8 h | Pitchs 2 min / 5 min + Q/R + démo répétée |

**Total ≈ 143 h ≈ 14 semaines à 10 h/sem.**

> **Décisions validées en fin de phase 0** — rythme retenu : ~10 h/semaine, pas d'entretien encore fixé → roadmap complète, les 12 phases dans l'ordre, sans compression. Ticketing : GLPI dès la phase 4B (et non en option de fin de projet).

⚠️ Git n'est pas la phase 11 : on initialise le dépôt **dès la phase 1** et on commite à chaque phase. La phase 11 ne fait que professionnaliser (releases, tags, Issues, Projects).

### Point de présentabilité minimale

**À la fin de la phase 6, le projet est déjà présentable en entretien.** Lab fonctionnel + 15 scénarios résolus + toolkit PowerShell = un dossier solide. Les phases 7 à 12 sont de la valorisation. Si l'entretien tombe tôt, on coupe après la phase 6 sans que le projet paraisse inachevé.

### Piste accélérée (entretien dans < 3 semaines)

Phases 1 → 2 → 3 → 5 (réduite à 6 scénarios) → 6 (réduit à 12 fonctions) → 12. ≈ 45 h.

---

## 7. Ce qu'il faut faire en premier (ordre exact)

1. **Lancer les téléchargements d'ISO maintenant** (~11 Go, plusieurs heures) — chemin critique.
2. Vérifier/activer Hyper-V (nécessite une élévation + un redémarrage).
3. Choisir le disque d'accueil des VMs et libérer l'espace.
4. `git init` + structure de dossiers + `.gitignore` + `README.md` initial → **premier commit**.
5. Créer le vSwitch `LAB-Internal` + le NAT (script idempotent, versionné).
6. Créer et installer DC01.

---

## 8. Ce qui peut attendre (et ce qu'on n'ajoutera PAS)

**Plus tard, si le temps le permet :**

- Consommation de l'**API REST de GLPI** depuis le toolkit PowerShell et l'app WPF (créer un ticket automatiquement depuis un diagnostic) — phase 6/7, très fort ROI entretien
- Passerelle RRAS sur DC01 à la place du NAT de l'hôte (permet de casser le routage de façon réaliste)
- Entra ID Free + jonction hybride (Service Desk moderne = de plus en plus hybride)
- Export PDF des rapports
- Déploiement logiciel par GPO ou WinGet à grande échelle

**Volontairement exclu** (complexité sans bénéfice pour un profil junior Service Desk) :

- Exchange Server → les incidents Outlook seront simulés avec un profil local, pas un serveur de messagerie
- WSUS, MDT/PXE, SCCM/Intune complet → hors périmètre N1, très gourmands en RAM et en temps
- Cluster, haute disponibilité, second DC, PKI, VLAN, pare-feu virtuel
- Docker/Kubernetes (GLPI sera installé nativement sur Debian — LAMP à la main, c'est justement l'exercice Linux qui a de la valeur)
- Second outil de ticketing (osTicket, Zammad) : GLPI seul suffit largement

Critère de décision, appliqué systématiquement : *utile au technicien Service Desk ? utile à l'apprentissage ? montrable en entretien ? valorisable au portfolio ?* — si non aux quatre, on n'ajoute pas.

---

## 9. Risques identifiés et parades

| # | Risque | Gravité | Parade |
|---|---|---|---|
| R1 | **16 Go de RAM** insuffisants si tout tourne | Élevée | Profils d'exécution A/B/C, mémoire dynamique, jamais 4 VMs |
| R2 | **Espace disque** saturé par VMs + checkpoints | Élevée | Disques dynamiques, max 3 checkpoints/VM, purge planifiée, alerte à 25 Go |
| R3 | **Expiration des licences d'évaluation** (Server 180 j / Win11 90 j) | Moyenne | Noter les dates d'expiration dans `docs/architecture/inventaire.md` ; `slmgr /rearm` ; le lab doit être **reconstructible par script** |
| R4 | **Sur-ingénierie de l'app WPF** qui dévore le temps | **Très élevée** | App en phase 7 seulement ; MVP à 5 modules ; time-box 25 h ; le toolkit PowerShell reste le livrable de secours |
| R5 | **Projet inachevé le jour J** | Élevée | Chaque phase produit un livrable autonome ; point de présentabilité fixé à la phase 6 |
| R6 | Windows 11 refuse de s'installer en VM (TPM/Secure Boot) | Moyenne | VM **Génération 2** + `Enable-VMTPM` + Secure Boot activé — à documenter, bon sujet d'entretien |
| R7 | Restaurer un **checkpoint du DC** casse AD (USN rollback, dérive horaire) | Moyenne | Checkpoints *de production* sur DC01 ; ne jamais restaurer le DC pendant que les clients tournent ; casser les clients plutôt que le DC |
| R8 | **Secret ou donnée réelle commité** sur GitHub | Élevée | `.gitignore` strict, `.env.example` uniquement, hook pre-commit gitleaks, données 100 % fictives, relecture avant chaque push |
| R9 | Passer pour un « dev » et non un technicien support | Moyenne | Le discours d'entretien part TOUJOURS de l'incident utilisateur, jamais du code |
| R10 | Découragement / abandon en cours de route | Moyenne | Commits fréquents, journal d'apprentissage, chaque phase se termine par une victoire visible |
| R11 | Perte de temps sur des ISO mal téléchargées | Faible | Vérification systématique du hash SHA-256 |
| R12 | **GLPI** = première expérience Linux (LAMP, droits fichiers, Apache, MariaDB) → phase 4B qui déborde | Moyenne | Procédure pas-à-pas commentée, checkpoint Debian avant chaque étape risquée, time-box 8 h ; en cas de blocage, on bascule temporairement sur les tickets Markdown pour ne pas bloquer la phase 5 |

---

## 10. Méthode d'apprentissage

Pour chaque module, dans cet ordre :

1. **Concept** — comprendre le mécanisme, en français simple
2. **Pourquoi en Service Desk** — faire le lien avec un appel utilisateur réel
3. **Exercice** — se fixer un objectif, pas suivre une marche à suivre
4. **Mise en pratique sans aide**
5. **Recherche documentaire** en cas de blocage, avant toute solution toute faite
6. **Comparaison avec la solution de référence**
7. **Rédaction de la procédure** dans `docs/procedures/`

Un module n'est acquis que lorsque la procédure est écrite et rejouable de mémoire.

Et pour chaque incident, la méthodologie en 11 étapes : comprendre → reproduire → collecter → identifier les symptômes → émettre des hypothèses → tester → identifier la cause → corriger → retester → documenter → clôturer.

---

## Statut

Document de cadrage figé avant le démarrage de la phase 1. Toute évolution d'architecture décidée en cours de projet est reportée ici et tracée dans `CHANGELOG.md`.
