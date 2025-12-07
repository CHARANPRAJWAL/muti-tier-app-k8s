# Kubernetes Production Deployment

## Prerequisites

- Kubernetes cluster (1.25+)
- kubectl configured
- NGINX Ingress Controller (for ingress)
- Container images built and available

## Manifest Structure

The Kubernetes manifests are organized into 5 consolidated files:

1. **namespace.yaml** - Namespace definition (`mtapp`)
2. **postgres.yaml** - PostgreSQL database (PVC, ConfigMap, Deployment, Service)
3. **backend.yaml** - Backend API (Deployment, Service)
4. **frontend.yaml** - Frontend web app (Deployment, Service)
5. **config.yaml** - Application configuration (ConfigMap, Secret, NetworkPolicies, HPA, Ingress)

## Quick Start

### 1. Build and Push Images

```bash
# Build images
docker build -t <registry>/multi-tier-app-backend:latest ./backend
docker build -t <registry>/multi-tier-app-frontend:latest ./frontend

# Push to registry
docker push <registry>/multi-tier-app-backend:latest
docker push <registry>/multi-tier-app-frontend:latest
```

### 2. Update Image References

Update the image references in:
- `backend.yaml` (line 27)
- `frontend.yaml` (line 27)

### 3. Deploy to Kubernetes

```bash
# Apply all resources in order
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/config.yaml
kubectl apply -f kubernetes/postgres.yaml
kubectl apply -f kubernetes/backend.yaml
kubectl apply -f kubernetes/frontend.yaml

# Or apply all at once
kubectl apply -f kubernetes/
```

### 4. Verify Deployment

```bash
# Check all resources
kubectl get all -n mtapp

# Check pods status
kubectl get pods -n mtapp -w

# Check services
kubectl get svc -n mtapp

# Check ingress
kubectl get ingress -n mtapp
```

## Configuration

### Environment Variables

Edit `config.yaml` for application configuration:

**ConfigMap (non-sensitive):**
- `DB_HOST`: PostgreSQL service name
- `DB_PORT`: PostgreSQL port
- `DB_NAME`: Database name
- `BACKEND_PORT`: Backend API port
- `REACT_APP_API_URL`: Frontend API URL

**Secret (sensitive data):**
- `POSTGRES_USER`: Database username
- `POSTGRES_PASSWORD`: Database password
- `DB_USER`: Backend database username
- `DB_PASSWORD`: Backend database password

> **Note**: In production, use sealed-secrets, external-secrets, or a proper secret management solution like Vault.

### Storage

The PostgreSQL PVC requests 5Gi by default. Modify `postgres.yaml` (PersistentVolumeClaim section) to:
- Change storage size
- Specify a storageClassName for your cluster

### Scaling

HPA is configured for backend and frontend in `config.yaml`:
- Min replicas: 2
- Max replicas: 10
- CPU target: 70%
- Memory target: 80%

Modify the HorizontalPodAutoscaler sections in `config.yaml` to adjust these values.

### Network Policies

Network policies are defined in `config.yaml` to restrict traffic:
- **PostgreSQL**: Only accepts connections from backend pods
- **Backend**: Only accepts connections from frontend pods and ingress
- **Frontend**: Only accepts connections from ingress

## Accessing the Application

### Option 1: Ingress (Production)

Add to `/etc/hosts`:
```
<INGRESS_IP> multi-tier-app.local
```

Access at: http://multi-tier-app.local

### Option 2: Port Forward (Development)

```bash
# Frontend
kubectl port-forward -n mtapp svc/frontend-service 3000:80

# Backend API
kubectl port-forward -n mtapp svc/backend-service 5000:5000
```

## Troubleshooting

```bash
# View logs
kubectl logs -n mtapp -l app.kubernetes.io/name=backend
kubectl logs -n mtapp -l app.kubernetes.io/name=frontend
kubectl logs -n mtapp -l app.kubernetes.io/name=postgres

# Describe resources
kubectl describe pod -n mtapp <pod-name>
kubectl describe deployment -n mtapp <deployment-name>

# Get events
kubectl get events -n mtapp --sort-by='.lastTimestamp'
```

## Cleanup

```bash
# Delete all resources
kubectl delete -f kubernetes/

# Or delete the namespace (removes everything)
kubectl delete namespace mtapp
```

## Production Considerations

1. **Secrets Management**: Use sealed-secrets, external-secrets, or Vault
2. **TLS**: Enable TLS in ingress with cert-manager
3. **Monitoring**: Add Prometheus/Grafana stack
4. **Logging**: Configure centralized logging (EFK/Loki)
5. **Backup**: Configure PostgreSQL backups (pg_dump, Velero)
