# tobehealthy k8s manifests

GitOps source-of-truth for the tobehealthy cluster. Argo CD watches `overlays/prod` and applies changes.

## Layout

```
k8s-manifests/
├── base/                       Plain manifests (namespace, mysql, redis, backend, frontend, ingress)
│   └── kustomization.yaml
├── overlays/
│   └── prod/
│       └── kustomization.yaml  Image tag overrides (updated by CI)
├── bootstrap/
│   └── argocd-application.yaml The root Argo CD Application
├── gha-templates/              Workflows to copy into the backend / frontend app repos
│   ├── backend-deploy.yml
│   └── frontend-deploy.yml
└── scripts/
    └── apply-secrets.sh        One-time Secrets bootstrap from .env files
```

## Flow

```
[push to to-be-healthy/backend or FrontEnd main]
        │
        ▼
[GHA: build → push image to ghcr.io/to-be-healthy/<svc>:sha-XXXX]
        │
        ▼
[GHA: checkout k8s-manifests, run `kustomize edit set image`, commit, push]
        │
        ▼
[Argo CD detects new commit → kustomize build overlays/prod → kubectl apply]
        │
        ▼
[Deployment rolling restart with the new image]
```

---

## One-time setup (perform on GitHub)

### 1. Create this repo on GitHub

```bash
# from the server (~/workspace/k8s-manifests/)
git init -b main
git add .
git commit -m "initial manifests"
gh repo create to-be-healthy/k8s-manifests --public --source=. --push
# or create on GitHub UI, then:
#   git remote add origin git@github.com:to-be-healthy/k8s-manifests.git
#   git push -u origin main
```

### 2. Create a Personal Access Token (PAT) for CI write access

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens:
- Repository access: `to-be-healthy/k8s-manifests`
- Permissions: Contents (read/write)
- Copy the token.

### 3. Add the PAT to both app repos as `MANIFEST_REPO_TOKEN`

For each of `to-be-healthy/backend` and `to-be-healthy/FrontEnd`:
- Settings → Secrets and variables → Actions → New repository secret
- Name: `MANIFEST_REPO_TOKEN`
- Value: the PAT from step 2.

### 4. Add frontend build-time vars to `to-be-healthy/FrontEnd`

Settings → Secrets and variables → Actions → **Variables** tab (not Secrets — these are baked into the JS bundle, so not secret):

- `NEXT_PUBLIC_WEB_URI` = `https://geonganghaejim.site`
- `NEXT_PUBLIC_API_URL` = `/api`
- `NEXT_PUBLIC_AUTH_URL` = `/api`
- `INTERNAL_API_URL` = `http://backend:8080`
- `NEXT_PUBLIC_KAKAO_CLIENT_ID` = `...`
- `NEXT_PUBLIC_NAVER_CLIENT_ID` = `...`
- `NEXT_PUBLIC_GOOGLE_CLIENT_ID` = `...`
- `NEXT_PUBLIC_APPLE_CLIENT_ID` = `tobehealthy.apple.login`

### 5. Copy workflow files into the app repos

```bash
# in to-be-healthy/backend
mkdir -p .github/workflows
cp <this repo>/gha-templates/backend-deploy.yml .github/workflows/deploy.yml
git add .github/workflows/deploy.yml && git commit -m "ci: build & push to GHCR, bump manifest" && git push

# same in to-be-healthy/FrontEnd
cp <this repo>/gha-templates/frontend-deploy.yml .github/workflows/deploy.yml
```

### 6. Make GHCR images public (or set up imagePullSecret)

By default ghcr.io images are private. Easiest: in GitHub org settings → Packages, mark `backend` and `frontend` packages as **public** after the first push.

Alternative for private images: create an imagePullSecret in the cluster:
```bash
kubectl -n tobehealthy create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<PAT with read:packages>
# then add `imagePullSecrets: [{name: ghcr-pull}]` to each Deployment spec.
```

---

## One-time setup (perform on the cluster)

### 1. Bootstrap secrets and ClusterIssuers (Argo CD does not manage these)

```bash
ssh ubuntu@116.120.240.197
cd ~/workspace/k8s-manifests

# ClusterIssuers (cluster-scoped, applied once)
kubectl apply -f base/50-clusterissuers.yaml

# Secrets from .env files (cluster-side, source-of-truth is .env files, not git)
./scripts/apply-secrets.sh
```

### 2. Register the Argo CD Application

```bash
kubectl apply -f bootstrap/argocd-application.yaml
# Argo CD will then pull this repo, kustomize-build overlays/prod, and apply.
```

### 3. (Optional) Access the Argo CD UI

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Port-forward to localhost
kubectl -n argocd port-forward svc/argocd-server 8443:443
# Open https://localhost:8443  (user: admin)
```

Or expose via Ingress at `argocd.geonganghaejim.site` (add DNS A record first):
```bash
kubectl -n argocd apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [argocd.geonganghaejim.site]
      secretName: argocd-tls
  rules:
    - host: argocd.geonganghaejim.site
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: argocd-server, port: {number: 80}}
EOF
```

---

## How a deploy happens end-to-end

1. Developer pushes a commit to `to-be-healthy/backend@main`.
2. `.github/workflows/deploy.yml`:
   - Builds image, tags with `sha-<short-commit>` and `latest`.
   - Pushes to `ghcr.io/to-be-healthy/backend`.
   - Checks out `to-be-healthy/k8s-manifests`, runs `kustomize edit set image` in `overlays/prod`, commits, pushes.
3. Argo CD sees a new commit on the manifest repo:
   - Re-runs `kustomize build overlays/prod`.
   - Applies the diff (only the image tag changed → Deployment is patched).
   - Kubernetes rolling-updates the pod.

## Troubleshooting

- `argocd app sync tobehealthy` from the Argo CD CLI to force a sync.
- `kubectl -n argocd describe app tobehealthy` to see sync status / errors.
- `kubectl -n tobehealthy describe pod -l app=backend` if a new image fails to pull.
- Check Argo CD UI → Application → "App Diff" tab for current vs desired state.

## Local emergency override

If Argo CD is down and you must hot-patch:
```bash
kubectl -n tobehealthy set image deploy/backend backend=ghcr.io/to-be-healthy/backend:hotfix
```
**Note:** self-heal will revert this on the next sync if `automated.selfHeal: true`. Disable temporarily via UI if you need the manual override to stick.
