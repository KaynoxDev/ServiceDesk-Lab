# Inventaire du lab — sources, licences et échéances

> Tenu à jour à chaque ajout de VM ou d'ISO.
> Parade au risque **R3** (expiration des licences d'évaluation) de la phase 0.

## Hôte

| Élément | Valeur |
|---|---|
| OS | Windows 11 Pro 10.0.26200 |
| CPU | Intel Core i5-10400F — 6 cœurs / 12 threads |
| RAM | 15,9 Go |
| Disque | Kingston SNV2S1000G — NVMe SSD 932 Go (**disque physique unique**) |
| Partitions | `A:` 195 Go (Dev) · `C:` 735 Go (système) — même disque 0 |
| Hyperviseur | Hyper-V |
| Dossier ISO | `C:\ISO` |
| Dossier VMs | `A:\VMs` |

## Images d'installation

| ISO | Version | Taille | SHA-256 vérifié | Date de téléchargement |
|---|---|---|---|---|
| `debian-13.6.0-amd64-netinst.iso` | Debian 13.6.0 « Trixie » | 755 Mo | ✅ `65273beed27b2df543b68b65630ba525cfbad8df2b12035732b2dff87d6664e7` | 2026-09-08 |
| Windows Server 2025 Evaluation (EN, x64) | — | ~5,5 Go | ⬜ à vérifier | — |
| Windows 11 Enterprise Evaluation 25H2 (x64) | — | ~6 Go | ⬜ à vérifier | — |

Commande de vérification :

```powershell
(Get-FileHash "C:\ISO\<fichier>.iso" -Algorithm SHA256).Hash
```

## Licences d'évaluation — échéances

⚠️ Les durées courent à partir de l'**installation**, pas du téléchargement.

| VM | Édition | Durée | Date d'installation | Expiration | Remarques |
|---|---|---|---|---|---|
| DC01 | Windows Server 2025 Evaluation | 180 j | *à compléter* | *à compléter* | **Doit s'activer via Internet dans les 10 premiers jours**, sinon arrêt automatique. `slmgr /rearm` pour prolonger. |
| CLI01 | Windows 11 Enterprise Evaluation | 90 j | *à compléter* | *à compléter* | |
| CLI02 | Windows 11 Enterprise Evaluation | 90 j | *à compléter* | *à compléter* | |
| SRV-LNX01 | Debian 13 | illimitée | *à compléter* | — | Libre, aucune échéance |

Vérifier le temps restant sur une VM Windows :

```powershell
slmgr /dli      # informations de licence
slmgr /xpr      # date d'expiration
```

**Principe directeur** : le lab doit rester **reconstructible par script**. Si une évaluation expire, on ne doit pas perdre le travail — les scripts de `powershell/lab-setup/` et les procédures de `docs/procedures/` permettent de tout remonter.

## Plan d'adressage

| Machine | Rôle | IP | Attribution |
|---|---|---|---|
| Hôte — `vEthernet (LAB-Internal)` | Passerelle + NAT | 192.168.10.1 | Fixe |
| DC01 | AD DS, DNS, DHCP, fichiers, impression | 192.168.10.10 | Fixe |
| SRV-LNX01 | GLPI | 192.168.10.20 | Fixe |
| CLI01 | Poste utilisateur | 192.168.10.100–150 | DHCP |
| CLI02 | Poste utilisateur | 192.168.10.100–150 | DHCP |

- Réseau : `192.168.10.0/24` — masque `255.255.255.0`
- Commutateur virtuel : `LAB-Internal` (type *Internal*)
- Domaine AD : `sdlab.lan` — NetBIOS `SDLAB`
- Étendue DHCP : `.100` → `.150`, bail 8 h, option 003 = `.1`, option 006 = `.10`
- DNS : DC01 fait autorité sur `sdlab.lan`, forwarders `1.1.1.1` / `8.8.8.8`
