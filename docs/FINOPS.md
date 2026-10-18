# R10 — application capacity, SLO and rightsizing

Built for forks; nothing in v2 has run on Azure.
The full workflow uses the tx02v2 commit pinned in `deploy/local/tx02v2.ref`.
The small scenario remains on one node with 7 GiB; the capacity scenario uses
`LOCAL_TOPOLOGY=ha` and `LOCAL_FINOPS=1` and recommends 12 GiB available to Docker.
Run heavy scenarios in Actions.

## Lesson and evidence

The CI `e2e-platform` job runs `scripts/capacity-app.sh` after the earlier probes.
On Linux or in a devcontainer with enough resources:

```bash
LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e-platform
```

The test accepts only the `kind-tx02v2-local` kubeconfig. It measures real HTTPS
requests to `/api/messages` through the Gateway with CA validation, without saving
or exposing credentials. Every phase has bounded concurrency and duration, a Pod
deadline and cleanup.

1. Measure a baseline with four clients for 30 seconds (success >= 99%, p99 <= 1.5 s).
2. Inject CPU StressChaos with a 500m API CPU limit alongside HTTP load.
   Require the HPA to reach four ready replicas.
3. Drain only API Pods from a worker belonging to kind. PDB, readiness and
   RollingUpdate remain active; the client must maintain the same SLO.
4. Remove stress, try CPU requests of 100m → 50m, and require scale-down to two.
   Repeat the same load/SLO and record aggregate requests before and after.
5. Lock a PostgreSQL table for 10 s: at least ten blocked API connections, a
   saturated pool and client-visible errors. Release the lock, require recovery,
   and repeat the SLO. More Pods do not fix a database bottleneck.
6. Require a VPA recommendation with `updateMode: Off`; a quota rejects an
   expensive Pod for exceeding CPU. Evidence JSON includes counts and latency,
   without response bodies.

Argo CD's controller is paused during the imperative experiment. The trap restores
requests, HPA and the controller's original replica count, including on failure.
GitOps manifests remain the source of permanent configuration. The normal HPA
has stabilization windows; only the test uses a short scale-down interval.

## Showback and interpretation

Every application Pod template requires `cost.lab/owner` and
`cost.lab/environment`; `contract-app` fails if either label is missing. Set owner
in kustomize to the lesson's responsible person. OpenCost and Grafana come from
tx02v2: see the [infrastructure FinOps lesson](https://github.com/maringelix/tx02v2/blob/main/docs/FINOPS.md)
for `/allocation`, idle/shared costs, sources/date/currency/region, and services
outside Pods.

Lower requests do not guarantee savings: HPA may request more replicas. Compare
aggregate requests, measured use, latency, errors and allocation under the same
load. The 50m candidate is an experiment, restored afterward; it does not
automatically change production configuration. VPA Off does not compete with HPA
over requests.

## Azure and cleanup

AKS has autoscaling on its regular pool and an optional tainted Spot pool; the
tx02v2 lesson uses a disposable task with a deadline and explicit on-demand
fallback, preserving the critical app. Scaling replicas in kind does not prove
managed scaling or Azure prices.

Use the tx02v2 estimate, budget and expiration gate before any apply. OpenCost is
not a bill and a budget is not a billing cap.

On failure, inspect `capacity-app.json`, events, HPA/PDB/VPA, metrics-server,
pool/connections and Gateway logs. The e2e teardown always destroys resources
created by that state and checks leftovers. Cloud cleanup follows the pair's
runbook and occurs only in an authorized run.
