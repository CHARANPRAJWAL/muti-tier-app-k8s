# Deploying a 3-Tier App on AWS EKS — End-to-End Production Guide

> **Goal:** Deploy the multi-tier-app (React + Node.js + PostgreSQL) on a real AWS EKS cluster with ALB Ingress, HPA, and Karpenter — following production practices while keeping costs at the bare minimum for learning.

---

## Table of Contents

> Use Notion's `/table of contents` block for navigation.

1. Architecture Overview
2. Cost Estimate (Budget-Friendly)
3. Prerequisites — Tool Installation
4. AWS Account Setup
5. Create the EKS Cluster with eksctl
6. Verify the Cluster
7. Install the AWS Load Balancer Controller (ALB)
8. Install Metrics Server (for HPA)
9. Install Karpenter (Cluster Autoscaler)
10. Prepare Application Manifests for EKS
11. Deploy the Application
12. Verify the Full Deployment
13. Test HPA Autoscaling
14. Test Karpenter Node Scaling
15. Production Best Practices Checklist
16. Teardown — Destroy Everything

---

## 1. Architecture Overview

```
                          Internet
                             │
                    ┌────────▼────────┐
                    │   AWS ALB        │  (Layer 7 Load Balancer)
                    │   Ingress        │
                    └────┬───────┬────┘
                         │       │
                    /    │       │  /api
                         │       │
               ┌─────────▼──┐ ┌─▼──────────┐
               │  Frontend   │ │  Backend    │
               │  (React)    │ │  (Node.js)  │
               │  2-10 pods  │ │  2-10 pods  │
               │  HPA scaled │ │  HPA scaled │
               └─────────────┘ └──────┬──────┘
                                      │
                               ┌──────▼──────┐
                               │  PostgreSQL  │
                               │  (1 pod+EBS) │
                               └─────────────┘

    Nodes managed by Karpenter (auto-provisions EC2 instances)
```

**What each AWS service does:**

| Component | AWS Service | Why |
|---|---|---|
| Kubernetes control plane | EKS | Managed masters, you don't maintain them |
| Worker nodes | EC2 (via Karpenter) | Run your pods |
| Load balancer | ALB (Application LB) | Routes HTTP traffic into the cluster |
| Persistent storage | EBS (gp3) | Database disk, survives pod restarts |
| Container images | Docker Hub (existing) | Your images are already pushed here |
| DNS (optional) | Route 53 | Map a domain to the ALB |
| IAM | IAM Roles for Service Accounts (IRSA) | Secure, least-privilege pod permissions |

---

## 2. Cost Estimate (Budget-Friendly)

Bare minimum for learning. **Destroy when not using.**

| Resource | Spec | Approx. Cost/hour |
|---|---|---|
| EKS Control Plane | 1 cluster | $0.10/hr (~$73/mo) |
| EC2 Nodes (2x t3.medium) | 2 vCPU, 4GB each | $0.0416/hr each |
| EBS Volume (gp3, 5Gi) | Database PVC | ~$0.40/mo |
| ALB | 1 load balancer | $0.0225/hr |
| NAT Gateway | 1 (single AZ) | $0.045/hr |
| **Total (running 24/7)** | | **~$150/mo** |
| **Total (4 hrs/day learning)** | | **~$25/mo** |

> **Key cost-saving moves we make in this guide:**
> - 2 nodes only (t3.medium) — smallest that works
> - Single NAT Gateway instead of one per AZ
> - Karpenter uses Spot instances for extra pods
> - **Tear down when not using** — this is the biggest saver

---

## 3. Prerequisites — Tool Installation

You need these tools on your local machine. Run all commands from your terminal.

### 3.1 AWS CLI v2

```bash
# macOS
brew install awscli

# Verify
aws --version
# Expected: aws-cli/2.x.x ...
```

### 3.2 eksctl (EKS cluster manager)

```bash
# macOS
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

# Verify
eksctl version
# Expected: 0.x.x or higher
```

**What is eksctl?** It's a CLI tool by Weaveworks that creates EKS clusters with one command. Behind the scenes it creates CloudFormation stacks for VPC, subnets, IAM roles, node groups, etc.

### 3.3 kubectl

```bash
# macOS
brew install kubectl

# Verify
kubectl version --client
```

### 3.4 Helm (Kubernetes package manager)

```bash
brew install helm

# Verify
helm version
```

**What is Helm?** Think of it like `npm` for Kubernetes. Instead of writing 20 YAML files to install something like the ALB controller, you run `helm install` and it pulls a pre-made chart with all the manifests.

### 3.5 jq (JSON processor — utility)

```bash
brew install jq
```

---

## 4. AWS Account Setup

### 4.1 Create an IAM User (if you don't have one)

Do NOT use your AWS root account. Create a dedicated IAM user.

