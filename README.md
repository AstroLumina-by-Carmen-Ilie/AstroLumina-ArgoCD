# AstroLumina-ArgoCD

GitOps bootstrap for the AstroLumina platform on RKE2: install prerequisites
for ArgoCD plus the `Application` that syncs
[AstroLumina-Kubernetes](https://github.com/AstroLumina-by-Carmen-Ilie/AstroLumina-Kubernetes)
(`HEAD` of `main`) into the cluster with **manual** sync.

Theory and day-2 operations live in [ARGOCD.md](./ARGOCD.md) -- read its
section 0 (prerequisites) before the first sync.

## Layout

- `install/` -- namespace + explicit cluster-admin grant for the ArgoCD
  service accounts, applied once before the Helm release.
- `apps/` -- the `astrolumina-kubernetes` Application (whole repo, manual sync).

## Install order

```bash
export K8S_CP_CONN=$(doppler secrets get K8S_CP_CONN --plain --project astrolumina --config prd)

# 1. Namespace + RBAC grant (from this repo root).
kubectl apply -k install/   # via ssh on the CP, same pattern as ARGOCD.md

# 2. ArgoCD itself via the Helm chart (versions + values in ARGOCD.md section 2).
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version <CHART_VERSION> -f ~/argocd-values.yaml

# 3. Register the app (ArgoCD takes over from here).
kubectl apply -f apps/astrolumina-kubernetes.yaml -n argocd
```

Then open the ArgoCD UI, review the diff, and press **SYNC** per change.
