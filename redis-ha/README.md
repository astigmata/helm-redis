# redis-ha

Chart Helm pour déployer un **groupe Redis hautement disponible** sur Kubernetes,
sans opérateur ni dépendance externe. Réplication master/replica + bascule
automatique par **Redis Sentinel**, trois sentinels co-localisés avec les nœuds.

## Ce que couvre la HA ici

| Risque | Réponse du chart |
|---|---|
| Perte du pod master | 3 sentinels élisent un replica ; `down-after-milliseconds` = 5 s par défaut |
| Perte d'un nœud Kubernetes | StatefulSet 3 réplicas + anti-affinité (`podAntiAffinity: soft`, `hard` possible) |
| Perte de données à la bascule | `min-replicas-to-write 1` : un master sans replica à jour **refuse** les écritures |
| Perte de données au crash | AOF `everysec` + RDB, sur un PVC par pod |
| Adresse du master qui change | Sentinel annonce des **noms DNS** (`resolve-hostnames`), jamais des IP de pods |
| Drain simultané de plusieurs nœuds | PodDisruptionBudget `maxUnavailable: 1` : la majorité des sentinels est préservée |
| Rolling update qui coupe le service | `preStop` : bascule volontaire avant l'arrêt du master |
| Arrêt complet du groupe | L'état Sentinel est persisté sur le PVC : au redémarrage, le dernier master connu est retrouvé |
| Sentinels fantômes après redémarrage | `sentinel myid` déterministe, dérivé du nom du pod |
| Saturation mémoire → OOMKill | `maxmemory` calculé depuis `resources.limits.memory` |
| Panne silencieuse | Probes `redis-cli`, deux exporters Prometheus, alertes `PrometheusRule` |

## Installation

```bash
helm install redis ./redis-ha -n datastore --create-namespace
```

Profil production (5 nœuds, anti-affinité stricte, monitoring, NetworkPolicy) :

```bash
helm install redis ./redis-ha -n datastore --create-namespace \
  -f redis-ha/ci/production-values.yaml
```

Vérifier que le groupe s'est bien formé :

```bash
helm test redis -n datastore
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster
```

Récupérer le mot de passe (généré une fois, conservé entre les `helm upgrade`) :

```bash
kubectl -n datastore get secret redis-redis-ha \
  -o jsonpath='{.data.redis-password}' | base64 -d
```

## Se connecter

**Passez par Sentinel.** Un client qui se connecte directement à un pod ou au
Service Redis ne basculera jamais tout seul.

```
sentinels   : redis-redis-ha-sentinel.datastore.svc.cluster.local:26379
master name : mymaster
```

```python
from redis.sentinel import Sentinel

s = Sentinel(
    [("redis-redis-ha-sentinel.datastore.svc.cluster.local", 26379)],
    sentinel_kwargs={"password": PASSWORD},
    password=PASSWORD,
)
master = s.master_for("mymaster")   # écritures, suit les bascules
replica = s.slave_for("mymaster")   # lectures
```

Trois Services sont exposés :

| Service | Port | Usage |
|---|---|---|
| `redis-redis-ha-sentinel` | 26379 | **Point d'entrée des clients.** Découverte du master. |
| `redis-redis-ha` | 6379 (+ 9121/9122) | Réparti sur **tous** les pods : lectures et scrape des métriques. Une écriture qui tombe sur un replica échoue en `-READONLY`. |
| `redis-redis-ha-headless` | 6379 / 26379 | DNS stable par pod. Usage interne (réplication, sentinels). |

Adresse du master à un instant t :