1. Go to **AWS Console → IAM → Users → Create User**
2. Name: `eks-admin`
3. Attach policy: `AdministratorAccess` (for learning; restrict in real production)
4. Create access keys (CLI type)

### 4.2 Configure AWS CLI

```bash
aws configure --profile eks-admin
```

You'll be prompted for:
```
AWS Access Key ID:     <your-access-key>
AWS Secret Access Key: <your-secret-key>
Default region name:   us-east-1        # cheapest region, pick one close to you
Default output format: json
```

### 4.3 Verify access

```bash
aws sts get-caller-identity --profile=eks-admin
```

Expected output:
```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/eks-admin"
}
```

> **Why us-east-1?** It's typically the cheapest region and has all services available. Pick `ap-south-1` (Mumbai) if you're in India and want lower latency.

---

## 5. Create the EKS Cluster with eksctl

### 5.1 Set environment variables

Set these once. They're reused throughout the guide.

```bash
export CLUSTER_NAME="mtapp-cluster"
export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile=eks-admin)
export K8S_VERSION="1.31"

# Confirm
echo "Cluster: $CLUSTER_NAME | Region: $AWS_REGION | Account: $ACCOUNT_ID"
```

### 5.2 Create the cluster config file

Create a file called `eks-cluster.yaml` in your project root:

```bash
cat <<'EOF' > eks-cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: mtapp-cluster
  region: us-east-1
  version: "1.31"

# ---------- IAM / OIDC ----------
iam:
  withOIDC: true              # Required for IRSA (IAM Roles for Service Accounts)
                              # This lets pods assume IAM roles securely

# ---------- Addons ----------
addons:
  - name: vpc-cni             # AWS VPC networking for pods
    version: latest
    configurationValues: '{"env":{"ENABLE_PREFIX_DELEGATION":"true"}}'
  - name: coredns             # Cluster DNS
    version: latest
  - name: kube-proxy          # Network proxy on each node
    version: latest
  - name: aws-ebs-csi-driver  # Required for EBS PersistentVolumes
    version: latest
    wellKnownPolicies:
      ebsCSIController: true  # Auto-creates the IAM policy for EBS access

# ---------- Managed Node Group ----------
managedNodeGroups:
  - name: core-nodes
    instanceType: t3.medium   # 2 vCPU, 4GB RAM — smallest practical size
    desiredCapacity: 2        # Start with 2 nodes
    minSize: 2                # Never go below 2 (HA)
    maxSize: 2                # Fixed at 2 — Karpenter handles scaling beyond this
    volumeSize: 20            # 20GB root EBS per node
    volumeType: gp3           # gp3 is cheaper and faster than gp2
    amiFamily: AmazonLinux2023
    iam:
      withAddonPolicies:
        ebs: true             # Let nodes manage EBS volumes
    labels:
      role: core              # Label to identify these as the fixed node group
    tags:
      Environment: learning
      ManagedBy: eksctl

# ---------- CloudWatch Logging (minimal) ----------
cloudWatch:
  clusterLogging:
    enableTypes:
      - api                   # API server audit logs
      - authenticator         # Auth logs for debugging access issues
    # Note: Each log type costs money. Only enable what you need for learning.
EOF
```

**What each section does:**

| Section | Purpose |
|---|---|
| `iam.withOIDC` | Creates an OIDC provider so Kubernetes service accounts can assume IAM roles. This is called IRSA and is the production-standard way to give pods AWS permissions. |
| `addons.vpc-cni` | The networking plugin that gives each pod a real VPC IP address. `ENABLE_PREFIX_DELEGATION` allows more pods per node. |
| `addons.aws-ebs-csi-driver` | Required for PersistentVolumeClaims to create EBS volumes. Without this, your PostgreSQL PVC will stay in `Pending` state forever. |
| `managedNodeGroups` | Creates EC2 instances managed by EKS. We use 2 fixed nodes for the baseline. Karpenter adds more when needed. |
| `cloudWatch.clusterLogging` | Sends control plane logs to CloudWatch. Only enable `api` and `authenticator` to keep costs low. |

### 5.3 Create the cluster

```bash
eksctl create cluster -f eks-cluster.yaml --profile=eks-admin
```

> **This takes 15-20 minutes.** eksctl creates:
> - A VPC with public and private subnets across 2-3 AZs
> - An Internet Gateway and NAT Gateway
> - The EKS control plane
> - 2 EC2 instances (t3.medium) in an Auto Scaling Group
> - All necessary IAM roles and security groups
> - The OIDC provider for IRSA

### 5.4 Verify kubeconfig was set

eksctl automatically updates your `~/.kube/config`:

```bash
kubectl config current-context
# Expected: <your-iam-user>@mtapp-cluster.us-east-1.eksctl.io

kubectl get nodes
# Expected: 2 nodes in Ready state
```

---

