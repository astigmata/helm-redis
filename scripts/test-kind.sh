#!/usr/bin/env bash
#
# Test de bout en bout du chart redis-ha dans un cluster KinD.
#
# Le script cree un cluster KinD (1 control-plane + 3 workers), y deploie le
# chart avec 3 noeuds, puis verifie que la HA fonctionne reellement : formation
# du groupe, replication, bascule Sentinel apres la perte brutale du master,
# continuite des ecritures et integrite des donnees.
#
# Usage : scripts/test-kind.sh [options]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Parametres
# ---------------------------------------------------------------------------
CHART_DIR="${CHART_DIR:-$REPO_DIR/redis-ha}"
CLUSTER_NAME="${CLUSTER_NAME:-redis-ha-e2e}"
K8S_VERSION="${K8S_VERSION:-1.30.8}"
NODE_IMAGE=""
WORKERS="${WORKERS:-3}"
REPLICAS="${REPLICAS:-3}"
NAMESPACE="${NAMESPACE:-datastore}"
RELEASE="${RELEASE:-redis}"
TIMEOUT="${TIMEOUT:-600s}"
KEEP=false
REUSE=false
SKIP_PRELOAD=false
SKIP_SYSCTL_CHECK=false
EXTRA_VALUES=()
MONITORING=false
MONITORING_DIR="${MONITORING_DIR:-$REPO_DIR/test/monitoring}"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v2.53.0}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:11.1.0}"
PROM_PORT="${PROM_PORT:-19090}"
GRAFANA_PORT="${GRAFANA_PORT:-13000}"

# Delai maximum accorde a Sentinel pour promouvoir un nouveau master
FAILOVER_DEADLINE="${FAILOVER_DEADLINE:-120}"

# Version minimale de kind embarquant l'image de noeud v1.30.8
KIND_MIN_VERSION="0.26.0"
# Limites inotify minimales pour un cluster KinD multi-noeuds
MIN_INOTIFY_INSTANCES="${MIN_INOTIFY_INSTANCES:-512}"
MIN_INOTIFY_WATCHES="${MIN_INOTIFY_WATCHES:-524288}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --k8s-version <v>   Version de Kubernetes (defaut: $K8S_VERSION)
  --node-image <img>  Image de noeud KinD (defaut: kindest/node:v<k8s-version>)
  --replicas <n>      Nombre de noeuds Redis (defaut: $REPLICAS)
  --workers <n>       Nombre de workers KinD (defaut: $WORKERS)
  --cluster <nom>     Nom du cluster KinD (defaut: $CLUSTER_NAME)
  --namespace <ns>    Namespace de deploiement (defaut: $NAMESPACE)
  --release <nom>     Nom de la release Helm (defaut: $RELEASE)
  --keep              Ne pas detruire le cluster a la fin (debug)
  --reuse             Reutiliser un cluster KinD existant du meme nom
  --skip-preload      Ne pas precharger les images dans les noeuds
  --skip-sysctl-check Ne pas verifier les limites inotify de l'hote
  --values <fichier>  Fichier de values supplementaire (repetable)
  --monitoring        Deploie Prometheus + Grafana (dashboard Redis) et
                      verifie que les metriques du chart y remontent
  -h, --help          Cette aide
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s-version) K8S_VERSION="$2"; shift 2 ;;
    --node-image)  NODE_IMAGE="$2"; shift 2 ;;
    --replicas)    REPLICAS="$2"; shift 2 ;;
    --workers)     WORKERS="$2"; shift 2 ;;
    --cluster)     CLUSTER_NAME="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --release)     RELEASE="$2"; shift 2 ;;
    --keep)        KEEP=true; shift ;;
    --reuse)       REUSE=true; shift ;;
    --skip-preload) SKIP_PRELOAD=true; shift ;;
    --skip-sysctl-check) SKIP_SYSCTL_CHECK=true; shift ;;
    --values|-f)   EXTRA_VALUES+=("$2"); shift 2 ;;
    --monitoring)  MONITORING=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; usage; exit 2 ;;
  esac
done

NODE_IMAGE="${NODE_IMAGE:-kindest/node:v${K8S_VERSION}}"

# ---------------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

FAILURES=0
CHECKS=0

