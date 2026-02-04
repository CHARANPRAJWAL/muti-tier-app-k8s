# Kubernetes Deployment Guide

Multi-tier application deployment on Kubernetes using a **React frontend**, **Node.js backend**, and **PostgreSQL database**.

## Architecture

```
                    ┌─────────────────────────────────────────────────┐
                    │                  Ingress (nginx)                │
                    │         /api  ──►  backend-service:5000         │
                    │         /     ──►  frontend-service:80          │
                    └──────────┬────────────────────┬─────────────────┘
                               │                    │
                    ┌──────────▼──────────┐  ┌──────▼──────────┐
                    │  Backend (x2 pods)  │  │ Frontend (x2)   │
                    │  Node.js :5000      │  │ React App :3000  │
                    └──────────┬──────────┘  └─────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  PostgreSQL (x1)    │
                    │  :5432              │
                    │  PVC: 5Gi           │
                    └─────────────────────┘
```

All resources are deployed in the `mtapp` namespace.

## Directory Structure

```
kubernetes/
├── base/
│   └── namespace.yaml          # mtapp namespace
├── config/
│   ├── configmap.yaml          # App configuration (DB host, ports, API URL)
│   └── secret.yaml             # Database credentials
├── database/
│   ├── configmap.yaml          # PostgreSQL init SQL script
│   ├── pvc.yaml                # Persistent volume claim (5Gi)
│   ├── deployment.yaml         # PostgreSQL deployment
│   ├── service.yaml            # postgres-service (ClusterIP:5432)
│   └── networkpolicy.yaml      # Only backend can access DB
├── backend/
│   ├── deployment.yaml         # Node.js API (2 replicas)
│   ├── service.yaml            # backend-service (ClusterIP:5000)
│   ├── hpa.yaml                # Auto-scale 2-10 pods
│   └── networkpolicy.yaml      # Only frontend + ingress can access
├── frontend/
│   ├── deployment.yaml         # React app (2 replicas)
│   ├── service.yaml            # frontend-service (ClusterIP:80)
│   ├── hpa.yaml                # Auto-scale 2-10 pods
│   └── networkpolicy.yaml      # Only ingress can access
└── ingress/
    └── ingress.yaml            # NGINX ingress routing rules
```

## Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for your cluster
- [kind](https://kind.sigs.k8s.io/) (for local development)
- Docker images pushed to registry:
  - `charanprajwal001/frontend-app:latest`
  - `charanprajwal001/backend-app:latest`

## Deployment Steps

### Step 1: Create the Kind Cluster (Local Development)

```bash
kind create cluster --name dev
kubectl config use-context kind-dev
```

### Step 2: Install NGINX Ingress Controller

Required for ingress routing to work. The kind-specific manifest configures the controller with the correct node ports.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Wait for the controller to be ready:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

### Step 3: Create Namespace

```bash
kubectl apply -f base/namespace.yaml
```

### Step 4: Deploy Configuration and Secrets

```bash
kubectl apply -f config/secret.yaml
kubectl apply -f config/configmap.yaml
```

The `app-config` ConfigMap contains:

| Key                | Value              | Used By          |
|--------------------|--------------------|------------------|
| `DB_HOST`          | postgres-service   | Backend          |
| `DB_PORT`          | 5432               | Backend          |
| `DB_NAME`          | appdb              | Backend          |
| `BACKEND_PORT`     | 5000               | Backend          |
| `REACT_APP_API_URL`| /api               | Frontend         |

The `db-credentials` Secret contains PostgreSQL credentials referenced by the backend and database deployments.

### Step 5: Deploy PostgreSQL Database

```bash
kubectl apply -f database/configmap.yaml
kubectl apply -f database/pvc.yaml
kubectl apply -f database/deployment.yaml
kubectl apply -f database/service.yaml
```

Wait for postgres to be ready before proceeding:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgres \
  -n mtapp --timeout=120s
```

The database initializes with a `users` table (seeded with sample data) using the init SQL ConfigMap.

### Step 6: Deploy Backend

```bash
kubectl apply -f backend/deployment.yaml
kubectl apply -f backend/service.yaml
```

Wait for backend pods:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=backend \
  -n mtapp --timeout=120s
```

The backend has an `init container` (`wait-for-postgres`) that blocks until the database is accepting connections.

### Step 7: Deploy Frontend

```bash
kubectl apply -f frontend/deployment.yaml
kubectl apply -f frontend/service.yaml
```

Wait for frontend pods:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=frontend \
  -n mtapp --timeout=120s
```

The frontend deployment references the `app-config` ConfigMap to set `REACT_APP_API_URL`, which tells the app to route API calls through the ingress at `/api`.

### Step 8: Apply Network Policies

```bash
kubectl apply -f database/networkpolicy.yaml
kubectl apply -f backend/networkpolicy.yaml
kubectl apply -f frontend/networkpolicy.yaml
```

Network policy rules:

| Target     | Allowed Sources                     | Port |
|------------|-------------------------------------|------|
| PostgreSQL | Backend pods only                   | 5432 |
| Backend    | Frontend pods + ingress-nginx       | 5000 |
| Frontend   | ingress-nginx only                  | 3000 |

### Step 9: Apply Horizontal Pod Autoscalers

```bash
kubectl apply -f backend/hpa.yaml
kubectl apply -f frontend/hpa.yaml
```

Both HPAs scale between **2-10 replicas** based on:
- CPU utilization > 70%
- Memory utilization > 80%

> **Note:** HPAs require the [Metrics Server](https://github.com/kubernetes-sigs/metrics-server) to be installed. On kind, metrics will show as `<unknown>` without it.

### Step 10: Apply Ingress

```bash
kubectl apply -f ingress/ingress.yaml
```

Routing rules:

| Path    | Service           | Port |
|---------|-------------------|------|
| `/api`  | backend-service   | 5000 |
| `/`     | frontend-service  | 80   |

## Verification

### Check all resources

```bash
kubectl get all,ingress,networkpolicy,hpa,configmap,secret,pvc -n mtapp
```

### Test backend health

```bash
kubectl run test --rm -i --restart=Never \
  --image=curlimages/curl -n mtapp \
  -- curl -s http://backend-service:5000/api/health
# Expected: {"status":"OK","message":"Server is running"}
```

### Test database connectivity

```bash
kubectl run test --rm -i --restart=Never \
  --image=curlimages/curl -n mtapp \
  -- curl -s http://backend-service:5000/api/users
# Expected: JSON array of users
```

### Test through ingress (local)

Port-forward the ingress controller:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 9090:80
```

Then in another terminal:

```bash
# Frontend
curl http://localhost:9090/

# Backend API
curl http://localhost:9090/api/health
curl http://localhost:9090/api/users
```

## Quick Deploy (All at Once)

```bash
# Namespace + Config
kubectl apply -f base/
kubectl apply -f config/

# Data tier
kubectl apply -f database/
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n mtapp --timeout=120s

# App tier
kubectl apply -f backend/
kubectl apply -f frontend/
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=backend -n mtapp --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=frontend -n mtapp --timeout=120s

# Ingress
kubectl apply -f ingress/
```

## Teardown

```bash
# Delete all app resources
kubectl delete namespace mtapp

# Delete ingress controller (optional)
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Delete kind cluster (local only)
kind delete cluster --name dev
```
