#!/usr/bin/env bash
# Delete the CloudFormation/SAM stack and all notification-sys resources.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"

echo "==> Deleting stack: ${STACK_NAME} (${REGION})"
aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "==> Waiting for delete to complete..."
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Stack ${STACK_NAME} deleted. Event bus, SNS topic, queues, and rule are gone."