## 6. Verify the Cluster

```bash
# Nodes
kubectl get nodes -o wide

# System pods
kubectl get pods -n kube-system

# EBS CSI driver running?
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# Storage class available?
kubectl get storageclass
# You should see gp2 (default). We'll create gp3 next.
```

### 6.1 Create a gp3 StorageClass

EKS comes with `gp2` as default. gp3 is cheaper and faster:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
  encrypted: "true"          # Encrypt all EBS volumes at rest
reclaimPolicy: Delete         # Auto-delete EBS when PVC is deleted (saves cost)
volumeBindingMode: WaitForFirstConsumer  # Only create EBS in the AZ where the pod lands
allowVolumeExpansion: true    # Allow resizing PVCs without recreation
EOF
```

Remove the default annotation from gp2:

```bash
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class-
```

**Why WaitForFirstConsumer?** EBS volumes are AZ-specific. If the volume is created in us-east-1a but the pod is scheduled in us-east-1b, it can't attach. `WaitForFirstConsumer` delays volume creation until the pod is scheduled, ensuring they're in the same AZ.

---

## 7. Install the AWS Load Balancer Controller (ALB)

The **AWS Load Balancer Controller** watches for Kubernetes `Ingress` resources and creates real AWS Application Load Balancers.

### 7.1 Why ALB instead of NGINX Ingress?

| Feature | NGINX Ingress | AWS ALB |
|---|---|---|
| Runs as | Pods inside your cluster (uses your node resources) | Managed AWS service (no pods needed) |
| Scaling | You scale the NGINX pods | AWS scales automatically |
| Cost | Free (but uses node CPU/RAM) | Pay per ALB (~$16/mo + traffic) |
| SSL termination | You manage certs with cert-manager | AWS Certificate Manager (free certs) |
| WAF integration | Manual | Native with AWS WAF |
| Production standard on AWS | Less common | Industry standard |

**For EKS, ALB is the production standard.**

### 7.2 Create IAM Policy for the controller

The ALB controller needs permission to create/manage load balancers in your AWS account:

```bash
# Download the IAM policy document
curl -o alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json

# Create the IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-iam-policy.json \
  --profile=eks-admin
```

### 7.3 Create a Service Account with IRSA

This links a Kubernetes service account to an IAM role. The ALB controller pod uses this service account, and through IRSA, it gets AWS permissions without needing access keys.

```bash
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --profile=eks-admin
```

**What is IRSA?** Traditional approach: store AWS credentials as Kubernetes secrets (bad — secrets can leak). IRSA approach: the pod's service account is linked to an IAM role via OIDC federation. AWS STS issues temporary credentials automatically. No secrets stored anywhere.

### 7.4 Install via Helm

```bash
# Add the EKS Helm chart repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text --profile=eks-admin)
```

### 7.5 Verify it's running

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller

# Expected: READY 2/2
```

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## 8. Install Metrics Server (for HPA)

HPA needs real-time CPU and memory metrics from pods. Metrics Server provides this.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verify:

```bash
# Wait 60 seconds for metrics to start collecting, then:
kubectl top nodes
kubectl top pods -A
```

If `kubectl top nodes` returns actual numbers (not errors), the metrics server is working.

---

## 9. Install Karpenter (Cluster Autoscaler)

### 9.1 What is Karpenter? Why not Cluster Autoscaler?

| Feature | Cluster Autoscaler | Karpenter |
|---|---|---|
| Developed by | Kubernetes SIG | AWS (open source) |
| How it works | Scales existing Auto Scaling Groups | Directly provisions EC2 instances |
| Speed | 3-5 minutes to add a node | 30-90 seconds to add a node |
| Instance selection | Fixed instance type per node group | Picks the best instance type from a list on the fly |
| Spot support | Via separate node groups | Native, automatic fallback to on-demand |
| Production standard on EKS | Being replaced | Recommended by AWS |

**Karpenter is the modern choice for EKS.** It's faster, smarter about instance selection, and handles Spot interruptions gracefully.

### 9.2 Tag subnets and security groups

Karpenter needs to know which subnets and security groups to use for new nodes. eksctl already tags subnets, but we need to add Karpenter-specific tags:

```bash
# Get the VPC ID
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text --profile=eks-admin)

# Tag private subnets for Karpenter
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text --profile=eks-admin)

for subnet in $PRIVATE_SUBNETS; do
  aws ec2 create-tags --resources $subnet \
    --tags Key=karpenter.sh/discovery,Value=$CLUSTER_NAME --profile=eks-admin
done

# Tag the cluster security group for Karpenter
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text --profile=eks-admin)

aws ec2 create-tags --resources $CLUSTER_SG \
  --tags Key=karpenter.sh/discovery,Value=$CLUSTER_NAME --profile=eks-admin

echo "Tagged subnets: $PRIVATE_SUBNETS"
echo "Tagged security group: $CLUSTER_SG"
```

