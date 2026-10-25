#!/usr/bin/env bash
# Deploy (or update) the notification-sys SAM stack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
SENDER_EMAIL="${SENDER_EMAIL:-orders@dailynonsensia.site}"
ALARM_EMAIL="${ALARM_EMAIL:-snoufa3@gmail.com}"
ENABLE_SES_TRACKING="${ENABLE_SES_TRACKING:-true}"

echo "==> Validating template"
sam validate --lint --template template.yaml

echo "==> Building TypeScript workers (tsc via sam build)"
sam build --template template.yaml

echo "==> Deploying stack: ${STACK_NAME} (${REGION})"
echo "    SenderEmail=${SENDER_EMAIL}"
echo "    AlarmEmail=${ALARM_EMAIL}"
echo "    EnableSesTracking=${ENABLE_SES_TRACKING}"
sam deploy \
  --template-file .aws-sam/build/template.yaml \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --resolve-s3 \
  --capabilities CAPABILITY_IAM \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "ProjectName=${STACK_NAME}" \
    "SenderEmail=${SENDER_EMAIL}" \
    "AlarmEmail=${ALARM_EMAIL}" \
    "EnableSesTracking=${ENABLE_SES_TRACKING}"

echo
echo "==> Stack outputs"
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
