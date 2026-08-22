#!/usr/bin/env bash
# infrastructure/scripts/destroy.sh
#
# The reliable way to tear down this project's infrastructure.
# Terraform-native destroy-time provisioners can't safely guarantee
# ordering against unrelated resource trees (e.g. the VPC module has no
# dependency relationship with the EKS/ALB Controller resources), and
# cached auth tokens can expire during a long-running `terraform destroy`.
# This script does the ALB cleanup as an explicit, separate first step,
# with its own fresh credentials, before Terraform ever touches the VPC.
#
# Usage: ./scripts/destroy.sh   (run from infrastructure/terraform/)

set -euo pipefail

REGION="us-east-1"
CLUSTER_NAME="project-bedrock-cluster"

echo "=== Step 1: Delete Kubernetes Ingress objects (triggers ALB Controller cleanup) ==="
if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null; then
  kubectl delete ingress --all --all-namespaces --ignore-not-found=true --timeout=60s || true
else
  echo "Cluster not reachable (may already be gone) - skipping kubectl cleanup."
fi

echo "=== Step 2: Wait for AWS Load Balancers to fully deprovision ==="
for i in $(seq 1 20); do
  COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?contains(DNSName, 'k8s-')])" --output text 2>/dev/null || echo 0)
  if [ "$COUNT" = "0" ]; then
    echo "All ALBs cleared."
    break
  fi
  echo "Still waiting... ($i/20, $COUNT ALB(s) remaining)"
  sleep 15
done

echo "=== Step 3: Force-delete any leftover ALB Controller security groups ==="
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
if [ -n "${VPC_ID:-}" ]; then
  for SG in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" \
    --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true); do
    echo "Deleting leftover security group: $SG"
    aws ec2 delete-security-group --group-id "$SG" || echo "  (could not delete $SG yet, may need manual cleanup)"
  done
fi

echo "=== Step 4: Run terraform destroy ==="
terraform destroy

echo "=== Done ==="