### 9.3 Create Karpenter IAM Roles

Karpenter needs two IAM roles:
1. **Controller role** — for the Karpenter pod itself (to launch EC2 instances)
2. **Node role** — for the EC2 instances that Karpenter creates (so they can join the cluster)

**Create the Node IAM Role**

```bash
# Create the role
aws iam create-role \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }' \
  --profile=eks-admin

# Attach required policies
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy --profile=eks-admin

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy --profile=eks-admin

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly --profile=eks-admin

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore --profile=eks-admin

# Create an instance profile (required for EC2)
aws iam create-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" --profile=eks-admin
aws iam add-role-to-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --profile=eks-admin
```

**Allow Karpenter nodes to join the cluster**

```bash
# Map the Karpenter node role in aws-auth ConfigMap
eksctl create iamidentitymapping \
  --cluster $CLUSTER_NAME \
  --arn "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --username system:node:{{EC2PrivateDNSName}} \
  --group system:bootstrappers \
  --group system:nodes \
  --profile=eks-admin
```

**Create the Controller IAM Policy**

The controller needs permissions to launch/terminate EC2 instances. Create the policy first, then the role.

```bash
cat <<EOF > karpenter-controller-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Karpenter",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DeleteLaunchTemplate",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "iam:AddRoleToInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:PassRole",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "pricing:GetProducts",
        "ssm:GetParameter",
        "eks:DescribeCluster"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ScopedTermination",
      "Effect": "Allow",
      "Action": ["ec2:TerminateInstances"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --policy-document file://karpenter-controller-policy.json \
  --profile=eks-admin
```

**Create the Controller IAM Role (via IRSA)**

Now create the service account and role, attaching the policy we just created:

```bash
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --name=karpenter \
  --namespace=kube-system \
  --role-name="KarpenterControllerRole-${CLUSTER_NAME}" \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --approve \
  --profile=eks-admin
```

### 9.4 Install Karpenter via Helm

```bash
# Set the Karpenter version
export KARPENTER_VERSION="1.1.1"

helm registry logout public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_VERSION" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueueName=${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set controller.resources.requests.cpu=0.5 \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

### 9.5 Verify Karpenter is running

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
# Expected: 2 pods (controller + webhook) in Running state

kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=20
```

### 9.6 Create a Karpenter NodePool and EC2NodeClass

The **NodePool** defines scaling rules. The **EC2NodeClass** defines what kind of EC2 instances to launch.

```bash
kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        role: karpenter           # Distinguish from core-nodes
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        # Budget-friendly: use t-series (burstable) and small sizes
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "m"]      # t3.medium, m5.large, etc.
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["small", "medium", "large"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]  # Prefer Spot (60-90% cheaper)
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]

  # Limits — prevent runaway scaling from blowing your AWS bill
  limits:
    cpu: "16"                     # Max 16 total vCPUs across all Karpenter nodes
    memory: "32Gi"                # Max 32GB total RAM

  # Disruption — consolidate underutilized nodes to save cost
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s         # Remove empty nodes after 60s
    budgets:
      - nodes: "20%"             # Don't disrupt more than 20% of nodes at once
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest        # Amazon Linux 2023 — latest EKS-optimized AMI
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: mtapp-cluster
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: mtapp-cluster
  instanceProfile: "KarpenterNodeInstanceProfile-mtapp-cluster"
  tags:
    Environment: learning
    ManagedBy: karpenter
EOF
```

**Key decisions explained:**

| Setting | Value | Why |
|---|---|---|
| `capacity-type: [spot, on-demand]` | Spot preferred | Spot instances are 60-90% cheaper. Karpenter auto-falls back to on-demand if Spot isn't available. |
| `limits.cpu: "16"` | Max 16 vCPUs | Prevents a misconfigured HPA from scaling to 100 nodes and costing you thousands. |
| `consolidationPolicy` | WhenEmptyOrUnderutilized | Automatically removes nodes when they're not needed. Saves money. |
| `instance-category: [t, m]` | Burstable + general | t3 instances are cheapest for bursty workloads. m5/m6i as fallback. |

---

## 10. Prepare Application Manifests for EKS

Your existing manifests need a few changes for EKS. Here's what changes and why.

### 10.1 Changes Summary

| What | Kind Local (Current) | EKS (New) | Why |
|---|---|---|---|
| Ingress class | `nginx` | `alb` | Using AWS ALB instead of NGINX |
| Ingress annotations | nginx-specific | ALB-specific | ALB controller needs its own annotations |
| PVC StorageClass | (default) | `gp3` | Use cheaper, encrypted EBS gp3 |
| Network Policy | ingress-nginx namespace | (update) | ALB traffic comes from a different path |
| Secrets | plaintext stringData | Same for learning (use Secrets Manager in prod) | Noted in best practices |