step() { printf '\n%s==> %s%s\n' "$C_BLUE$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
pass() { CHECKS=$((CHECKS + 1)); printf '    %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() {
  CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
  printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"
}
die() { printf '%s[ERREUR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# check_eq <description> <valeur attendue> <valeur obtenue>
check_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1 (=$3)"; else fail "$1 : attendu '$2', obtenu '$3'"; fi
}

check_ne() {
  if [[ "$2" != "$3" ]]; then pass "$1 (=$3)"; else fail "$1 : valeur inchangee ('$3')"; fi
}

# ---------------------------------------------------------------------------
# Nettoyage
# ---------------------------------------------------------------------------
PF_PIDS=()
VALUES_FILE=""
CLUSTER_CREATED=false

cleanup() {
  local rc=$?
  set +e
  for pid in ${PF_PIDS+"${PF_PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  done
  [[ -n "$VALUES_FILE" ]] && rm -f "$VALUES_FILE"
  if [[ "$CLUSTER_CREATED" == true && "$KEEP" == false ]]; then
    step "Suppression du cluster KinD $CLUSTER_NAME"
    if [[ "$MONITORING" == true ]]; then
      # Sans --keep, Prometheus et Grafana partent avec le cluster : le dire
      # ici evite un `make grafana` qui ne trouve plus de contexte kubectl.
      info "La stack d'observabilite disparait avec le cluster."
      info "Pour la garder : --keep (ou 'make monitoring-up'), puis 'make grafana'."
    fi
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
  elif [[ "$KEEP" == true ]] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    printf '\nCluster conserve. Pour le supprimer : kind delete cluster --name %s\n' "$CLUSTER_NAME"
    if [[ "$MONITORING" == true ]]; then
      printf 'Grafana    : kubectl --context kind-%s -n monitoring port-forward svc/grafana 3000:3000\n' "$CLUSTER_NAME"
      printf '             puis http://127.0.0.1:3000 (acces anonyme, dashboard "Redis HA")\n'
      printf 'Prometheus : kubectl --context kind-%s -n monitoring port-forward svc/prometheus 9090:9090\n' "$CLUSTER_NAME"
    fi
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Prerequis
# ---------------------------------------------------------------------------
step "Verification des prerequis"
for bin in docker kind kubectl helm curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin est requis mais introuvable."
done
docker info >/dev/null 2>&1 || die "Le daemon Docker n'est pas joignable."
[[ -d "$CHART_DIR" ]] || die "Chart introuvable : $CHART_DIR"
info "docker $(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
info "$(kind version)"
info "$(helm version --short)"

# L'image de noeud v1.30.8 n'est publiee qu'a partir de kind 0.26.0 : avec une
# version plus ancienne, le demarrage du control-plane peut echouer.
KIND_VERSION="$(kind version | sed -n 's/^kind v\([0-9.]*\).*/\1/p')"
if [[ -n "$KIND_VERSION" ]]; then
  lowest="$(printf '%s\n%s\n' "$KIND_VERSION" "$KIND_MIN_VERSION" | sort -V | head -1)"
  if [[ "$lowest" == "$KIND_VERSION" && "$KIND_VERSION" != "$KIND_MIN_VERSION" ]]; then
    warn "kind $KIND_VERSION est anterieur a $KIND_MIN_VERSION : l'image $NODE_IMAGE"
    warn "peut ne pas demarrer. Mettre kind a jour en cas d'echec de creation."
  fi
fi

# Chaque noeud KinD consomme des instances inotify (kubelet, kube-proxy,
# controller-manager, containerd). Sous les limites par defaut de beaucoup de
# distributions, kube-proxy plante en boucle avec "too many open files" et les
# workers n'arrivent pas a rejoindre le cluster.
INOTIFY_INSTANCES="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
INOTIFY_WATCHES="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
info "fs.inotify.max_user_instances = $INOTIFY_INSTANCES (min conseille : $MIN_INOTIFY_INSTANCES)"
info "fs.inotify.max_user_watches   = $INOTIFY_WATCHES (min conseille : $MIN_INOTIFY_WATCHES)"
if [[ "$SKIP_SYSCTL_CHECK" == false && "$INOTIFY_INSTANCES" -lt "$MIN_INOTIFY_INSTANCES" ]]; then
  printf '%s[ERREUR]%s fs.inotify.max_user_instances=%s : trop bas pour un cluster KinD\n' \
    "$C_RED" "$C_RESET" "$INOTIFY_INSTANCES" >&2
  printf '        multi-noeuds. kube-proxy plantera en "too many open files" et les\n' >&2
  printf '        workers ne rejoindront pas le cluster.\n' >&2
  printf '\nCorriger (temporaire, jusqu%sau redemarrage) :\n' "'" >&2
  printf '  sudo sysctl -w fs.inotify.max_user_instances=%s fs.inotify.max_user_watches=%s\n' \
    "$MIN_INOTIFY_INSTANCES" "$MIN_INOTIFY_WATCHES" >&2
  printf '\nOu de facon permanente, en deux commandes distinctes :\n' >&2
  printf '  echo -e "fs.inotify.max_user_instances=%s\\nfs.inotify.max_user_watches=%s" \\\n' \
    "$MIN_INOTIFY_INSTANCES" "$MIN_INOTIFY_WATCHES" >&2
  printf '    | sudo tee /etc/sysctl.d/99-kind.conf\n' >&2
  printf '  sudo sysctl -p /etc/sysctl.d/99-kind.conf\n' >&2
  # Enchainees avec &&, le second sudo peut redemander le mot de passe et etre
  # abandonne : le fichier existe alors sans que la limite active ait change.
  if [[ -f /etc/sysctl.d/99-kind.conf ]]; then
    printf '\n%s[NOTE]%s /etc/sysctl.d/99-kind.conf existe deja mais la limite active est\n' \
      "$C_YELLOW" "$C_RESET" >&2
    printf '       toujours trop basse : il ne manque que le rechargement ci-dessus\n' >&2
    printf '       (ou un redemarrage).\n' >&2
  fi
  printf '\nPour ignorer cette verification : --skip-sysctl-check\n' >&2
  exit 1
fi

# Les watches sont moins critiques : 65536 suffit en pratique pour ~4 noeuds.
if [[ "$INOTIFY_WATCHES" -lt "$MIN_INOTIFY_WATCHES" ]]; then
  warn "fs.inotify.max_user_watches=$INOTIFY_WATCHES (conseille : $MIN_INOTIFY_WATCHES)."
  warn "Suffisant pour un petit cluster, a augmenter si les noeuds deviennent instables."
fi

# Les autres clusters KinD consomment ces memes limites.
OTHER_CLUSTERS="$(kind get clusters 2>/dev/null | grep -vx "$CLUSTER_NAME" | grep -c . || true)"
if [[ "$OTHER_CLUSTERS" -gt 0 ]]; then
  warn "$OTHER_CLUSTERS autre(s) cluster KinD deja en cours d'execution : ils consomment"
  warn "des instances inotify et de la memoire. Les arreter en cas d'instabilite."
fi

# Toutes les images referencees par le chart, exporters compris.
mapfile -t CHART_IMAGES < <(helm template preload "$CHART_DIR" \
  | awk '/^[[:space:]]*image:[[:space:]]/ {gsub(/"/, "", $2); print $2}' | sort -u)
[[ ${#CHART_IMAGES[@]} -gt 0 ]] || die "Aucune image trouvee dans le chart rendu."
info "images du chart : ${CHART_IMAGES[*]}"

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------
step "helm lint"
helm lint "$CHART_DIR" --strict --set replicaCount="$REPLICAS"

# ---------------------------------------------------------------------------
# Cluster KinD
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if [[ "$REUSE" == true ]]; then
    step "Reutilisation du cluster KinD existant $CLUSTER_NAME"
  else
    die "Le cluster '$CLUSTER_NAME' existe deja. Utiliser --reuse ou : kind delete cluster --name $CLUSTER_NAME"
  fi
else
  step "Creation du cluster KinD $CLUSTER_NAME (Kubernetes $K8S_VERSION, $WORKERS workers)"
  {
    echo "kind: Cluster"
    echo "apiVersion: kind.x-k8s.io/v1alpha4"
    echo "nodes:"
    echo "  - role: control-plane"
    for _ in $(seq 1 "$WORKERS"); do
      echo "  - role: worker"
    done
  } | kind create cluster --name "$CLUSTER_NAME" --image "$NODE_IMAGE" --wait 180s --config -
  CLUSTER_CREATED=true
fi

KUBECTL=(kubectl --context "kind-${CLUSTER_NAME}")

step "Etat du cluster"
"${KUBECTL[@]}" get nodes -o wide
SERVER_VERSION="$("${KUBECTL[@]}" version -o json | jq -r '.serverVersion.gitVersion')"
check_eq "Version du serveur Kubernetes" "v${K8S_VERSION}" "$SERVER_VERSION"

# Precharger les images evite N pulls concurrents et les limites de debit.
if [[ "$SKIP_PRELOAD" == false ]]; then
  step "Prechargement des images dans les noeuds KinD"
  PRELOAD_IMAGES=("${CHART_IMAGES[@]}")
  [[ "$MONITORING" == true ]] && PRELOAD_IMAGES+=("$PROMETHEUS_IMAGE" "$GRAFANA_IMAGE")
  for img in "${PRELOAD_IMAGES[@]}"; do
    info "docker pull $img"
    docker pull --quiet "$img" >/dev/null
    info "kind load docker-image $img"
    kind load docker-image "$img" --name "$CLUSTER_NAME" >/dev/null
  done
fi

# ---------------------------------------------------------------------------
# Deploiement
# ---------------------------------------------------------------------------
step "Installation du chart ($REPLICAS noeuds, namespace $NAMESPACE)"
VALUES_FILE="$(mktemp -t redis-ha-kind-values.XXXXXX.yaml)"
cat >"$VALUES_FILE" <<EOF
# Valeurs allegees : KinD tourne sur une seule machine.
replicaCount: $REPLICAS
podAntiAffinity: hard
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 512Mi
persistence:
  enabled: true
  size: 1Gi
metrics:
  enabled: true
  sentinel:
    enabled: true
EOF

HELM_VALUES_ARGS=(--values "$VALUES_FILE")
for f in ${EXTRA_VALUES+"${EXTRA_VALUES[@]}"}; do
  [[ -f "$f" ]] || die "Fichier de values introuvable : $f"
  info "values supplementaires : $f"
  HELM_VALUES_ARGS+=(--values "$f")
done

helm --kube-context "kind-${CLUSTER_NAME}" upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  "${HELM_VALUES_ARGS[@]}" \
  --wait --timeout "$TIMEOUT"

STS="$("${KUBECTL[@]}" -n "$NAMESPACE" get statefulset \
  -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[0].metadata.name}')"
HEADLESS="${STS}-headless"
SUFFIX=".${HEADLESS}.${NAMESPACE}.svc.cluster.local"
CHART_VALUES="$(helm --kube-context "kind-${CLUSTER_NAME}" get values "$RELEASE" -n "$NAMESPACE" -a -o json)"
GROUP="$(jq -r '.sentinel.masterGroup' <<<"$CHART_VALUES")"
METRICS_PORT="$(jq -r '.service.ports.metrics' <<<"$CHART_VALUES")"
SENTINEL_METRICS_PORT="$(jq -r '.service.ports.sentinelMetrics' <<<"$CHART_VALUES")"
info "StatefulSet : $STS"
info "Groupe Sentinel : $GROUP"

step "Attente du rollout complet"
"${KUBECTL[@]}" -n "$NAMESPACE" rollout status "statefulset/$STS" --timeout="$TIMEOUT"
"${KUBECTL[@]}" -n "$NAMESPACE" get pods -o wide

# ---------------------------------------------------------------------------
# Stack d'observabilite (optionnelle)
# ---------------------------------------------------------------------------
# Deployee avant le scenario de panne : le dashboard montre alors la bascule.
if [[ "$MONITORING" == true ]]; then
  step "Deploiement de Prometheus + Grafana (namespace monitoring)"
  [[ -d "$MONITORING_DIR" ]] || die "Manifestes de monitoring introuvables : $MONITORING_DIR"

  APP_NAME="$("${KUBECTL[@]}" -n "$NAMESPACE" get statefulset "$STS" -o json \
    | jq -r '.metadata.labels["app.kubernetes.io/name"]')"
  DASH_SUM="$(sha256sum "$MONITORING_DIR/dashboard-redis.json" | cut -c1-16)"

  "${KUBECTL[@]}" create namespace monitoring --dry-run=client -o yaml \
    | "${KUBECTL[@]}" apply -f - >/dev/null

  sed -e "s|__REDIS_NAMESPACE__|$NAMESPACE|g" \
      -e "s|__REDIS_APP_NAME__|$APP_NAME|g" \
      -e "s|__REDIS_RELEASE__|$RELEASE|g" \
      -e "s|__PROMETHEUS_IMAGE__|$PROMETHEUS_IMAGE|g" \
      "$MONITORING_DIR/prometheus.yaml" | "${KUBECTL[@]}" apply -f - >/dev/null

  # Le dashboard reste un vrai fichier JSON : versionnable et relisable.
  "${KUBECTL[@]}" -n monitoring create configmap grafana-dashboards \
    --from-file=redis.json="$MONITORING_DIR/dashboard-redis.json" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

  sed -e "s|__GRAFANA_IMAGE__|$GRAFANA_IMAGE|g" \
      -e "s|__DASHBOARD_CHECKSUM__|$DASH_SUM|g" \
      "$MONITORING_DIR/grafana.yaml" | "${KUBECTL[@]}" apply -f - >/dev/null

  "${KUBECTL[@]}" -n monitoring rollout status deployment/prometheus --timeout="$TIMEOUT"
  "${KUBECTL[@]}" -n monitoring rollout status deployment/grafana --timeout="$TIMEOUT"
fi

# ---------------------------------------------------------------------------
# Verifications d'infrastructure
# ---------------------------------------------------------------------------
step "Verification du deploiement"

READY="$("${KUBECTL[@]}" -n "$NAMESPACE" get statefulset "$STS" -o jsonpath='{.status.readyReplicas}')"
check_eq "Pods Ready" "$REPLICAS" "${READY:-0}"

if [[ -n "$("${KUBECTL[@]}" -n "$NAMESPACE" get statefulset "$STS" \
      -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}')" ]]; then
  BOUND="$("${KUBECTL[@]}" -n "$NAMESPACE" get pvc -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{.items[*].status.phase}' | tr ' ' '\n' | grep -c '^Bound$' || true)"
  check_eq "PVC Bound" "$REPLICAS" "$BOUND"
else
  info "Persistance desactivee : verification des PVC ignoree"
fi

# L'anti-affinite stricte doit avoir reparti les pods sur des noeuds distincts.
DISTINCT_NODES="$("${KUBECTL[@]}" -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)"
check_eq "Pods sur des noeuds distincts (anti-affinite)" "$REPLICAS" "$DISTINCT_NODES"

if "${KUBECTL[@]}" -n "$NAMESPACE" get pdb "$STS" >/dev/null 2>&1; then
  ALLOWED="$("${KUBECTL[@]}" -n "$NAMESPACE" get pdb "$STS" -o jsonpath='{.status.disruptionsAllowed}')"
  check_eq "PodDisruptionBudget : disruptions autorisees" "1" "${ALLOWED:-0}"
else
  info "PodDisruptionBudget desactive : verification ignoree"
fi

# ---------------------------------------------------------------------------
# Helpers Redis / Sentinel
# ---------------------------------------------------------------------------
# REDISCLI_AUTH est deja dans l'environnement des conteneurs : redis-cli
# s'authentifie tout seul, sans mot de passe en argument.
rcli() { local i="$1"; shift; "${KUBECTL[@]}" -n "$NAMESPACE" exec "${STS}-${i}" -c redis -- redis-cli "$@" 2>/dev/null | tr -d '\r'; }
scli() { local i="$1"; shift; "${KUBECTL[@]}" -n "$NAMESPACE" exec "${STS}-${i}" -c sentinel -- redis-cli -p 26379 "$@" 2>/dev/null | tr -d '\r'; }

# FQDN du master courant, vu par le sentinel du pod $1.
sentinel_master() { scli "$1" sentinel get-master-addr-by-name "$GROUP" | head -n1; }

# Index de pod extrait d'un FQDN (redis-redis-ha-1.xxx -> 1).
pod_index() { local host="${1%%.*}"; echo "${host##*-}"; }

# Nombre de replicas attaches au master, vu depuis le pod $1.
connected_slaves() {
  rcli "$1" -h "$2" info replication | awk -F: '/^connected_slaves:/{print $2+0}'
}

info_field() { rcli "$1" -h "$2" info replication | awk -F: -v k="$3" '$1==k{print $2}'; }

# ---------------------------------------------------------------------------
# Verifications du groupe Redis
# ---------------------------------------------------------------------------
step "Verification du groupe Redis / Sentinel"

MASTER_HOST="$(sentinel_master 0)"
[[ -n "$MASTER_HOST" ]] || die "Aucun sentinel ne designe de master."
MASTER_IDX="$(pod_index "$MASTER_HOST")"
info "master : ${STS}-${MASTER_IDX} ($MASTER_HOST)"

# Tous les sentinels doivent designer le meme master : sinon, split-brain.
AGREED="$(for i in $(seq 0 $((REPLICAS - 1))); do sentinel_master "$i"; done | sort -u | grep -c . || true)"
check_eq "Sentinels d'accord sur un unique master" "1" "$AGREED"

# Chaque sentinel doit avoir decouvert les autres, sinon la majorite requise
# pour autoriser une bascule ne sera jamais atteinte.
KNOWN_OK=0
for i in $(seq 0 $((REPLICAS - 1))); do
  others="$(scli "$i" sentinel master "$GROUP" | awk '/^num-other-sentinels$/{getline; print}')"
  [[ "${others:-0}" -eq $((REPLICAS - 1)) ]] && KNOWN_OK=$((KNOWN_OK + 1))
done
check_eq "Sentinels connaissant tous leurs pairs" "$REPLICAS" "$KNOWN_OK"

check_eq "Replicas attaches au master" "$((REPLICAS - 1))" "$(connected_slaves 0 "$MASTER_HOST")"

# Chaque pod doit avoir exactement un role coherent.
ROLES="$(for i in $(seq 0 $((REPLICAS - 1))); do rcli "$i" role | head -n1; done | sort | uniq -c | tr -s ' ' | sed 's/^ //' | tr '\n' ' ')"
check_eq "Roles dans le groupe" "1 master $((REPLICAS - 1)) slave " "$ROLES"

# Le mot de passe genere doit reellement etre exige. REDISCLI_AUTH doit etre
# retire de l'environnement, pas vide : redis-cli enverrait sinon un AUTH avec
# un mot de passe vide, et la reponse serait WRONGPASS au lieu de NOAUTH.
NOAUTH="$("${KUBECTL[@]}" -n "$NAMESPACE" exec "${STS}-0" -c redis -- \
  sh -c 'unset REDISCLI_AUTH; redis-cli ping' 2>&1 | tr -d '\r' | head -n1)"
if [[ "$NOAUTH" == NOAUTH* ]]; then
  pass "Authentification exigee par Redis"
else
  fail "Redis repond sans mot de passe : '$NOAUTH'"
fi

# maxmemory doit avoir ete calcule depuis resources.limits.memory (512Mi * 0.6).
MAXMEM="$(rcli 0 config get maxmemory | tail -n1)"
EXPECTED_MAXMEM=$(( 512 * 1024 * 1024 * 6 / 10 ))
check_eq "maxmemory calcule depuis la limite du conteneur" "$EXPECTED_MAXMEM" "$MAXMEM"

step "helm test (replication et accord des sentinels)"
if helm --kube-context "kind-${CLUSTER_NAME}" test "$RELEASE" -n "$NAMESPACE" --timeout 300s >/dev/null 2>&1; then
  pass "helm test"
else
  fail "helm test"
  "${KUBECTL[@]}" -n "$NAMESPACE" logs "${STS}-test-replication" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Scenario de haute disponibilite
# ---------------------------------------------------------------------------
step "Scenario HA : perte brutale du master, bascule Sentinel, integrite"

# Pod depuis lequel on pilotera le test : surtout pas la victime.
CTRL=0
[[ "$MASTER_IDX" -eq 0 ]] && CTRL=1
info "pod de pilotage : ${STS}-${CTRL}"

# 1. Ecriture avant la panne, confirmee repliquee par WAIT.
rcli "$CTRL" -h "$MASTER_HOST" set ha:before "valeur-avant-panne" >/dev/null
ACKED="$(rcli "$CTRL" -h "$MASTER_HOST" wait $((REPLICAS - 1)) 5000)"
check_eq "Ecriture avant panne repliquee (WAIT)" "$((REPLICAS - 1))" "$ACKED"

# La donnee doit etre lisible sur un replica, pas seulement sur le master.
REPLICA_IDX=$CTRL
[[ "$REPLICA_IDX" -eq "$MASTER_IDX" ]] && REPLICA_IDX=$(( (MASTER_IDX + 1) % REPLICAS ))
check_eq "Donnee lisible sur un replica" "valeur-avant-panne" "$(rcli "$REPLICA_IDX" get ha:before)"

# 2. Perte brutale du master.
#    --grace-period=1 court-circuite le hook preStop : on teste la vraie panne
#    (le noeud disparait sans ceder sa place), pas l'arret propre.
VICTIM="${STS}-${MASTER_IDX}"
step "Suppression brutale du master $VICTIM"
"${KUBECTL[@]}" -n "$NAMESPACE" delete pod "$VICTIM" --grace-period=1 --wait=false >/dev/null

# 3. Sentinel doit promouvoir un replica.
NEW_MASTER=""
DEADLINE=$((SECONDS + FAILOVER_DEADLINE))
while [[ $SECONDS -lt $DEADLINE ]]; do
  NEW_MASTER="$(sentinel_master "$CTRL" || true)"
  [[ -n "$NEW_MASTER" && "$NEW_MASTER" != "$MASTER_HOST" ]] && break
  sleep 2
done
check_ne "Nouveau master promu par Sentinel" "$MASTER_HOST" "${NEW_MASTER:-aucun}"
[[ -n "$NEW_MASTER" && "$NEW_MASTER" != "$MASTER_HOST" ]] \
  || die "Aucune bascule en ${FAILOVER_DEADLINE}s : le reste du scenario n'a plus de sens."

# 4. Le service doit rester disponible pendant la panne. La premiere ecriture
#    peut echouer : min-replicas-to-write bloque tant que le replica survivant
#    n'a pas fini de se rattacher au nouveau master.
WROTE="ko"
DEADLINE=$((SECONDS + 90))
while [[ $SECONDS -lt $DEADLINE ]]; do
  if [[ "$(rcli "$CTRL" -h "$NEW_MASTER" set ha:during "valeur-pendant-panne")" == "OK" ]]; then
    WROTE="ok"; break
  fi
  sleep 3
done
check_eq "Ecriture PENDANT la panne acceptee par le nouveau master" "ok" "$WROTE"

# 5. La donnee ecrite avant la panne doit avoir survecu a la promotion.
check_eq "Donnee d'avant panne intacte sur le nouveau master" "valeur-avant-panne" \
  "$(rcli "$CTRL" -h "$NEW_MASTER" get ha:before)"

# 6. Retour du pod supprime : il doit revenir en REPLICA du nouveau master,
#    pas en second master.
step "Attente du retour de $VICTIM"
for _ in $(seq 1 60); do
  "${KUBECTL[@]}" -n "$NAMESPACE" get pod "$VICTIM" >/dev/null 2>&1 && break
  sleep 2
done
"${KUBECTL[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$VICTIM" --timeout="$TIMEOUT" >/dev/null
"${KUBECTL[@]}" -n "$NAMESPACE" rollout status "statefulset/$STS" --timeout="$TIMEOUT" >/dev/null

ROLE_BACK=""
LINK_BACK=""
for _ in $(seq 1 30); do
  ROLE_BACK="$(rcli "$MASTER_IDX" role | head -n1)"
  LINK_BACK="$(info_field "$MASTER_IDX" 127.0.0.1 master_link_status)"
  [[ "$ROLE_BACK" == "slave" && "$LINK_BACK" == "up" ]] && break
  sleep 5
done
check_eq "Ancien master revenu en replica" "slave" "$ROLE_BACK"
check_eq "Lien de replication de l'ancien master" "up" "$LINK_BACK"

MASTER_HOST_AFTER="$(sentinel_master "$MASTER_IDX")"
check_eq "L'ancien master suit desormais le nouveau" "$NEW_MASTER" "$MASTER_HOST_AFTER"

SLAVES_AFTER=0
for _ in $(seq 1 30); do
  SLAVES_AFTER="$(connected_slaves "$CTRL" "$NEW_MASTER")"
  [[ "$SLAVES_AFTER" -eq $((REPLICAS - 1)) ]] && break
  sleep 5
done
check_eq "Replicas attaches apres reprise" "$((REPLICAS - 1))" "$SLAVES_AFTER"

AGREED_AFTER="$(for i in $(seq 0 $((REPLICAS - 1))); do sentinel_master "$i"; done | sort -u | grep -c . || true)"
check_eq "Sentinels de nouveau d'accord sur un unique master" "1" "$AGREED_AFTER"

# 7. Les deux cles doivent etre presentes sur TOUS les noeuds.
BOTH=0
for i in $(seq 0 $((REPLICAS - 1))); do
  for _ in $(seq 1 12); do
    a="$(rcli "$i" get ha:before)"; b="$(rcli "$i" get ha:during)"
    [[ "$a" == "valeur-avant-panne" && "$b" == "valeur-pendant-panne" ]] && break
    sleep 5
  done
  [[ "$a" == "valeur-avant-panne" && "$b" == "valeur-pendant-panne" ]] && BOTH=$((BOTH + 1))
done
check_eq "Noeuds portant les deux cles apres la bascule" "$REPLICAS" "$BOTH"

if [[ "$MONITORING" == false ]]; then
  rcli "$CTRL" -h "$NEW_MASTER" del ha:before ha:during >/dev/null || true
else
  info "Cles ha:* conservees : elles alimentent le dashboard Grafana"
fi

# ---------------------------------------------------------------------------
# Metriques
# ---------------------------------------------------------------------------
step "Metriques Prometheus"
# wget (busybox) et non /dev/tcp : l'image redis est basee sur Alpine, son shell
# est ash et ne connait pas cette extension de bash.
scrape() {
  "${KUBECTL[@]}" -n "$NAMESPACE" exec "${STS}-0" -c redis -- \
    wget -q -O - "http://127.0.0.1:$1/metrics" 2>/dev/null || true
}

if scrape "$METRICS_PORT" | grep -q '^redis_up 1'; then
  pass "Exporter Redis : /metrics expose des series redis_*"
else
  fail "Exporter Redis : /metrics muet ou injoignable"
fi

if scrape "$SENTINEL_METRICS_PORT" | grep -q '^redis_sentinel_masters'; then
  pass "Exporter Sentinel : /metrics expose des series redis_sentinel_*"
else
  fail "Exporter Sentinel : /metrics muet ou injoignable"
fi

# ---------------------------------------------------------------------------
# Verification de la chaine de metriques : Redis -> Prometheus -> Grafana
# ---------------------------------------------------------------------------
if [[ "$MONITORING" == true ]]; then
  step "Verification de Prometheus"
  "${KUBECTL[@]}" -n monitoring port-forward svc/prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://127.0.0.1:${PROM_PORT}/-/ready" && break
    sleep 1
  done

  # Valeur scalaire d'une requete instantanee ("" si la serie n'existe pas).
  promq() {
    curl -sSG "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
      --data-urlencode "query=$1" 2>/dev/null | jq -r '.data.result[0].value[1] // ""'
  }

  # Laisse le temps a au moins un scrape d'aboutir.
  SCRAPED=""
  for _ in $(seq 1 30); do
    SCRAPED="$(promq "sum(up{job=\"redis\"})")"
    [[ "$SCRAPED" == "$REPLICAS" ]] && break
    sleep 3
  done
  check_eq "Cibles Redis scrapees par Prometheus" "$REPLICAS" "${SCRAPED:-0}"

  SSCRAPED=""
  for _ in $(seq 1 20); do
    SSCRAPED="$(promq "sum(up{job=\"redis-sentinel\"})")"
    [[ "$SSCRAPED" == "$REPLICAS" ]] && break
    sleep 3
  done
  check_eq "Cibles Sentinel scrapees par Prometheus" "$REPLICAS" "${SSCRAPED:-0}"

  # Le pod supprime vient de revenir : Prometheus a encore en memoire la serie
  # role="master" d'avant la bascule, tant qu'un nouveau scrape ne l'a pas
  # marquee obsolete. On laisse la vue converger.
  MASTERS=""
  for _ in $(seq 1 20); do
    MASTERS="$(promq 'count(redis_instance_info{redis_mode="standalone",role="master"})')"
    [[ "$MASTERS" == "1" ]] && break
    sleep 3
  done
  check_eq "Un seul master vu par Prometheus apres reprise" "1" "${MASTERS:-0}"

  # Chaque expression du dashboard doit renvoyer des donnees : c'est ce qui
  # attrape un nom de metrique errone.
  step "Verification des requetes du dashboard"
  EMPTY_EXPRS=()
  TOTAL_EXPRS=0
  while IFS= read -r expr; do
    [[ -z "$expr" ]] && continue
    TOTAL_EXPRS=$((TOTAL_EXPRS + 1))
    # Les variables de template ne sont pas connues de Prometheus.
    resolved="${expr//\$node/.*}"
    if [[ -z "$(promq "$resolved")" ]]; then
      EMPTY_EXPRS+=("$expr")
    fi
  done < <(jq -r '.panels[].targets[].expr' "$MONITORING_DIR/dashboard-redis.json")

  if [[ ${#EMPTY_EXPRS[@]} -eq 0 ]]; then
    pass "Les $TOTAL_EXPRS requetes du dashboard renvoient des donnees"
  else
    fail "${#EMPTY_EXPRS[@]}/$TOTAL_EXPRS requetes du dashboard sans donnees"
    for e in "${EMPTY_EXPRS[@]}"; do info "  sans donnees : $e"; done
  fi

  step "Verification de Grafana"
  "${KUBECTL[@]}" -n monitoring port-forward svc/grafana "${GRAFANA_PORT}:3000" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  GRAFANA="http://admin:admin@127.0.0.1:${GRAFANA_PORT}"
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "${GRAFANA}/api/health" && break
    sleep 1
  done

  check_eq "Grafana operationnel" "ok" \
    "$(curl -sf "${GRAFANA}/api/health" | jq -r '.database // "ko"')"
  check_eq "Datasource Prometheus provisionnee" "prometheus" \
    "$(curl -sf "${GRAFANA}/api/datasources" | jq -r '.[0].type // "absente"')"
  check_eq "Dashboard Redis provisionne" "Redis HA — groupe Sentinel" \
    "$(curl -sf "${GRAFANA}/api/dashboards/uid/redis-ha" | jq -r '.dashboard.title // "absent"')"

  # La datasource repond-elle a travers le proxy Grafana ?
  PROXY_UP="$(curl -sfG "${GRAFANA}/api/datasources/proxy/uid/prometheus-redis/api/v1/query" \
    --data-urlencode 'query=sum(up{job="redis"})' | jq -r '.data.result[0].value[1] // ""')"
  check_eq "Grafana interroge Prometheus (proxy datasource)" "$REPLICAS" "${PROXY_UP:-0}"
fi

# ---------------------------------------------------------------------------
# Resultat
# ---------------------------------------------------------------------------
step "Resultat"
"${KUBECTL[@]}" -n "$NAMESPACE" get pods -o wide
printf '\n'
if [[ "$FAILURES" -eq 0 ]]; then
  printf '%s%s %d/%d verifications reussies. Groupe Redis HA valide sur Kubernetes %s.%s\n' \
    "$C_GREEN" "$C_BOLD" "$CHECKS" "$CHECKS" "$K8S_VERSION" "$C_RESET"
  exit 0
else
  printf '%s%s %d/%d verifications en echec.%s\n' \
    "$C_RED" "$C_BOLD" "$FAILURES" "$CHECKS" "$C_RESET"
  exit 1
fi
