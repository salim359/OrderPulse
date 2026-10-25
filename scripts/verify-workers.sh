#!/usr/bin/env bash
# After publishing an OrderCreated event, confirm Lambda workers wrote DynamoDB rows.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
ORDER_ID="${1:-}"
WAIT_SECONDS="${WAIT_SECONDS:-8}"

get_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

NOTIF_TABLE="$(get_output NotificationsTableName)"
AUDIT_TABLE="$(get_output AuditTableName)"

echo "==> Waiting ${WAIT_SECONDS}s for workers…"
sleep "${WAIT_SECONDS}"

if [[ -n "${ORDER_ID}" ]]; then
  echo "---- Notifications (orderId=${ORDER_ID}) ----"
  aws dynamodb query \
    --region "${REGION}" \
    --table-name "${NOTIF_TABLE}" \
    --index-name by-order \
    --key-condition-expression "orderId = :o" \
    --expression-attribute-values "{\":o\":{\"S\":\"${ORDER_ID}\"}}" \
    --output json | jq '.Items'

  echo "---- Audit trail (orderId=${ORDER_ID}) ----"
  aws dynamodb query \
    --region "${REGION}" \
    --table-name "${AUDIT_TABLE}" \
    --index-name by-order \
    --key-condition-expression "orderId = :o" \
    --expression-attribute-values "{\":o\":{\"S\":\"${ORDER_ID}\"}}" \
    --output json | jq '.Items'
else
  echo "---- Recent notifications (scan) ----"
  aws dynamodb scan --region "${REGION}" --table-name "${NOTIF_TABLE}" --limit 5 --output json \
    | jq '.Items'

  echo "---- Recent audit rows (scan) ----"
  aws dynamodb scan --region "${REGION}" --table-name "${AUDIT_TABLE}" --limit 5 --output json \
    | jq '.Items'
fi

echo
echo "Tip: ./scripts/verify-workers.sh order-1001"