### 10.2 Create EKS-specific Ingress

Create a new file `kubernetes-eks/ingress/ingress-alb.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: mtapp
  labels:
    app.kubernetes.io/name: multi-tier-app
  annotations:
    # Tell Kubernetes this is for the ALB controller
    kubernetes.io/ingress.class: alb

    # internet-facing = public ALB with a public DNS name
    # (vs "internal" which is only accessible inside the VPC)
    alb.ingress.kubernetes.io/scheme: internet-facing

    # ip mode = ALB sends traffic directly to pod IPs (faster, no extra hop)
    # vs "instance" mode which goes through NodePort (adds latency)
    alb.ingress.kubernetes.io/target-type: ip

    # Health check settings for ALB target groups
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "15"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "5"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"

    # Group multiple ingress rules into a single ALB (saves cost — one ALB instead of many)
    alb.ingress.kubernetes.io/group.name: mtapp

    # Listen on port 80 (add 443 later with ACM certificate)
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'

    # Tags on the ALB for cost tracking
    alb.ingress.kubernetes.io/tags: Environment=learning,App=mtapp
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: backend-service
                port:
                  number: 5000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

### 10.3 Update PVC to use gp3

Update `kubernetes-eks/database/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: mtapp
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: database
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3           # <-- ADD THIS LINE
  resources:
    requests:
      storage: 5Gi
```

### 10.4 Update Network Policies for ALB

ALB traffic arrives at pod IPs directly (because we used `target-type: ip`). This means the traffic source is the ALB's ENI, not a namespace. Update the backend and frontend network policies.

Replace `kubernetes-eks/backend/networkpolicy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-network-policy
  namespace: mtapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: backend
  policyTypes:
    - Ingress
  ingress:
    # Allow traffic from frontend pods
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: frontend
      ports:
        - protocol: TCP
          port: 5000
    # Allow traffic from ALB (VPC CIDR)
    # The ALB lives in your VPC, so allow the VPC CIDR range
    - from:
        - ipBlock:
            cidr: 192.168.0.0/16    # Adjust to your VPC CIDR
      ports:
        - protocol: TCP
          port: 5000
```

Replace `kubernetes-eks/frontend/networkpolicy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-network-policy
  namespace: mtapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: frontend
  policyTypes:
    - Ingress
  ingress:
    # Allow traffic from ALB (VPC CIDR)
    - from:
        - ipBlock:
            cidr: 192.168.0.0/16    # Adjust to your VPC CIDR
      ports:
        - protocol: TCP
          port: 3000
```

> **Find your actual VPC CIDR:**
> ```bash
> aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].CidrBlock' --output text --profile=eks-admin
> ```
> Replace `192.168.0.0/16` with the output.

---

## 11. Deploy the Application

Now deploy everything step by step.

### 11.1 Create Namespace

```bash
kubectl apply -f kubernetes-eks/base/namespace.yaml

# Verify
kubectl get namespace mtapp
```

### 11.2 Deploy Config and Secrets

```bash
kubectl apply -f kubernetes-eks/config/configmap.yaml
kubectl apply -f kubernetes-eks/config/secret.yaml

# Verify
kubectl get configmap,secret -n mtapp
```

### 11.3 Deploy Database

```bash
kubectl apply -f kubernetes-eks/database/

# This creates: PVC, ConfigMap (init.sql), Deployment, Service, NetworkPolicy
```

Wait for PostgreSQL to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=postgres -n mtapp --timeout=120s
```

Verify the database:

```bash
# Check PVC is bound to an EBS volume
kubectl get pvc -n mtapp
# STATUS should be "Bound"

# Check pod is running
kubectl get pods -n mtapp -l app.kubernetes.io/name=postgres

# Check logs
kubectl logs -n mtapp -l app.kubernetes.io/name=postgres --tail=20
```

### 11.4 Deploy Backend

```bash
kubectl apply -f kubernetes-eks/backend/

# Wait for rollout
kubectl rollout status deployment/backend -n mtapp --timeout=120s
```

Verify:

```bash
kubectl get pods -n mtapp -l app.kubernetes.io/name=backend
# Expected: 2/2 Running

# Test the health endpoint from inside the cluster
kubectl run curl-test --rm -it --image=curlimages/curl -n mtapp -- \
  curl -s http://backend-service:5000/api/health
# Expected: {"status":"OK","message":"Server is running"}
```

### 11.5 Deploy Frontend

```bash
kubectl apply -f kubernetes-eks/frontend/

kubectl rollout status deployment/frontend -n mtapp --timeout=120s
```

### 11.6 Deploy ALB Ingress

```bash
# Use the EKS-specific ALB ingress, NOT the nginx one
kubectl apply -f kubernetes-eks/ingress/ingress-alb.yaml
```

