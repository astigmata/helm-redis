# Makefile du chart redis-ha.
# `make` sans argument affiche l'aide.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CHART        ?= redis-ha
CHART_DIR    ?= $(CURDIR)/$(CHART)
SCRIPT       ?= $(CURDIR)/scripts/test-kind.sh
RELEASE      ?= redis
NAMESPACE    ?= datastore
K8S_VERSION  ?= 1.30.8
# Version de Kubernetes du scenario test-envoy. Elle suit K8S_VERSION : la
# branche 1.6.x d'Envoy Gateway couvre 1.30 a 1.33. Une branche plus recente
# (EG_VERSION=v1.8.3) impose Kubernetes >= 1.32 — surcharger les deux ensemble.
ENVOY_K8S_VERSION ?= $(K8S_VERSION)
REPLICAS     ?= 3
CLUSTER      ?= redis-ha-e2e
GROUP        ?= mymaster
OUT          ?= $(CURDIR)/.out
KUBECONFORM_IMAGE ?= ghcr.io/yannh/kubeconform:latest

# Ports locaux des port-forward. A surcharger si un service de la machine les
# occupe deja — Cockpit, par exemple, ecoute en permanence sur 9090.
GRAFANA_LOCAL_PORT ?= 3000
PROM_LOCAL_PORT    ?= 9090

# Versions parcourues par `make test-matrix`
K8S_MATRIX   ?= 1.29.12 1.30.8 1.31.4

# Seuils inotify du script (voir README, section Prerequis). max_user_instances
# est bloquant, max_user_watches n'est qu'un avertissement. Surchargeables.
MIN_INOTIFY_INSTANCES ?=
MIN_INOTIFY_WATCHES   ?=
export MIN_INOTIFY_INSTANCES MIN_INOTIFY_WATCHES

VALUES_DEFAULT   := $(CHART_DIR)/values.yaml
VALUES_PROD      := $(CHART_DIR)/ci/production-values.yaml
VALUES_EPHEMERAL := $(CHART_DIR)/ci/ephemeral-values.yaml
VALUES_ENVOY     := $(CHART_DIR)/ci/envoy-gateway-values.yaml
VALUES_SESSIONS  := $(CHART_DIR)/ci/sessions-values.yaml

# Overlay cache + NetworkPolicy + Secret externe, genere a la volee
define CACHE_OVERLAY
maxMemory:
  policy: allkeys-lru
replication:
  minReplicasToWrite: 0
persistenceConfig:
  appendOnly: false
  save: []
networkPolicy:
  enabled: true
  allowExternal: false
auth:
  existingSecret: redis-external-auth
endef
export CACHE_OVERLAY

# Le profil sessions active ServiceMonitor et PrometheusRule : leurs CRD
# viennent de prometheus-operator, absent du cluster de test. Ressources
# reduites, KinD tourne sur une seule machine.
define SESSIONS_OVERLAY
metrics:
  serviceMonitor:
    enabled: false
  prometheusRule:
    enabled: false
persistence:
  size: 1Gi
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 512Mi
envoyGateway:
  enabled: true
endef
export SESSIONS_OVERLAY

.PHONY: help
help: ## Affiche cette aide
	@echo "redis-ha — cibles disponibles"
	@echo
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables : RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) K8S_VERSION=$(K8S_VERSION) REPLICAS=$(REPLICAS)"
	@echo "Exemple   : make test-kind K8S_VERSION=1.31.4 REPLICAS=5"

# ---------------------------------------------------------------------------
# Verifications hors cluster (rapides, sans Docker)
# ---------------------------------------------------------------------------

.PHONY: lint
lint: ## Lint strict du chart (defaut + profils production et ephemere)
	helm lint $(CHART_DIR) --strict
	helm lint $(CHART_DIR) --strict --values $(VALUES_PROD)
	helm lint $(CHART_DIR) --strict --values $(VALUES_EPHEMERAL)
	helm lint $(CHART_DIR) --strict --values $(VALUES_ENVOY)
	helm lint $(CHART_DIR) --strict --values $(VALUES_SESSIONS)

.PHONY: render
render: ## Rend les manifestes de tous les profils dans .out/
	@mkdir -p $(OUT)
	helm template $(RELEASE) $(CHART_DIR) > $(OUT)/default.yaml
	helm template $(RELEASE) $(CHART_DIR) --values $(VALUES_PROD) > $(OUT)/production.yaml
	helm template $(RELEASE) $(CHART_DIR) --values $(VALUES_EPHEMERAL) > $(OUT)/ephemeral.yaml
	@echo "$$CACHE_OVERLAY" > $(OUT)/cache-overlay.yaml
	helm template $(RELEASE) $(CHART_DIR) \
		--values $(VALUES_PROD) --values $(OUT)/cache-overlay.yaml > $(OUT)/cache.yaml
	helm template $(RELEASE) $(CHART_DIR) --set replicaCount=1 > $(OUT)/single.yaml
	helm template $(RELEASE) $(CHART_DIR) --values $(VALUES_ENVOY) > $(OUT)/envoy-gateway.yaml
	helm template $(RELEASE) $(CHART_DIR) --values $(VALUES_SESSIONS) > $(OUT)/sessions.yaml
	@echo "Manifestes rendus dans $(OUT)/"

