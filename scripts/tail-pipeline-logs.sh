#!/usr/bin/env bash
# Tail CloudWatch logs for the full OrderCreated path:
#   EventBridge TRACE (ingest → pattern match → SNS invoke)
#   + email/audit workers (queue_landed → fanout_consumed → worker_done)
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
SINCE="${SINCE:-5m}"

output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

BUS_LG="$(output EventBusLogGroupName)"
EMAIL_LG="$(output EmailWorkerLogGroupName)"
AUDIT_LG="$(output AuditWorkerLogGroupName)"

if [[ -z "${BUS_LG}" || "${BUS_LG}" == "None" ]]; then
  echo "Could not resolve EventBusLogGroupName from stack ${STACK_NAME}." >&2
  echo "Deploy first: ./scripts/deploy.sh" >&2
  exit 1
fi

echo "==> Pipeline logs (since ${SINCE}) · stack=${STACK_NAME} · region=${REGION}"
echo "    EventBridge TRACE : ${BUS_LG}"
echo "    Email worker      : ${EMAIL_LG}"
echo "    Audit worker      : ${AUDIT_LG}"
echo
echo "Look for stages:"
echo "  Event Ingested / Rule Matching Started / Rule Matched / No Rules Matched"
echo "  Invocation Started / Invocation Succeeded  (SNS fan-out)"
echo "  queue_landed / fanout_consumed / worker_done  (SQS → Lambda)"
echo
echo "Ctrl-C to stop."
echo

aws logs tail "${BUS_LG}" \
  --region "${REGION}" \
  --since "${SINCE}" \
  --follow \
  --format short &
PID_BUS=$!

aws logs tail "${EMAIL_LG}" \
  --region "${REGION}" \
  --since "${SINCE}" \
  --follow \
  --format short &
PID_EMAIL=$!

aws logs tail "${AUDIT_LG}" \
  --region "${REGION}" \
  --since "${SINCE}" \
  --follow \
  --format short &
PID_AUDIT=$!

trap 'kill ${PID_BUS} ${PID_EMAIL} ${PID_AUDIT} 2>/dev/null || true' EXIT INT TERM
wait