Wait for the ALB to be provisioned:

```bash
# This takes 2-3 minutes. Watch the address field:
kubectl get ingress -n mtapp -w

# Once ADDRESS shows a DNS name like:
# k8s-mtapp-xxxxxxxx-yyyyyyyyyy.us-east-1.elb.amazonaws.com
# Press Ctrl+C
```

Get the ALB URL:

```bash
ALB_URL=$(kubectl get ingress -n mtapp app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Application URL: http://$ALB_URL"
```

### 11.7 Test the Application

```bash
# Health check
curl -s http://$ALB_URL/api/health | jq

# Get users
curl -s http://$ALB_URL/api/users | jq

# Open frontend in browser
open http://$ALB_URL
```

---

## 12. Verify the Full Deployment

Run this checklist to make sure everything is working:

```bash
echo "=== Namespace ==="
kubectl get namespace mtapp

echo -e "\n=== Pods ==="
kubectl get pods -n mtapp -o wide

echo -e "\n=== Services ==="
kubectl get svc -n mtapp

echo -e "\n=== Ingress ==="
kubectl get ingress -n mtapp

echo -e "\n=== HPA ==="
kubectl get hpa -n mtapp

echo -e "\n=== PVC ==="
kubectl get pvc -n mtapp

echo -e "\n=== Network Policies ==="
kubectl get networkpolicy -n mtapp

echo -e "\n=== Nodes ==="
kubectl get nodes -o wide

echo -e "\n=== Karpenter NodePool ==="
kubectl get nodepool

echo -e "\n=== Resource Usage ==="
kubectl top pods -n mtapp
kubectl top nodes
```

Expected state:
```
PODS:         5 running (2 backend, 2 frontend, 1 postgres)
SERVICES:     3 ClusterIP (backend, frontend, postgres)
INGRESS:      1 with ALB address
HPA:          2 (backend-hpa, frontend-hpa) with metrics visible
PVC:          1 Bound (5Gi gp3)
NODES:        2 (core-nodes from eksctl)
```

---

## 13. Test HPA Autoscaling

### 13.1 Watch HPA in one terminal

```bash
kubectl get hpa -n mtapp -w
```

### 13.2 Generate load in another terminal

```bash
# Create a load generator pod
kubectl run load-generator -n mtapp \
  --image=busybox:1.36 \
  --restart=Never \
  -- /bin/sh -c "
    while true; do
      for i in \$(seq 1 100); do
        wget -q -O /dev/null http://backend-service:5000/api/health &
      done
      wait
    done
  "
```

### 13.3 Observe

After 1-2 minutes, you should see:
- HPA `TARGETS` column showing increasing CPU percentages
- `REPLICAS` column increasing from 2 toward 10
- New pods appearing: `kubectl get pods -n mtapp -l app.kubernetes.io/name=backend -w`

### 13.4 Clean up load generator

```bash
kubectl delete pod load-generator -n mtapp
```

After 5-10 minutes of cooldown, HPA will scale pods back down to 2.

---

## 14. Test Karpenter Node Scaling

HPA scales pods. But if there aren't enough nodes to place those pods, they'll be stuck in `Pending`. That's where Karpenter kicks in.

### 14.1 Force pod demand beyond current node capacity

```bash
# Create a deployment that requests more resources than 2 nodes can handle
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: mtapp
spec:
  replicas: 10
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
EOF
```

### 14.2 Watch Karpenter provision nodes

```bash
# In terminal 1 — watch pods (some will be Pending, then Running)
kubectl get pods -n mtapp -l app=inflate -w

# In terminal 2 — watch nodes (new ones appear)
kubectl get nodes -w

# In terminal 3 — watch Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f --tail=50
```

You should see:
1. Pods go `Pending` (not enough resources on 2 nodes)
2. Karpenter logs: `launched instance` (provisioning a new EC2 — likely Spot)
3. A new node appears in `kubectl get nodes` within 60-90 seconds
4. Pending pods move to `Running`

### 14.3 Clean up

```bash
kubectl delete deployment inflate -n mtapp
```

After 60 seconds, Karpenter's consolidation policy will detect the empty node and terminate it. Watch with:

```bash
kubectl get nodes -w
# The Karpenter-provisioned node will disappear
```

---

## 15. Production Best Practices Checklist

These are organized from **most critical** to **nice to have**. For learning, focus on understanding what each one does. In a real production cluster, implement all of them.

### 15.1 Secrets Management (Critical)

**Problem:** Your `secret.yaml` has passwords in plain text, committed to Git.

**Production solution — AWS Secrets Manager + External Secrets Operator:**

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

```bash
# Store secrets in AWS Secrets Manager
aws secretsmanager create-secret \
  --name mtapp/db-credentials \
  --secret-string '{"POSTGRES_USER":"appuser","POSTGRES_PASSWORD":"<strong-random-password>"}' \
  --profile=eks-admin
```