.PHONY: validate
validate: render ## Valide les manifestes contre les schemas Kubernetes $(K8S_VERSION)
	@# kubeconform valide hors ligne contre les schemas officiels de la version
	@# ciblee. Les CRD externes (ServiceMonitor, PrometheusRule) sont ignorees.
	@if command -v docker > /dev/null 2>&1; then \
		for f in $(OUT)/default.yaml $(OUT)/production.yaml $(OUT)/ephemeral.yaml $(OUT)/cache.yaml $(OUT)/single.yaml $(OUT)/envoy-gateway.yaml $(OUT)/sessions.yaml; do \
			printf '%-16s ' "$$(basename $$f)"; \
			docker run --rm -i $(KUBECONFORM_IMAGE) \
				-kubernetes-version $(K8S_VERSION) -strict -summary \
				-ignore-missing-schemas < $$f || exit 1; \
		done; \
	elif kubectl cluster-info > /dev/null 2>&1; then \
		echo "docker absent : repli sur kubectl --dry-run=client"; \
		for f in $(OUT)/default.yaml $(OUT)/ephemeral.yaml $(OUT)/single.yaml; do \
			echo "--- $$f"; kubectl apply --dry-run=client -f $$f > /dev/null || exit 1; \
		done; \
	else \
		echo "Ni docker ni cluster joignable : validation impossible" >&2; exit 1; \
	fi
	@echo "Tous les manifestes sont valides."

.PHONY: check
check: lint validate ## lint + validate (verification complete hors cluster)

# ---------------------------------------------------------------------------
# Scenarios de test de bout en bout sur KinD
# ---------------------------------------------------------------------------

.PHONY: test-kind
test-kind: ## Scenario nominal : 3 noeuds, Kubernetes $(K8S_VERSION), avec perte du master
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER)

.PHONY: test-kind-keep
test-kind-keep: ## Idem mais conserve le cluster pour investigation
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --keep

.PHONY: test-ha5
test-ha5: ## Scenario 5 noeuds sur 5 workers (tolere 2 pannes)
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas 5 --workers 5 \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER)

.PHONY: test-ephemeral
test-ephemeral: ## Scenario sans persistance (emptyDir, PDB desactive)
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) \
		--values $(VALUES_EPHEMERAL)

.PHONY: test-sessions
test-sessions: ## Scenario magasin de sessions : 5 noeuds, disponibilite avant durabilite
	@mkdir -p $(OUT)
	@echo "$$SESSIONS_OVERLAY" > $(OUT)/sessions-overlay.yaml
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas 5 --workers 5 \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --envoy-gateway \
		--values $(VALUES_SESSIONS) --values $(OUT)/sessions-overlay.yaml