```bash
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

## Principales valeurs

### Groupe et HA

| Clé | Défaut | Description |
|---|---|---|
| `replicaCount` | `3` | Nombre de nœuds (redis + sentinel par pod). **Toujours impair** (3, 5, 7). |
| `sentinel.masterGroup` | `mymaster` | Nom du groupe surveillé, référencé par les clients. |
| `sentinel.quorum` | `""` | Vide = majorité stricte `(N+1)/2`. |
| `sentinel.downAfterMilliseconds` | `5000` | Délai avant de déclarer le master en panne. |
| `sentinel.failoverTimeout` | `30000` | Fenêtre au-delà de laquelle une bascule est considérée échouée. |
| `sentinel.parallelSyncs` | `1` | Replicas resynchronisés simultanément après une bascule. |
| `replication.minReplicasToWrite` | `1` | Le master refuse les écritures en dessous. `0` désactive. |
| `replication.maxLagSeconds` | `10` | Au-delà, un replica ne compte plus. |
| `podAntiAffinity` | `soft` | `soft`, `hard` ou `""` (désactivé). |
| `podDisruptionBudget.enabled` / `.maxUnavailable` | `true` / `1` | Protection lors des drains. |
| `terminationGracePeriodSeconds` | `120` | Temps laissé à la bascule volontaire. |
| `gracefulShutdown.enabled` | `true` | Hook `preStop` : force la bascule avant d'arrêter un master. |

### Image, auth, stockage

| Clé | Défaut | Description |
|---|---|---|
| `image.repository` / `image.tag` | `redis` / `7.4.5-alpine` | La même image sert à `redis-server` et `redis-sentinel`. |
| `auth.enabled` | `true` | `false` = aucun mot de passe, `protected-mode no`. |
| `auth.password` | `""` | Vide = généré puis conservé via lookup du Secret. |
| `auth.existingSecret` | `""` | Secret externe (clé `redis-password`). |
| `persistence.enabled` | `true` | **Ne pas désactiver en production** : porte aussi l'état Sentinel. |
| `persistence.size` / `.storageClass` | `20Gi` / `""` | Volume par nœud. |
| `persistenceConfig.appendOnly` / `.appendFsync` | `true` / `everysec` | AOF : limite la perte à ~1 s. |
| `persistenceConfig.save` | 3 règles | Instantanés RDB. Liste vide = RDB désactivé. |
| `resources` | 250m / 1Gi → 2Gi | Pas de limite CPU par défaut (Redis est mono-thread). |
| `maxMemory.type` / `.value` | `relative` / `0.6` | Calculé depuis `resources.limits.memory` (voir plus bas). |
| `maxMemory.policy` | `noeviction` | `allkeys-lru` pour un usage cache. |

### Réseau et observabilité

| Clé | Défaut | Description |
|---|---|---|
| `service.ports.*` | 6379 / 26379 / 9121 / 9122 | redis, sentinel, metrics, sentinel-metrics. |
| `sentinelService.type` | `ClusterIP` | Service de découverte. |
| `networkPolicy.enabled` | `false` | Autorise 6379 et 26379 entre pods, plus les ports clients. |
| `metrics.enabled` | `true` | Exporter `oliver006/redis_exporter` en sidecar. |
| `metrics.sentinel.enabled` | `true` | Second exporter branché sur Sentinel. |
| `metrics.serviceMonitor.enabled` | `false` | Nécessite prometheus-operator. |
| `metrics.prometheusRule.enabled` | `false` | Alertes : nœud down, pas de master, réplication cassée, mémoire, retard. |
| `extraConfiguration` / `sentinel.extraConfiguration` | `""` | Lignes ajoutées à `redis.conf` / `sentinel.conf`. |

Liste complète : `helm show values ./redis-ha`.

## Comment la HA fonctionne concrètement

**Élection du rôle au démarrage.** Le rôle n'est pas figé dans le manifeste : au
démarrage, `start-redis.sh` demande le master courant aux sentinels des *autres*
pods, puis se déclare master ou `replicaof`. Trois sources, par ordre de fiabilité :

1. un sentinel pair qui répond — la vérité du moment ;
2. l'état Sentinel persisté sur le PVC local (`/data/sentinel.conf`) — c'est ce qui
   permet de retrouver le bon master après un **arrêt complet** du groupe, plutôt
   que de repartir aveuglément sur le pod 0 et d'écraser des données plus récentes ;
3. le pod 0, uniquement au tout premier démarrage.

**Noms DNS partout.** Les pods changent d'IP à chaque recréation. Le chart pose
`replica-announce-ip <pod>.<headless>.<ns>.svc.<domain>` côté Redis et
`sentinel resolve-hostnames yes` + `announce-hostnames yes` côté Sentinel : le
groupe raisonne exclusivement en noms stables, y compris dans la réponse de
`SENTINEL get-master-addr-by-name` servie aux clients.

**Identité stable des sentinels.** `sentinel myid` est dérivé du nom du pod par
SHA-1. Sans cela, chaque redémarrage créerait un nouveau sentinel aux yeux des
autres : les entrées fantômes font monter la majorité requise pour autoriser une
bascule, jusqu'à la rendre impossible.

**Configuration effective générée au démarrage.** `redis.conf` et `sentinel.conf`
du ConfigMap ne sont que des modèles. Les scripts y ajoutent le mot de passe et le
rôle, dans un fichier en 0600 — un ConfigMap est lisible par tout le namespace,
le mot de passe n'y figure jamais. Sentinel réécrit ensuite son propre fichier :
c'est la mémoire du groupe, elle vit sur le PVC.

**Arrêt d'un master.** Le hook `preStop` demande une bascule à un sentinel *pair*
(le sentinel local reçoit `SIGTERM` en même temps que Redis, il peut déjà être
parti) et attend qu'elle soit effective. Sans cela, les clients restent en erreur
pendant tout `down-after-milliseconds`.

## Opérations courantes

Forcer une bascule (test de reprise) :

```bash
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel failover mymaster
```

État complet vu par Sentinel :

```bash
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel replicas mymaster
```

Scaler (toujours vers un nombre impair) :

```bash
helm upgrade redis ./redis-ha -n datastore --set replicaCount=5
```

Après une **réduction**, les sentinels gardent en mémoire les nœuds disparus.
Les faire oublier :

```bash
kubectl -n datastore exec redis-redis-ha-0 -c sentinel -- \
  redis-cli -p 26379 sentinel reset mymaster