```yaml
# ExternalSecret that syncs from AWS to Kubernetes
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: mtapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-credentials
  data:
    - secretKey: POSTGRES_USER
      remoteRef:
        key: mtapp/db-credentials
        property: POSTGRES_USER
    - secretKey: POSTGRES_PASSWORD
      remoteRef:
        key: mtapp/db-credentials
        property: POSTGRES_PASSWORD
```

### 15.2 HTTPS / TLS (Critical)

**Problem:** Your app is HTTP-only. Passwords and data travel in plain text.

**Production solution — AWS Certificate Manager (free) + ALB HTTPS:**

```bash
# Step 1: Request a free certificate (you need a domain)
aws acm request-certificate \
  --domain-name "app.yourdomain.com" \
  --validation-method DNS \
  --profile=eks-admin
# Follow the DNS validation steps in ACM console
```

```yaml
# Step 2: Update your ALB ingress annotations
annotations:
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:ACCOUNT:certificate/CERT-ID
```

This gives you free, auto-renewing SSL certificates — no cert-manager needed.

### 15.3 Database in Production (Critical)

**Problem:** Running PostgreSQL in a pod means data loss risk, no automated backups, no replication.

**Production solution — Use Amazon RDS:**

| Aspect | Pod-based PostgreSQL | Amazon RDS |
|---|---|---|
| Backups | Manual | Automated daily + point-in-time recovery |
| High availability | None (single pod) | Multi-AZ standby replica |
| Scaling | Resize PVC manually | Push-button vertical scaling |
| Patching | You do it | AWS does it |
| Cost | ~$0 (uses node resources) | ~$13/mo (db.t3.micro) |

```bash
# Budget option: Single-AZ, db.t3.micro
aws rds create-db-instance \
  --db-instance-identifier mtapp-postgres \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15 \
  --master-username appuser \
  --master-user-password "<strong-password>" \
  --allocated-storage 20 \
  --vpc-security-group-ids $DB_SG_ID \
  --db-subnet-group-name $DB_SUBNET_GROUP \
  --no-multi-az \
  --storage-type gp3 \
  --profile=eks-admin
```

Then update your ConfigMap:
```yaml
DB_HOST: "mtapp-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
```

### 15.4 Resource Requests & Limits (Important)

Your current manifests already have these set — good. Here's the reasoning:

```yaml
resources:
  requests:               # Scheduler uses this to place pods on nodes
    cpu: "100m"           # "I need at least 0.1 CPU cores"
    memory: "128Mi"       # "I need at least 128MB RAM"
  limits:                 # Hard ceiling — pod gets killed if it exceeds memory
    cpu: "500m"           # "Never use more than 0.5 CPU cores"
    memory: "256Mi"       # "Kill me if I use more than 256MB" (OOMKilled)
```

**Production tuning tip:** Run the app under load, observe actual usage with `kubectl top pods`, then set:
- `requests` = P50 (median) usage
- `limits` = P99 usage + 20% headroom

### 15.5 Pod Disruption Budgets (Important)

Ensure minimum availability during node drains, upgrades, and Karpenter consolidation:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: mtapp
spec:
  minAvailable: 1              # At least 1 backend pod must always be running
  selector:
    matchLabels:
      app.kubernetes.io/name: backend
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: mtapp
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: frontend
```

### 15.6 Liveness & Readiness Probes (Already Done)

Your manifests already have these. Here's why both matter:

- **Readiness probe:** "Is this pod ready to receive traffic?" If it fails, the pod is removed from the Service's endpoint list (no traffic sent to it). Used during startup and temporary issues.
- **Liveness probe:** "Is this pod alive?" If it fails, Kubernetes restarts the pod. Used to detect deadlocks/hangs.

### 15.7 Observability (Important)

For production, you need logs, metrics, and traces.

**Budget-friendly option — CloudWatch Container Insights:**

```bash
# Install CloudWatch observability addon
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability \
  --profile=eks-admin
```

This gives you:
- Container logs in CloudWatch Logs
- CPU/memory/network metrics in CloudWatch Metrics
- Pre-built dashboards

**Full production option (more powerful, more complex):**
- **Metrics:** Prometheus + Grafana (via `kube-prometheus-stack` Helm chart)
- **Logs:** Fluent Bit → CloudWatch or Loki
- **Traces:** AWS X-Ray or OpenTelemetry

### 15.8 Image Security (Important)

```yaml
# In your deployments, NEVER use :latest in production
# Pin to a specific tag or digest
image: charanprajwal001/backend-app:v1.0.0    # Good
image: charanprajwal001/backend-app:latest     # Bad — you can't tell what's running

