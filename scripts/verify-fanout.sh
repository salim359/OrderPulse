#!/usr/bin/env bash
# Receive messages from Email and Audit queues to confirm SNS fan-out.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
WAIT_SECONDS="${WAIT_SECONDS:-3}"

get_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

EMAIL_URL="$(get_output EmailQueueUrl)"
AUDIT_URL="$(get_output AuditQueueUrl)"

echo "==> Waiting ${WAIT_SECONDS}s for delivery..."
sleep "${WAIT_SECONDS}"

receive_one() {
  local label="$1"
  local url="$2"
  echo
  echo "---- ${label} ----"
  local payload
  payload="$(aws sqs receive-message \
    --region "${REGION}" \
    --queue-url "${url}" \
    --max-number-of-messages 1 \
    --wait-time-seconds 5 \
    --message-attribute-names All \
    --attribute-names All \
    --output json)"

  if echo "${payload}" | jq -e '.Messages | length > 0' >/dev/null 2>&1; then
    echo "${payload}" | jq '.Messages[0] | {MessageId, Body: (.Body | fromjson? // .Body)}'
    local handle
    handle="$(echo "${payload}" | jq -r '.Messages[0].ReceiptHandle')"
    aws sqs delete-message \
      --region "${REGION}" \
      --queue-url "${url}" \
      --receipt-handle "${handle}" >/dev/null
    echo "(deleted message from ${label})"
  else
    echo "No message received on ${label}."
    echo "${payload}" | jq .
    return 1
  fi
}

ok=0
receive_one "EmailQueue" "${EMAIL_URL}" && ok=$((ok + 1)) || true
receive_one "AuditQueue" "${AUDIT_URL}" && ok=$((ok + 1)) || true

echo
if [[ "${ok}" -eq 2 ]]; then
  echo "Fan-out OK: both Email and Audit queues received the event."
else
  echo "Fan-out incomplete (${ok}/2 queues). Re-publish and retry, or check the EventBridge rule / SNS subscriptions." >&2
  exit 1
fi