.PHONY: test-envoy
test-envoy: ## Scenario nominal + Envoy Gateway : verifie que le gateway ne sert que le master
	$(SCRIPT) --k8s-version $(ENVOY_K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --envoy-gateway

.PHONY: test-monitoring
test-monitoring: ## Scenario nominal + Prometheus/Grafana : verifie la chaine de metriques
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --monitoring

.PHONY: test-matrix
test-matrix: ## Rejoue le scenario nominal sur $(K8S_MATRIX)
	@set -e; for v in $(K8S_MATRIX); do \
		echo; echo "############ Kubernetes $$v ############"; \
		$(SCRIPT) --k8s-version $$v --replicas $(REPLICAS) \
			--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER)-$${v//./-}; \
	done
	@echo "Matrice $(K8S_MATRIX) : OK"

.PHONY: test-all
test-all: check test-kind ## Verification hors cluster puis scenario nominal

# ---------------------------------------------------------------------------
# Cluster KinD manuel (pour iterer sans relancer tout le scenario)
# ---------------------------------------------------------------------------

.PHONY: kind-up
kind-up: ## Cree un cluster KinD 1 control-plane + 3 workers et y installe le chart
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --keep

.PHONY: monitoring-up
monitoring-up: ## Cluster KinD + chart + Prometheus/Grafana, conserves (voir make grafana)
	$(SCRIPT) --k8s-version $(K8S_VERSION) --replicas $(REPLICAS) \
		--namespace $(NAMESPACE) --release $(RELEASE) --cluster $(CLUSTER) --monitoring --keep

# Les cibles ci-dessous supposent un cluster KinD vivant. Les scenarios test-*
# le detruisent en sortant : seules kind-up / monitoring-up le conservent.
.PHONY: require-cluster
require-cluster:
	@kind get clusters 2>/dev/null | grep -qx "$(CLUSTER)" || { \
		echo "Le cluster KinD '$(CLUSTER)' n'existe pas."; \
		echo; \
		echo "Les cibles test-* detruisent le cluster a la fin du scenario."; \
		echo "Pour garder un cluster utilisable :"; \
		echo "  make monitoring-up   # scenario complet + Prometheus/Grafana, conserves"; \
		echo "  make kind-up         # cluster + chart seuls, conserves"; \
		exit 1; }

# Verifie qu'un port local est libre avant de lancer le port-forward : sinon
# kubectl echoue sur un "address already in use" qui ne dit pas qui l'occupe.
# $(1) = port, $(2) = variable a surcharger
define check_port
	@ss -ltn "sport = :$(1)" 2>/dev/null | grep -q ":$(1)" && { \
		echo "Le port local $(1) est deja occupe sur cette machine :"; \
		ss -ltnp "sport = :$(1)" 2>/dev/null | tail -n +2 | sed 's/^/  /'; \
		echo; \
		echo "Choisir un autre port local :"; \
		echo "  make $(2)=<port> $@"; \
		exit 1; } || true
endef

.PHONY: grafana
grafana: require-cluster ## Port-forward de Grafana sur http://127.0.0.1:$(GRAFANA_LOCAL_PORT)
	$(call check_port,$(GRAFANA_LOCAL_PORT),GRAFANA_LOCAL_PORT)
	@echo "Grafana : http://127.0.0.1:$(GRAFANA_LOCAL_PORT) — acces anonyme, dashboard \"Redis HA\""
	kubectl --context kind-$(CLUSTER) -n monitoring port-forward svc/grafana $(GRAFANA_LOCAL_PORT):3000

.PHONY: prometheus
prometheus: require-cluster ## Port-forward de Prometheus sur http://127.0.0.1:$(PROM_LOCAL_PORT)
	$(call check_port,$(PROM_LOCAL_PORT),PROM_LOCAL_PORT)
	@echo "Prometheus : http://127.0.0.1:$(PROM_LOCAL_PORT)"
	kubectl --context kind-$(CLUSTER) -n monitoring port-forward svc/prometheus $(PROM_LOCAL_PORT):9090

.PHONY: kind-down
kind-down: ## Supprime le cluster KinD de test
	-kind delete cluster --name $(CLUSTER)

.PHONY: kind-status
kind-status: require-cluster ## Etat des pods et du groupe Redis
	kubectl --context kind-$(CLUSTER) -n $(NAMESPACE) get pods,pvc,svc -o wide
	kubectl --context kind-$(CLUSTER) -n $(NAMESPACE) exec $(RELEASE)-$(CHART)-0 -c sentinel -- \
		redis-cli -p 26379 sentinel master $(GROUP)

# ---------------------------------------------------------------------------
# Deploiement sur le cluster courant (kubectl config current-context)
# ---------------------------------------------------------------------------

.PHONY: install
install: ## Installe/met a jour le chart sur le contexte kubectl courant
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
		--namespace $(NAMESPACE) --create-namespace --wait

.PHONY: install-prod
install-prod: ## Idem avec le profil production
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
		--namespace $(NAMESPACE) --create-namespace --values $(VALUES_PROD) --wait

.PHONY: test
test: ## Lance `helm test` sur la release deployee
	helm test $(RELEASE) --namespace $(NAMESPACE) --logs

.PHONY: status
status: ## Etat de la release et du groupe Redis
	helm status $(RELEASE) --namespace $(NAMESPACE)
	kubectl -n $(NAMESPACE) exec $(RELEASE)-$(CHART)-0 -c sentinel -- \
		redis-cli -p 26379 sentinel master $(GROUP)

.PHONY: master
master: ## Affiche le master courant designe par Sentinel
	@kubectl -n $(NAMESPACE) exec $(RELEASE)-$(CHART)-0 -c sentinel -- \
		redis-cli -p 26379 sentinel get-master-addr-by-name $(GROUP)

.PHONY: failover
failover: ## Force une bascule Sentinel (test de reprise, hors production)
	kubectl -n $(NAMESPACE) exec $(RELEASE)-$(CHART)-0 -c sentinel -- \
		redis-cli -p 26379 sentinel failover $(GROUP)

.PHONY: password
password: ## Affiche le mot de passe genere
	@kubectl -n $(NAMESPACE) get secret $(RELEASE)-$(CHART) \
		-o jsonpath='{.data.redis-password}' | base64 -d; echo

.PHONY: cli
cli: ## Ouvre un redis-cli sur le master courant
	@kubectl -n $(NAMESPACE) exec -it $(RELEASE)-$(CHART)-0 -c redis -- sh -c \
		'redis-cli -h $$(redis-cli -p 26379 sentinel get-master-addr-by-name $(GROUP) | head -1)'

.PHONY: uninstall
uninstall: ## Desinstalle la release (les PVC et le Secret sont conserves)
	-helm uninstall $(RELEASE) --namespace $(NAMESPACE)

# ---------------------------------------------------------------------------
# Divers
# ---------------------------------------------------------------------------

.PHONY: package
package: lint ## Empaquette le chart en .tgz
	@mkdir -p $(OUT)
	helm package $(CHART_DIR) --destination $(OUT)

.PHONY: clean
clean: ## Supprime les artefacts locaux (.out/)
	rm -rf $(OUT)