```

Sauvegarde ponctuelle depuis un replica (n'impacte pas le master) :

```bash
kubectl -n datastore exec redis-redis-ha-1 -c redis -- redis-cli bgsave
kubectl -n datastore cp redis-redis-ha-1:/data/dump.rdb ./dump.rdb -c redis
```

## Points d'attention

- **Un client non Sentinel-aware n'est pas HA.** Il continuera de parler à
  l'ancien master (devenu replica) et recevra des `-READONLY`. C'est le mode de
  panne le plus fréquent de ce type de déploiement.
- **Le Service `redis-redis-ha:6379` ne garantit pas le master.** Il répartit sur
  tous les pods : lectures uniquement.
- **Nombre pair de nœuds inutile.** 4 nœuds tolèrent la même chose que 3 (une
  panne), et Sentinel exige de toute façon une majorité stricte.
- **`replicaCount: 1` ou `2` n'est pas de la HA.** Avec 2 sentinels, la majorité
  est de 2 : la perte d'un nœud rend toute bascule impossible.
- **`persistence.enabled: false` casse deux choses**, pas une : les données Redis
  *et* la mémoire de Sentinel. Après un redémarrage complet, le groupe repart sur
  le pod 0. À réserver aux tests.
- **`min-replicas-to-write` est un compromis assumé.** Il protège des écritures
  perdues, mais rend le master indisponible en écriture quand il n'a plus assez de
  replicas à jour — y compris pendant les quelques secondes qui suivent une
  bascule. Mettre `0` privilégie la disponibilité à la durabilité.
- **Mono-zone.** `podAntiAffinity` répartit sur les nœuds, pas sur les zones :
  ajouter `topologySpreadConstraints` pour du multi-AZ.
- **NetworkPolicy.** Si vous en activez d'autres dans le namespace, laisser passer
  6379 et 26379 entre les pods du groupe.
- **`maxmemory` : ne pas le laisser vide.** Redis ne lit pas la limite mémoire
  cgroup de son conteneur. Sans `maxmemory` explicite, il grossit jusqu'à
  l'OOMKill — qui coupe la réplication net, sans passer par le contrôle de flux.
  Le chart le calcule donc depuis `resources.limits.memory` (0,6 par défaut : la
  marge couvre le copy-on-write d'un `BGSAVE`, les tampons de réplication et la
  fragmentation, qui ne sont pas comptés dans `maxmemory`).
- **`maxmemory-policy: noeviction`** fait échouer les écritures une fois la limite
  atteinte, au lieu de supprimer des clés en silence. Pour un cache, basculer sur
  `allkeys-lru`.
