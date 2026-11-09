# Prime Detect Helm Chart

Helm chart for the **Prime Detect application layer** - the SOC Prime
real-time Sigma detection platform's apps. It deploys the Admin Panel backend,
the Admin Panel UI, and the supporting resources for the Flink Sigma detector.

This is the **open-source edition**. All images are public on Docker Hub under
[`socprime/detectflow-oss`](https://hub.docker.com/r/socprime/detectflow-oss) -
no registry login and no pull secret are needed. Everything else behaves
exactly like the standard chart.

> Chart version: `0.18.0+oss` · App version: `v2.3.2`

---

## What this chart deploys

| Component | Kind(s) | Notes |
| --- | --- | --- |
| **Backend** (`admin-panel-be`) | Deployment, Service, PVC, (ServiceAccount), (ConfigMap), (Secret), (PDB) | FastAPI API. Spawns Flink jobs via the operator and the df-agent / df-correlation job Deployments. |
| **UI** (`admin-panel-ui`) | Deployment, Service, (ConfigMap), (PDB) | React/Vite admin panel. Proxies `/api/v1` to the backend. |
| **Flink support** | (ServiceAccount + RBAC), (ConfigMap `flink-config`), (Secret `flink-sigma-config`), 3× PVC | Consumed by operator-spawned `FlinkDeployment`s. **No static Flink workload.** |
| **Ingress** | Ingress | Optional. Fronts the UI, optional separate API host, optional cert-manager TLS. |

Items in `()` are optional / toggleable (rendered by default, can be disabled
or pointed at pre-created resources).

### NOT deployed by this chart (external dependencies)

You install and manage these yourself; the chart only connects to them:

- **Apache Kafka** - bootstrap address lives in the backend and `flink-sigma-config` Secrets
- **PostgreSQL** - connection string lives in the backend Secret
- **Flink Kubernetes Operator** - creates the `FlinkDeployment`s the backend requests
- **cert-manager** - required by the Flink Kubernetes Operator (webhook certs); also used for app TLS when an ingress has `tls.enabled`
- **Ingress controller** - only if `ingress.ui.enabled` / `ingress.backend.enabled`

---

## Prerequisites

### Infrastructure dependencies

| Dependency | Version | Purpose | Required by |
| --- | --- | --- | --- |
| Kubernetes | 1.28+ | Container orchestration | All components |
| Helm | 3.x / 4.x | Chart installation (`apiVersion: v2` charts work unchanged on Helm 4) | - |
| PostgreSQL | 14+ | Backend database (rules, pipelines, users) | Backend |
| Apache Kafka | 3.8+ | Event streaming & rule distribution | Backend, Flink Sigma Detector |
| Apache Flink | 2.2 | Stream processing engine (runs inside the `flink-sigma-detector` image) | Flink Sigma Detector |
| Flink Kubernetes Operator | 1.15.0 | Manages Flink deployments as CRDs | Flink Sigma Detector lifecycle |
| cert-manager | 1.21.0 | TLS certificate management (Flink operator webhooks; app TLS in cert-manager mode) | Flink Operator, optional TLS |

The Kubernetes minimum is enforced by `kubeVersion` in `Chart.yaml`.

### Cluster setup

- The external dependencies above, running in / reachable from the target namespace
- No pull secret: the images are public. One is needed only if you mirror them into a private registry - then set `imagePullSecrets`.
- A node labeled for app scheduling (default `app=detectflow-prod`, `spec-node-ns-pod-disk=pvc-security`) - see `nodeSelector`. Keep the pin where the metrics PVC is zonal (EBS): an unpinned pod can land in another AZ and fail to attach its volume. If you do not pin app pods, set `backend.nodeSelector` / `ui.nodeSelector` to `null` in your overlay - **not** `{}`, which Helm deep-merges and keeps the default.

---

## Quick start

> **Before installing:** all components from [Prerequisites](#prerequisites)
> must already be installed and running - PostgreSQL, Apache Kafka, the Flink
> Kubernetes Operator and cert-manager. The chart only connects to them; without
> any of them the application will not work.

```bash
# 1. namespace
kubectl create namespace flink

# 2. label the node the app pods should run on
kubectl label node <NODE> app=detectflow-prod --overwrite
kubectl label node <NODE> spec-node-ns-pod-disk=pvc-security --overwrite

# 3. install. The default values reference pre-created Secrets
#    (backend.existingSecret=admin-panel-be-secret,
#    flink.existingSecret=flink-sigma-config) - create those first, or the
#    pods CrashLoop on a missing envFrom source. To have the chart render
#    them instead, pass an overlay that clears existingSecret and fills
#    backend.secret / flink.secret (DATABASE_URL, KAFKA_*, JWT_* - see the
#    "Backend config/secret key reference" section below).
helm install detectflow charts/detectflow -n flink

# 4. typical install: reference pre-created config/secrets via an overlay -
#    copy charts/detectflow/values.yaml.example to your own file first and
#    fill in your host/annotations/ARNs. Any charts/detectflow/*-values.yaml
#    name is gitignored (e.g. custom-values.yaml, aws-values.yaml,
#    baremetal-values.yaml) - pick whatever fits your environment.
helm install detectflow charts/detectflow -n flink -f charts/detectflow/custom-values.yaml
```

Uninstall / upgrade:

```bash
helm upgrade detectflow charts/detectflow -n flink -f charts/detectflow/custom-values.yaml
helm uninstall detectflow -n flink     # leaves PVCs and the Flink workloads - see "What uninstall leaves behind"
```

---

## Two operating modes

The chart can either **render** ConfigMaps/Secrets/RBAC itself, or **reference**
pre-created ones. Toggle per resource:

| Resource | Render (default) | Reference existing |
| --- | --- | --- |
| backend ConfigMap | `backend.existingConfigMap: ""` | `backend.existingConfigMap: <name>` |
| backend Secret | `backend.existingSecret: ""` + `backend.secret.*` | `backend.existingSecret: <name>` |
| UI ConfigMap | `ui.existingConfigMap: ""` | `ui.existingConfigMap: <name>` |
| UI Secret (optional) | `ui.existingSecret: ""` + `ui.secret.*` | `ui.existingSecret: <name>` |
| flink-config | `flink.existingConfigMap: ""` + `flink.config.*` (renders as `flink-config`) | `flink.existingConfigMap: <name>` (any name - passed to the backend as `FLINK_CONFIG_CONFIGMAP_NAME`) |
| flink-sigma-config | `flink.existingSecret: ""` (renders as `flink-sigma-config`) | `flink.existingSecret: <name>` (any name - passed to the backend as `FLINK_SIGMA_CONFIG_SECRET_NAME`) |
| detectflow-agent-config | `jobs.agent.existingConfigMap: ""` + `jobs.agent.config.*` (renders as `detectflow-agent-config`) | `jobs.agent.existingConfigMap: <name>` (any name - passed to the backend as `DETECTFLOW_AGENT_CONFIGMAP_NAME`) |
| detectflow-agent-secrets (optional) | `jobs.agent.existingSecret: ""` + `jobs.agent.secret.*` | `jobs.agent.existingSecret: <name>` (any name - passed to the backend as `DETECTFLOW_AGENT_SECRET_NAME`) |
| backend metrics PVC | `backend.persistence.existingClaim: ""` | `backend.persistence.existingClaim: <name>` |
| Flink checkpoints/HA/savepoints PVCs | `flink.pvcs.existing*Claim: ""` (renders `flink-*-pvc`) | `flink.pvcs.existingCheckpointsClaim` / `existingHaClaim` / `existingSavepointsClaim: <name>` (any name - passed to the backend as `FLINK_CHECKPOINTS_PVC` / `FLINK_HA_PVC` / `FLINK_SAVEPOINTS_PVC`) |
| Flink RBAC + SA | `flink.rbac.create: true` | `false` (apply externally) |
| backend SA | `backend.serviceAccount.create: true` | `false`, set `name` to an existing SA |

The "Render (default)" column shows how to enable render mode per resource -
it is not always the shipped default. Two secrets ship in **reference** mode:
`backend.existingSecret` defaults to `admin-panel-be-secret` and
`flink.existingSecret` to `flink-sigma-config`, so a bare `helm install` with
no overlay expects those two Secrets to already exist. Clear the corresponding
`existingSecret` and fill `backend.secret`/`flink.secret` to have the chart
render them instead.

`values.yaml.example` is a starting point for **reference** mode - copy it to
any `charts/detectflow/*-values.yaml` name (gitignored) that fits your
environment (`custom-values.yaml`, `aws-values.yaml`, `baremetal-values.yaml`,
...). You pre-create the referenced ConfigMaps/Secrets yourself before
installing, with the exact names and keys listed in the Parameters tables
below (`backend.secret`/`.config`, `ui.config`, `flink.secret`/`.config`,
`jobs.agent.config`/`.secret`). Flink RBAC is chart-managed - the chart's
rbac.yaml mirrors the canonical `flink-rbac.yaml`.

> **⚠️ Reference mode does not auto-restart pods on config changes.** In
> render mode, Deployments carry a `checksum/config`/`checksum/secret`
> annotation so a config change automatically rolls the pods. In reference
> mode the chart never sees the ConfigMap/Secret content, so it cannot compute
> that checksum. After you update a pre-created ConfigMap or Secret,
> **manually restart the affected Deployment** or the pod keeps running with
> the old values:
>
> ```bash
> kubectl rollout restart deployment/admin-panel-be -n flink
> kubectl rollout restart deployment/admin-panel-ui -n flink
> ```

---

## Parameters

### Global

| Key | Default | Description |
| --- | --- | --- |
| `nameOverride` | `""` | Override the chart name used in labels/resource names. |
| `fullnameOverride` | `""` | Override the full resource-name prefix (used by the Ingress name). |
| `imagePullSecrets` | `[]` | Pre-created docker-registry secrets, applied to the app pods and to the `flink` ServiceAccount the operator-spawned job pods run under. Empty because the OSS images are public; set it only if you mirror them into a private registry. |

### Backend (`backend.*`)

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `socprime/detectflow-oss` | Backend image repository. (public) |
| `image.tag` | `admin-panel-be-oss.v2.3.2` | Backend image tag. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `serviceName` | `admin-panel-be` | Fixed Deployment/Service name (other components resolve it by DNS - keep stable). |
| `replicas` | `1` | Number of backend pods. |
| `existingSecret` | `admin-panel-be-secret` | Reference a pre-created Secret (any name - only this chart's Deployment reads it, via `envFrom`). Empty → render `admin-panel-be-secret` from `secret`. |
| `secret` | `{}` | Free-form map `KEY: value` for the rendered Secret (used when `existingSecret` is empty). See "Backend `config`/`secret` key reference" below for the full list. |
| `existingConfigMap` | `""` | Reference a pre-created ConfigMap. Empty → render `admin-panel-be-config` from `config` (+ chart-computed keys). |
| `config` | `{}` | Free-form map `KEY: value` of backend env, merged with the chart-computed keys (`KUBERNETES_NAMESPACE`, `FLINK_IMAGE`, `IMAGE_PULL_POLICY`, `FLINK_CONFIG_CONFIGMAP_NAME`, `FLINK_SIGMA_CONFIG_SECRET_NAME`, `FLINK_*_PVC`, `AGENT_JOB_IMAGE`, `CORRELATION_JOB_IMAGE`, `CORRELATION_JOB_DEPLOYMENT_NAME`, `CORRELATION_JOB_SERVICE_ACCOUNT`). See "Backend `config`/`secret` key reference" below for the full list. |
| `resources` | requests 500m/512Mi, limits 2/1Gi | Container resources. |
| `persistence.enabled` | `true` | Create the metrics PVC (mounted at `/mnt/metrics`); `false` → emptyDir. |
| `persistence.existingClaim` | `""` | Reference a pre-created PVC by name instead of rendering one (e.g. a hand-made claim on shared storage). The `size`/`storageClass`/`accessModes`/`keep` keys below are then ignored - the existing PVC's own spec applies. Ignored entirely when `enabled: false` (emptyDir wins). |
| `persistence.size` | `1Gi` | Metrics PVC size. |
| `persistence.storageClass` | `""` | StorageClass (empty → cluster default). |
| `persistence.accessModes` | `[ReadWriteOnce]` | PVC access modes. |
| `persistence.keep` | `true` | Add `helm.sh/resource-policy=keep` so the PVC survives uninstall/upgrade. |
| `service.type` | `ClusterIP` | Backend Service type. |
| `service.port` | `8000` | Backend Service port. |
| `service.annotations` | `{}` | Extra Service annotations. |
| `serviceAccount.create` | `true` | Create the backend ServiceAccount. |
| `serviceAccount.name` | `""` | SA name (empty → `serviceName`). Set to `default` when RBAC is external and binds the default SA. |
| `serviceAccount.annotations` | `{}` | SA annotations. |
| `podAnnotations` / `podLabels` | `{}` | Extra pod metadata. |
| `nodeSelector` | `{app: detectflow-prod}` | Node selector for app pods. Keep the pin where the metrics PVC is zonal (EBS) - an unpinned pod can land in another AZ and fail to attach. On a cluster whose nodes carry no such label, set to `null` (**not** `{}`, which deep-merges and keeps the default). |
| `tolerations` | `[]` | Node taint tolerations. |
| `affinity` | `{}` | Affinity rules. |
| `podSecurityContext` | runAsNonRoot, uid/fsGroup 1000, seccomp RuntimeDefault | Pod-level security context - the backend image (v2.2.0+) runs as uid 1000. For older root-only images set it to `null`, **not** `{}` - Helm deep-merges maps, so `{}` keeps these defaults instead of clearing them. |
| `securityContext` | no privilege escalation, drop ALL capabilities | Container-level security context. `readOnlyRootFilesystem` is not set (app write paths unverified). |
| `automountServiceAccountToken` | `true` | Backend needs the K8s API (FlinkDeployments / job Deployments). |
| `terminationGracePeriodSeconds` | `30` | Graceful shutdown window. |
| `extraEnvs` | `[]` | Extra env vars (list of `{name,value}`), appended to the container. |
| `envFrom` | `[]` | Extra `envFrom` sources, appended after the chart's ConfigMap + Secret. |
| `extraVolumes` / `extraVolumeMounts` | `[]` | Extra volumes / mounts. |
| `startupProbe` | httpGet `/health:http`, 300s budget | Grace period for a slow first boot; liveness/readiness start counting only after this succeeds (set to `null` to disable - `{}` merges with and keeps the default). |
| `livenessProbe` | httpGet `/health:http` | Liveness probe (set to `null` to disable - `{}` merges with and keeps the default). |
| `readinessProbe` | httpGet `/health:http` | Readiness probe (set to `null` to disable - `{}` merges with and keeps the default). |
| `updateStrategy` | `{type: Recreate}` | Recreate because the metrics PVC is RWO (RollingUpdate can deadlock on Multi-Attach). `RollingUpdate` is safe once the volume is `ReadWriteMany` - e.g. an `existingClaim` on shared storage. |
| `podDisruptionBudget.enabled` | `false` | Create a PDB for the backend. |
| `podDisruptionBudget.minAvailable` | `1` | PDB minAvailable (or set `maxUnavailable`). |

#### Backend `config`/`secret` key reference

`backend.config`/`backend.secret` are free-form maps - nothing here is schema-validated
against a fixed key list, so this table is documentation, not enforcement. Source:
the `admin-panel-backend` app's own `.env.example` and README.

**`secret`** (sensitive - only via `secret`/`existingSecret`, never `config`):

| Key | Required | Notes |
| --- | --- | --- |
| `DATABASE_URL` | yes | PostgreSQL connection string. |
| `JWT_SECRET_KEY` / `JWT_REFRESH_SECRET_KEY` | yes | Change from the app's dev defaults in production. |
| `KAFKA_BOOTSTRAP_SERVERS` | yes | Kafka broker addresses. |
| `KAFKA_AUTH_METHOD` | optional, default `PLAINTEXT` | `PLAINTEXT`, `SASL`, or `SSL`. |
| `KAFKA_API_KEY` / `KAFKA_API_SECRET` | required if `KAFKA_AUTH_METHOD=SASL` | SASL credentials. |

**`config`** (non-sensitive), grouped:

| Group | Keys |
| --- | --- |
| Logging | `LOG_LEVEL` (default `INFO`) |
| API | `DISABLE_API_DOCS` (default `false` - disables Swagger/ReDoc/OpenAPI JSON), `CORS_ALLOW_ORIGINS` (comma-separated origins; empty = same-origin only, the correct default whenever the frontend reaches the API through the same host) |
| Kafka topics/consumer groups | `KAFKA_SIGMA_RULES_TOPIC`, `KAFKA_ACTIVE_THREATS_TOPIC`, `KAFKA_HOS_RULES_TOPIC`, `KAFKA_TAGGED_EVENTS_TOPIC` (+ `KAFKA_TAGGED_EVENTS_PARTITIONS`), `KAFKA_METRICS_TOPIC` / `KAFKA_METRICS_CONSUMER_GROUP`, `KAFKA_ACTIVITY_TOPIC` / `KAFKA_ACTIVITY_CONSUMER_GROUP`, `KAFKA_CHAINS_CONFIG_TOPIC`, `KAFKA_CHAINS_RAW_TOPIC`, `KAFKA_CHAINS_ANALYSED_TOPIC` / `_CONSUMER_GROUP` / `_ENABLED` / `_AUTO_OFFSET_RESET`, `KAFKA_DEFAULT_PARTITIONS`, `KAFKA_DEFAULT_REPLICATION_FACTOR`, `KAFKA_SSL_CHECK_HOSTNAME` |
| Kafka SSL auth (`KAFKA_AUTH_METHOD=SSL`) | `KAFKA_SSL_CA_LOCATION`, `KAFKA_SSL_CERTIFICATE_LOCATION`, `KAFKA_SSL_KEY_LOCATION` - paths the backend reads the CA/cert/key from; mount the actual files at those paths via `backend.extraVolumes`/`extraVolumeMounts`. |
| Flink resource defaults | `FLINK_TASKMANAGER_CPU` / `_MEMORY_GB`, `FLINK_JOBMANAGER_CPU` / `_MEMORY_GB`, `FLINK_METRICS_POLL_INTERVAL`, `AUTOSCALER_QUOTA_CPU` / `_MEMORY_GB` (unset → auto-calculated from TaskManager resources), `FLINK_NODE_SELECTOR_KEY` / `_VALUE`, `DETECTFLOW_CHECKPOINT_INTERVAL_SEC` |
| Flink TaskManager memory split | `FLINK_TASKMANAGER_PROCESS_MEMORY_BASE_MB`, `_GROWTH_FRACTION`, `_MIN_MB`, `_NATIVE_HEADROOM_MIN_MB`, `FLINK_TASKMANAGER_NATIVE_HEADROOM_MIN_MB` - JVM/pod memory split for the PyFlink TaskManager pod, on top of `FLINK_TASKMANAGER_MEMORY_GB`. Advanced tuning; the defaults suit most deployments. |
| Matcher runtime | `MATCHER_PYTHON_EXECUTION_MODE` (`process` or `thread`), `MATCHER_STATE_BACKEND` (e.g. `rocksdb`) - rendered into every sigma-detector `FlinkDeployment`. Existing pipelines need re-rendering (recreate/update) to pick up a change. |
| Correlation job tuning | `CORRELATION_JOB_PARALLELISM`, `CORRELATION_JOB_TASKMANAGER_MEMORY` / `_CPU`, `CORRELATION_JOB_JOBMANAGER_MEMORY` / `_CPU`, `CORRELATION_JOB_INPUT_TOPIC` |
| Agent job tuning | `AGENT_JOB_PARALLELISM`, `AGENT_JOB_TASKMANAGER_MEMORY` / `_CPU`, `AGENT_JOB_JOBMANAGER_MEMORY` / `_CPU`, `AGENT_NODE_SELECTOR_KEY` / `_VALUE` (defaults to the `FLINK_NODE_SELECTOR_*` pair above if unset), `DETECTFLOW_AGENT_SSL_CERT_FILE` / `_DEFAULT` (LLM CA-bundle path override / fallback-path convention - see the df-agent LLM config section under Jobs below). Agent job's own LLM ConfigMap/Secret are `jobs.agent.config`/`secret` (or `existingConfigMap`/`existingSecret`) - see the Jobs section below for keys. |
| Dashboard | `DASHBOARD_BROADCAST_INTERVAL_SECONDS`, `DASHBOARD_TOPOLOGY_TTL_SECONDS`, `ATTACK_CHAINS_LIST_SSE_HEARTBEAT_SECONDS` |
| JWT tuning | `JWT_ALGORITHM`, `JWT_ACCESS_TOKEN_EXPIRE_MINUTES`, `JWT_REFRESH_TOKEN_EXPIRE_DAYS` |
| Audit / rules | `AUDIT_LOGS_RETENTION_DAYS`, `RULE_VERSION_RETENTION`, `HIDE_RESTRICTED_RULE_BODIES` |
| Sync scheduler | `ENABLE_AUTO_SYNC`, `SYNC_API_REPOS_INTERVAL_MINUTES` / `_TIMEOUT_SECONDS`, `SYNC_ACTIVE_THREATS_ENABLED` / `_INTERVAL_MINUTES` / `_TIMEOUT_SECONDS` / `_FULL_REFRESH_INTERVAL_HOURS` / `_RETENTION_DAYS`, `SYNC_DELETE_AT_MISSING_IN_TDM`, `SYNC_DELETE_ORPHAN_HOS`, `SYNC_DELETE_UNREFERENCED_SYSTEM_RULES`, `HEALTH_CHECK_INTERVAL_MINUTES` |
| TDM / SOC Prime | `TDM_API_BASE_URL` (default `https://api.tdm.socprime.com`), `TDM_HOSTNAME` |
| Misc | `SETUP_DEMO_ENVIRONMENT_ON_STARTUP` |

**Do not set manually** - chart-computed, land in the rendered ConfigMap automatically:
`KUBERNETES_NAMESPACE`, `FLINK_IMAGE`, `IMAGE_PULL_POLICY`, `FLINK_CONFIG_CONFIGMAP_NAME`,
`FLINK_SIGMA_CONFIG_SECRET_NAME`, `FLINK_CHECKPOINTS_PVC` / `FLINK_HA_PVC` /
`FLINK_SAVEPOINTS_PVC`, `CORRELATION_JOB_IMAGE` / `_DEPLOYMENT_NAME` /
`_SERVICE_ACCOUNT`, `AGENT_JOB_IMAGE`, `AGENT_JOB_DEPLOYMENT_NAME`,
`DETECTFLOW_AGENT_CONFIGMAP_NAME`, `DETECTFLOW_AGENT_SECRET_NAME`.

**Out of scope** - `FLINK_PROVIDER` (default `kubernetes`), `FLINK_IMAGE_CMF`,
and the `cmf` branch (`CMF_URL`, `CMF_ENVIRONMENT`, `CMF_NAMESPACE`,
`CMF_CLIENT_CERT_PATH`, etc.) - this chart only supports the Flink
Kubernetes Operator deployment model;
Confluent Manager for Flink is not supported here.

### UI (`ui.*`)

Same shape as backend minus `persistence`, `serviceAccount`, and `secret`.

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `socprime/detectflow-oss` | UI image repository. (public) |
| `image.tag` | `admin-panel-ui-oss.v2.3.2` | UI image tag. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `serviceName` | `admin-panel-ui` | Fixed Deployment/Service name (referenced by the Ingress). |
| `replicas` | `1` | Number of UI pods. |
| `existingConfigMap` | `""` | Reference a pre-created ConfigMap. Empty → render `admin-panel-ui-config` from `config`. |
| `config` | `{}` | Free-form map `KEY: value` of UI env, merged over the chart-computed keys below (anything set here wins). Further keys the UI accepts: `VITE_ENVIRONMENT_STAGE`, `VITE_SSE_ENABLED`, `VITE_SSE_RECONNECT`, `VITE_SSE_RECONNECT_INTERVAL`, `VITE_SSE_RECONNECT_ATTEMPTS`. |
| `existingSecret` | `""` | Reference a pre-created Secret. Empty → render `admin-panel-ui-secret` from `secret`, but only if `secret` is non-empty. No required keys today (all current UI env is public); this exists for parity with backend/flink if a sensitive UI value is ever needed. |
| `secret` | `{}` | Free-form map `KEY: value` for the rendered Secret (used when `existingSecret` is empty and this is non-empty). |
| `resources` | requests 200m/256Mi, limits 1/512Mi | Container resources. |
| `service.type` | `ClusterIP` | UI Service type. |
| `service.port` | `4173` | UI Service port. |
| `service.annotations` | `{}` | Extra Service annotations. |
| `podAnnotations` / `podLabels` | `{}` | Extra pod metadata. |
| `nodeSelector` | `{app: detectflow-prod}` | Node selector. Set to `null` (**not** `{}`) on a cluster without that node label. |
| `tolerations` / `affinity` | `[]` / `{}` | Scheduling. |
| `podSecurityContext` / `securityContext` | runAsNonRoot uid 1001 / drop ALL | Security contexts - the UI image (v2.2.0+) runs as uid 1001, no fsGroup (no volumes). For older root-only images set to `null`, **not** `{}` (see backend). |
| `automountServiceAccountToken` | `false` | UI never talks to the K8s API. |
| `terminationGracePeriodSeconds` | `30` | Graceful shutdown window. |
| `extraEnvs` / `envFrom` | `[]` | Extra env sources. |
| `extraVolumes` / `extraVolumeMounts` | `[]` | Extra volumes / mounts. |
| `livenessProbe` | httpGet `/:http` | Liveness probe (set to `null` to disable - `{}` merges with and keeps the default). |
| `readinessProbe` | tcpSocket `http` | Readiness probe. |
| `updateStrategy` | `{type: RollingUpdate}` | Rollout strategy. |
| `podDisruptionBudget.enabled` | `false` | Create a PDB for the UI. |
| `podDisruptionBudget.minAvailable` | `1` | PDB minAvailable. |

#### What the chart puts in `admin-panel-ui-config`

In render mode (`ui.existingConfigMap` empty) the chart does not leave the UI
ConfigMap empty - it fills in the keys a deployment cannot work without,
derived from values you have already set:

| Key | Value |
| --- | --- |
| `VITE_API_BASE_URL` | `/api/v1` - relative, so the browser calls the UI host and the UI proxies to the backend |
| `VITE_API_PROXY_TARGET` | `http://<backend.serviceName>.<namespace>.svc.cluster.local:<backend.service.port>` |
| `VITE_PREVIEW_ALLOWED_HOSTS` | `ingress.ui.host` or `httpRoute.ui.hostnames`, plus `<ui.serviceName>.<namespace>.svc.cluster.local` and `localhost` |
| `VITE_USE_MOCK_API` | `"false"` |
| `VITE_USE_MOCK_AUTH` | `"false"` |

`VITE_PREVIEW_ALLOWED_HOSTS` is the one that bites when missing: the Vite
preview server answers `403` to any request whose `Host` header is not on the
list, so an ingress host absent from it makes the UI unreachable from outside.

Anything in `ui.config` overrides the corresponding key, so to publish the UI
under several hostnames, or to run against an external API, set that one key
and leave the rest to the chart. In reference mode nothing is rendered and the
pre-created ConfigMap must carry all of these itself.

### Flink support (`flink.*`)

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `socprime/detectflow-oss` | Flink Sigma detector image repository (public). |
| `image.tag` | `flink-sigma-detector-oss.v2.3.2` | Image tag. Handed to the backend as `FLINK_IMAGE`. |
| `image.pullPolicy` | `IfNotPresent` | `IMAGE_PULL_POLICY` for spawned Flink jobs. |
| `rbac.create` | `true` | Render Flink RBAC: SA `flink` (carrying `imagePullSecrets` when any are set, for spawned job pods), `flink-internal-role`, and `admin-panel-flink-access` bound to the backend SA. The latter grants: `events` read; `flinkdeployments`/`flinksessionjobs` + `apps/deployments` + `batch/jobs` full lifecycle (the last for pipeline-deletion storage-cleanup Jobs); and read-only `batch/jobs/status`, `pods`, `pods/log`, `configmaps` (pod state and logs shown in the UI; `configmaps` also lets the backend resolve `SSL_CERT_FILE` for the agent-job CA mount). Mirrors the canonical `flink-rbac.yaml`. `false` when RBAC is applied externally. |
| `existingConfigMap` | `""` | Reference a pre-created ConfigMap (any name). Empty → render `flink-config` from `config`. The chosen name is passed to the backend as `FLINK_CONFIG_CONFIGMAP_NAME`, which the operator-spawned Flink job spec reads - the pre-created ConfigMap must exist under that exact name. |
| `existingSecret` | `flink-sigma-config` | Reference a pre-created Secret (any name). Empty → render `flink-sigma-config` from `secret`. The chosen name is passed to the backend as `FLINK_SIGMA_CONFIG_SECRET_NAME`, same rule as `existingConfigMap`. |
| `secret` | `{}` | Free-form map `KEY: value` for the rendered Secret (used when `existingSecret` is empty). Expected keys: `KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_AUTH_METHOD`. |
| `config` | `{}` | Free-form map `KEY: value` for `flink-config`, rendered when `existingConfigMap` is empty **and** this is non-empty (both empty → no ConfigMap). Expected keys: `KAFKA_STARTING_OFFSET`, `LOG_LEVEL`, `LOG_FORMAT`. |
| `pvcs.enabled` | `true` | Create the checkpoints/HA/savepoints PVCs. |
| `pvcs.existingCheckpointsClaim` | `""` | Reference a pre-created PVC for checkpoints instead of rendering one - needed when the Flink volumes live on shared storage whose claims are made by hand. The name set here is what the backend receives as `FLINK_CHECKPOINTS_PVC`, so operator-spawned job pods mount the right claim. |
| `pvcs.existingHaClaim` | `""` | Same for the HA volume (`FLINK_HA_PVC`). |
| `pvcs.existingSavepointsClaim` | `""` | Same for savepoints (`FLINK_SAVEPOINTS_PVC`). |
| `pvcs.storageClass` | `""` | StorageClass for the Flink PVCs. |
| `pvcs.accessModes` | `[ReadWriteOnce]` | Applies to all three PVCs. Independent of `storageClass` - e.g. Longhorn decides block vs. NFS/share-manager provisioning per-PVC from this field, not the storage class name. Set `[ReadWriteMany]` if TaskManager/JobManager pods can land on different nodes and need to share these volumes. |
| `pvcs.checkpointsSize` | `5Gi` | Checkpoints PVC size. |
| `pvcs.haSize` | `2Gi` | HA PVC size. |
| `pvcs.savepointsSize` | `5Gi` | Savepoints PVC size. |
| `pvcs.keep` | `true` | Add `helm.sh/resource-policy=keep` so the PVCs survive uninstall/upgrade. |

> **Note:** the `spec-node-ns-pod-disk=pvc-security` node label is for the Flink
> **job** pods (PVC scheduling). Those pods are created by the operator from the
> backend's `FlinkDeployment` spec - set that nodeSelector on the backend side,
> not in this chart.

### Jobs (`jobs.*`)

Images for the worker jobs the backend launches as Deployments in this
namespace (df-agent / df-correlation) - same pattern as the Flink image: no
static workload here, handed to the backend via chart-computed ConfigMap keys
and triggered from the UI through the backend.

| Key | Default | Description |
| --- | --- | --- |
| `agent.image.repository` | `socprime/detectflow-oss` | df-agent image repository (public). |
| `agent.image.tag` | `df-agent-oss.v2.3.2` | Handed to the backend as `AGENT_JOB_IMAGE`. |
| `agent.deploymentName` | `agent-job` | `AGENT_JOB_DEPLOYMENT_NAME` the backend manages. |
| `correlation.image.repository` | `socprime/detectflow-oss` | df-correlation image repository (public). |
| `correlation.image.tag` | `df-correlation-oss.v2.3.2` | Handed to the backend as `CORRELATION_JOB_IMAGE`. |
| `correlation.deploymentName` | `correlation-job` | `CORRELATION_JOB_DEPLOYMENT_NAME` the backend manages. |
| `correlation.serviceAccount` | `default` | `CORRELATION_JOB_SERVICE_ACCOUNT` for the job pods. |

The df-agent job (v2.1.0+ backend) additionally reads its own LLM runtime
config at start - ConfigMap `detectflow-agent-config` and Secret
`detectflow-agent-secrets` (`LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY`, rate/
retry/size tuning). Same render/reference toggle as the rest of the chart:
`jobs.agent.existingConfigMap`/`existingSecret` (empty → chart renders each
from `jobs.agent.config`/`secret`, and only when that map is non-empty - a
pre-created ConfigMap with a forgotten `existingConfigMap` would otherwise
collide with an empty one the chart rendered). The chosen names are passed to the
backend as `DETECTFLOW_AGENT_CONFIGMAP_NAME`/`DETECTFLOW_AGENT_SECRET_NAME`,
the same principle as `FLINK_CONFIG_CONFIGMAP_NAME`/
`FLINK_SIGMA_CONFIG_SECRET_NAME` above. The Secret is optional to render (no
`fail()` guard, unlike `flink.secret`) - leave both `existingSecret` and
`secret` empty when the LLM endpoint needs no credentials.

For a self-signed-cert local LLM endpoint: `httpx` (the agent's HTTP client)
respects `SSL_CERT_FILE` for a custom CA bundle - put the CA cert content
under a Secret key and `SSL_CERT_FILE: /mount/path/<that key>` in
`jobs.agent.config`. This chart only provisions the ConfigMap/Secret objects;
the actual volume mount is backend-side (the agent-job pod spec is spawned at
runtime, not rendered by this chart), including on the per-pipeline
`agent-{correlation_pipeline_id}` deploy path. The backend derives the mount
from `SSL_CERT_FILE` when it can read
`detectflow-agent-config` (needs `get` on ConfigMaps in the Flink namespace);
without that RBAC it falls back to the `/etc/ssl/agent-ca/ca.pem` convention -
so as long as the Secret key equals `basename(SSL_CERT_FILE)` (e.g. `ca.pem`),
the mount resolves either way, no extra RBAC required.

The CA cert content itself is a separate concern from the mount: it must
carry a `subjectAltName` matching the LLM endpoint's host/IP - a CN-only cert
is rejected by Python's `ssl` module (`IP address mismatch`) even once
correctly mounted. `LLM_SSL_VERIFY: "false"` in `jobs.agent.config` is a
documented test-only bypass, not a fix.

### NetworkPolicy (`networkPolicy.*`)

Optional in-namespace traffic restrictions (requires a CNI that enforces
NetworkPolicy). Disabled by default.

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `false` | Render NetworkPolicies for the UI and backend pods. |
| `ui.allowAll` | `true` | Accept ingress to the UI port from any source (ALB `target-type: ip`, out-of-namespace controllers). `false` → only `extraFrom`. |
| `ui.extraFrom` | `[]` | Extra `NetworkPolicyPeer` entries for the UI. |
| `backend.allowAll` | `false` | `false` → backend reachable only from the UI pods (+ `extraFrom`). Set `true` or add peers if `ingress.backend.enabled`. |
| `backend.extraFrom` | `[]` | Extra `NetworkPolicyPeer` entries for the backend. |

### Ingress (`ingress.*`)

Two **independent** Ingress resources - `ingress.ui` and `ingress.backend` - so
each DNS name gets its own IngressClass, annotations and TLS/certificate (e.g. a
separate ACM cert per host on AWS ALB). Same key shape for both blocks:

| Key | UI default | Backend default | Description |
| --- | --- | --- | --- |
| `<blk>.enabled` | `true` | `false` | Render this Ingress. |
| `<blk>.className` | `""` | `""` | IngressClass (`nginx`, `traefik`, `alb`, …). Empty → cluster default. |
| `<blk>.host` | `detectflow.example.com` | `api.detectflow.example.com` | Hostname. UI → `admin-panel-ui:4173`, backend → `admin-panel-be:8000`. |
| `<blk>.pathType` | `Prefix` | `Prefix` | `Prefix`, `Exact`, or `ImplementationSpecific` - `Prefix` works with every mainstream controller. |
| `<blk>.annotations` | `{}` | `{}` | Extra annotations (ALB / cert-manager / per-host ACM `certificate-arn`). |
| `<blk>.tls.enabled` | `true` | `true` | Add a TLS block + cert-manager annotation. Set `false` for ALB/ACM. |
| `<blk>.tls.clusterIssuer` | `letsencrypt-prod` | `letsencrypt-prod` | cert-manager `ClusterIssuer` (used only when `tls.enabled`). |

`<blk>` is `ui` or `backend`. The UI proxies `/api/v1` to the backend, so the
backend Ingress is only needed for direct external API access.

Rendered names: `<release>-ui` and `<release>-backend`. TLS secrets:
`<release>-ui-tls` / `<release>-backend-tls`.

### Gateway API (`httpRoute.*`)

Alternative to `ingress.*` for clusters with no classic Ingress controller
(GKE Gateway, Istio/Cilium Gateway API). Renders an `HTTPRoute`
(`gateway.networking.k8s.io/v1`) instead of an `Ingress`. `httpRoute.ui` and
`httpRoute.backend` are **mutually exclusive** with `ingress.ui`/`ingress.backend`
respectively - the chart fails to render if both are enabled for the same
component. Same key shape for both blocks:

| Key | Default | Description |
| --- | --- | --- |
| `<blk>.enabled` | `false` | Render this HTTPRoute. |
| `<blk>.parentRefs` | one entry, placeholder values | Which `Gateway`(s) to attach to - `name`/`namespace`/`sectionName`. The `Gateway` itself is **not created by this chart**, must already exist. `sectionName` pins to one listener - required if the Gateway has multiple (e.g. a separate HTTP-redirect-only listener). |
| `<blk>.hostnames` | one placeholder entry | Hostnames this route matches. Must fall within whatever pattern the Gateway listener allows (e.g. a wildcard listener) - a hostname outside it gets `Accepted: False` / `NoMatchingListenerHostname`. |
| `<blk>.path` / `<blk>.pathType` | `/` / `PathPrefix` | Single rule per route (same one-path-per-component scope as `ingress.*`). `pathType`: `Exact`, `PathPrefix`, or `RegularExpression`. |
| `<blk>.filters` | `[]` | Passthrough list of `HTTPRouteFilter` (e.g. `RequestHeaderModifier`). |
| `<blk>.annotations` / `<blk>.labels` | `{}` | Extra metadata on the HTTPRoute object. |

`<blk>` is `ui` or `backend`. TLS is **not configured here** - it's a
Gateway-listener concern (the Gateway's owner terminates TLS on its listener,
independent of this chart). The chart also refuses to render, with a clear
error, if the cluster has no Gateway API CRDs installed
(`gateway.networking.k8s.io/v1` not found).

Many Gateway implementations only accept routes from namespaces the Gateway
explicitly allows (`allowedRoutes.namespaces.from: Selector`) - this chart
cannot label namespaces, see the post-install NOTES for a reminder if routes
show `Accepted: False`.

```yaml
ingress:
  ui:
    enabled: false          # mutually exclusive with httpRoute.ui
httpRoute:
  ui:
    enabled: true
    parentRefs:
      - name: main
        namespace: gateway-system
        sectionName: websecure
    hostnames:
      - detectflow.example.com
```

---

## Exposing the apps

**Ingress with cert-manager** (e.g. nginx) - UI public, backend reached via the
UI proxy:

```yaml
ingress:
  ui:
    enabled: true
    className: nginx
    host: detectflow.example.com
    tls:
      enabled: true
      clusterIssuer: letsencrypt-prod
  backend:
    enabled: false          # API only via the UI's /api/v1 proxy
```

**AWS EKS / ALB** - two Ingresses, a separate ACM certificate per DNS, TLS by ALB
(not cert-manager). Requires the AWS Load Balancer Controller installed.

```yaml
ingress:
  ui:
    enabled: true
    className: alb
    host: ui.example.com
    tls:
      enabled: false        # ALB terminates TLS via ACM
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip          # ClusterIP svc → pod IPs
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:<region>:<acct>:certificate/<UI_CERT>"
      alb.ingress.kubernetes.io/healthcheck-path: /
  backend:
    enabled: true
    className: alb
    host: api.example.com
    tls:
      enabled: false
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:<region>:<acct>:certificate/<API_CERT>"
      alb.ingress.kubernetes.io/healthcheck-path: /health
```

> Each Ingress gets its own ACM cert (`certificate-arn`). For per-target-group
> health checks with `target-type: ip`, also set
> `backend.service.annotations`/`ui.service.annotations` with
> `alb.ingress.kubernetes.io/healthcheck-path` if the controller version needs it.

**Without ingress** (port-forward):

```bash
kubectl port-forward --address 0.0.0.0 -n flink svc/admin-panel-ui 4173:4173 &
kubectl port-forward --address 0.0.0.0 -n flink svc/admin-panel-be 8000:8000 &
```

---

## Disk protection

PVCs carry `helm.sh/resource-policy=keep` (via `*.keep: true`), so `helm
uninstall`/`upgrade` will **not** delete them. For full data safety against PVC
deletion, also set the StorageClass `reclaimPolicy: Retain` (cluster-level) - the
PV and data then survive even a manual `kubectl delete pvc`.

```bash
kubectl get storageclass <sc> -o jsonpath='{.reclaimPolicy}{"\n"}'   # prefer Retain
```

### What uninstall leaves behind

`helm uninstall` removes only what the chart created. The Flink workloads are
not among them: the backend creates those at runtime through the operator, so
Helm never owned them and does not delete them. After uninstalling, the
namespace still holds:

- **`FlinkDeployment` custom resources** - one per detection pipeline
  (`flink-<id>`), plus `agent-<id>` and `corr-<id>` for the enrichment and
  correlation jobs. The operator keeps the Deployments and pods it derived
  from them running, in whatever state they were in.
- **ConfigMaps and Secrets you pre-created** in reference mode - the chart
  only referenced them by name.
- **PVCs carrying `keep: true`** (the default), as described above.

The clean path is to delete the pipelines from the UI *before* uninstalling:
the backend then removes the custom resources and the operator tears the
workloads down with them.

If the release is already gone, delete the custom resources directly. Delete
the `FlinkDeployment`, not the Deployment it produced - the operator simply
recreates a Deployment whose `FlinkDeployment` still exists:

```bash
kubectl get flinkdeployments.flink.apache.org -n <namespace>
kubectl delete flinkdeployments.flink.apache.org --all -n <namespace>
```

Worth knowing before a reinstall: leftovers from the previous release stay
visible to the new one, so pipelines you thought were gone reappear in the UI.

### Using pre-created PVCs

Any volume can point at a claim made outside the chart:
`backend.persistence.existingClaim` for the metrics volume, and
`flink.pvcs.existingCheckpointsClaim` / `existingHaClaim` /
`existingSavepointsClaim` for the Flink volumes (each independent - override one
and the other two stay chart-managed). Typical reason: the volumes live on
shared storage whose claims are provisioned by hand.

The name set there is what the chart uses everywhere - the pod's `claimName`
and, for the Flink volumes, the `FLINK_CHECKPOINTS_PVC` / `FLINK_HA_PVC` /
`FLINK_SAVEPOINTS_PVC` keys the backend passes to operator-spawned job pods.

Points to know:

- **Create the PVC before installing/upgrading.** The chart only references it;
  a missing claim leaves pods `Pending` on an unbound volume.
- **`accessModes` are the existing PVC's own.** Give it `ReadWriteMany` if
  JobManager/TaskManager pods can land on different nodes - the chart's
  `pvcs.accessModes` applies only to PVCs it still renders.
- **`keep`, `storageClass` and the size keys do not apply** to an existing
  claim. Its lifecycle, including deletion protection, is yours to manage.
- **Switching an already chart-managed PVC to `existingClaim` releases it.**
  The old PVC drops out of the Helm release; `keep: true` (default) stops the
  data being deleted, but the claim is then unmanaged and has to be cleaned up
  by hand. Create the replacement claim first, upgrade, confirm the jobs come up
  on it, and only then remove the old one.

```bash
kubectl get pvc -n flink   # confirm the pre-created claims are Bound first
```

---

## Validate before installing

Values are validated against `values.schema.json` on every
`lint`/`template`/`install`/`upgrade` (types, required image fields, `latest`
tag rejected). The chart also fails fast when `backend.existingSecret` is empty
and `backend.secret` provides no keys (same for `flink`). `ui.secret` is the
exception - optional, no such check (see the UI table above).

```bash
# use your own *-values.yaml overlay (copied from values.yaml.example)
# if you're validating reference mode
helm lint charts/detectflow -f charts/detectflow/custom-values.yaml
helm template detectflow charts/detectflow -n flink -f charts/detectflow/custom-values.yaml
helm template detectflow charts/detectflow -n flink | kubectl apply --dry-run=server -f -
```