# Use imagePullPolicy: IfNotPresent (not Always) with pinned tags
imagePullPolicy: IfNotPresent
```

**Consider using Amazon ECR** instead of Docker Hub:
```bash
# Create ECR repositories
aws ecr create-repository --repository-name mtapp/backend --profile=eks-admin
aws ecr create-repository --repository-name mtapp/frontend --profile=eks-admin

# Login and push
aws ecr get-login-password --profile=eks-admin | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker tag backend-app:latest $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mtapp/backend:v1.0.0
docker push $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mtapp/backend:v1.0.0
```

ECR benefits: private, no rate limits, image scanning, closer to your cluster (faster pulls).

### 15.9 Namespace Resource Quotas (Good Practice)

Prevent one namespace from consuming all cluster resources:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mtapp-quota
  namespace: mtapp
spec:
  hard:
    requests.cpu: "4"          # Total CPU requests across all pods in namespace
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    pods: "30"                 # Max 30 pods in this namespace
    persistentvolumeclaims: "5"
```

### 15.10 Network Security (Good Practice)

Your existing NetworkPolicies are solid. Additional EKS-specific hardening:

```bash
# Enable VPC CNI Network Policy enforcement (if not already enabled)
kubectl set env daemonset aws-node -n kube-system ENABLE_NETWORK_POLICY=true
```

### 15.11 Cluster Upgrades (Operational)

EKS versions reach end-of-life. Plan upgrades:

```bash
# Check current version
kubectl version --short

# Check available versions
aws eks describe-addon-versions --kubernetes-version 1.32 --query 'addons[0].addonVersions[0]' --profile=eks-admin

# Upgrade (control plane first, then nodes)
eksctl upgrade cluster --name $CLUSTER_NAME --version 1.32 --approve --profile=eks-admin
eksctl upgrade nodegroup --name core-nodes --cluster $CLUSTER_NAME --profile=eks-admin
```

---

## 16. Teardown — Destroy Everything

**Run this when you're done for the day to stop billing.**

### Step 1: Delete application resources

```bash
kubectl delete namespace mtapp
```

This deletes all pods, services, ingress (which deletes the ALB), PVCs (which deletes EBS volumes).

### Step 2: Verify ALB is deleted

```bash
# The ALB should be gone. If not, delete manually:
aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `mtapp`)].LoadBalancerArn' --output text --profile=eks-admin
# If any show up:
# aws elbv2 delete-load-balancer --load-balancer-arn <arn>
```

### Step 3: Delete the Karpenter resources

```bash
kubectl delete nodepool default
kubectl delete ec2nodeclass default
helm uninstall karpenter -n kube-system
```

### Step 4: Delete the cluster

```bash
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION --profile=eks-admin
```

> This takes 10-15 minutes and deletes: EKS cluster, node group, VPC, subnets, NAT gateway, CloudFormation stacks.

### Step 5: Clean up IAM resources

```bash
# Delete Karpenter IAM resources
aws iam remove-role-from-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --profile=eks-admin
aws iam delete-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" --profile=eks-admin

for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --policy-arn "arn:aws:iam::aws:policy/$policy" --profile=eks-admin
done
aws iam delete-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --profile=eks-admin

# Delete custom policies
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" --profile=eks-admin
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" --profile=eks-admin
```

### Step 6: Verify nothing is left

```bash
# Check for any remaining EKS clusters
aws eks list-clusters --profile=eks-admin

# Check for orphaned load balancers
aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerName' --profile=eks-admin

# Check for orphaned EBS volumes
aws ec2 describe-volumes --filters Name=tag:Environment,Values=learning --query 'Volumes[*].VolumeId' --profile=eks-admin

# Check for running EC2 instances
aws ec2 describe-instances --filters Name=tag:Environment,Values=learning Name=instance-state-name,Values=running --query 'Reservations[*].Instances[*].InstanceId' --profile=eks-admin
```

---

## Quick Reference — Commands You'll Use Daily

```bash
# Connect to cluster (if kubeconfig expires)
aws eks update-kubeconfig --name mtapp-cluster --region us-east-1 --profile=eks-admin

# View everything in the app namespace
kubectl get all -n mtapp

# Watch pods in real time
kubectl get pods -n mtapp -w

# View pod logs
kubectl logs -n mtapp -l app.kubernetes.io/name=backend --tail=50 -f

# Shell into a pod for debugging
kubectl exec -it -n mtapp deploy/backend -- /bin/sh

# Check HPA status
kubectl get hpa -n mtapp

# Check Karpenter node pool
kubectl get nodepool

# View cluster events (useful for debugging)
kubectl get events -n mtapp --sort-by='.lastTimestamp'

# Port-forward for direct access (bypasses ALB)
kubectl port-forward -n mtapp svc/backend-service 5000:5000
kubectl port-forward -n mtapp svc/frontend-service 3000:80
```
