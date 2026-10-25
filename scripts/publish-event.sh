#!/usr/bin/env bash
# Publish an OrderCreated (or custom) event to the orders EventBridge bus.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
EVENT_FILE="${1:-${ROOT}/events/order-created.json}"

if [[ ! -f "${EVENT_FILE}" ]]; then
  echo "Event file not found: ${EVENT_FILE}" >&2
  exit 1
fi

BUS_NAME="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='EventBusName'].OutputValue" \
  --output text)"

if [[ -z "${BUS_NAME}" || "${BUS_NAME}" == "None" ]]; then
  echo "Could not resolve EventBusName from stack ${STACK_NAME}." >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
sed "s/EVENT_BUS_NAME_PLACEHOLDER/${BUS_NAME}/g" "${EVENT_FILE}" > "${TMP}"

echo "==> Publishing event from ${EVENT_FILE}"
echo "    Event bus: ${BUS_NAME}"
aws events put-events \
  --region "${REGION}" \
  --entries "file://${TMP}" \
  --output json

echo "Done. Run scripts/verify-fanout.sh to check both queues."
