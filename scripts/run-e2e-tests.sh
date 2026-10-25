#!/usr/bin/env bash
# OrderPulse end-to-end acceptance tests against the live AWS stack.
# Usage:
#   ./scripts/run-e2e-tests.sh           # run all
#   ./scripts/run-e2e-tests.sh E2E-01    # run one scenario
#   RECIPIENT=you@example.com ./scripts/run-e2e-tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_NAME="${STACK_NAME:-notification-sys}"
RECIPIENT="${RECIPIENT:-snoufa3@gmail.com}"
WAIT_SECONDS="${WAIT_SECONDS:-12}"
FILTER_ONLY="${1:-}"

PASS=0
FAIL=0
SKIP=0
RESULTS=()

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); RESULTS+=("${GREEN}PASS${RESET}  $1"); log "  ${GREEN}✔${RESET} $2"; }
fail() { FAIL=$((FAIL + 1)); RESULTS+=("${RED}FAIL${RESET}  $1"); log "  ${RED}✖${RESET} $2"; }
skip() { SKIP=$((SKIP + 1)); RESULTS+=("${YELLOW}SKIP${RESET}  $1"); log "  ${YELLOW}↷${RESET} $2"; }

require_stack() {
  BUS_NAME="$(get_output EventBusName)"
  NOTIF_TABLE="$(get_output NotificationsTableName)"
  AUDIT_TABLE="$(get_output AuditTableName)"
  EMAIL_DLQ="$(get_output EmailQueueDLQUrl)"
  AUDIT_DLQ="$(get_output AuditQueueDLQUrl)"
  EB_DLQ="$(get_output EventBridgeDLQUrl)"
  SENDER="$(get_output SenderEmail)"
  CONFIG_SET="$(get_output SesConfigurationSetName || true)"
  [[ -n "${BUS_NAME}" && "${BUS_NAME}" != "None" ]] || { echo "Stack ${STACK_NAME} not found / missing outputs" >&2; exit 1; }
}

new_order_id() {
  echo "e2e-${1}-$(date +%s)-${RANDOM}"
}

put_event() {
  local detail_type="$1"
  local detail_json="$2"
  local bus="${3:-$BUS_NAME}"
  aws events put-events \
    --region "${REGION}" \
    --entries "[{
      \"EventBusName\": \"${bus}\",
      \"Source\": \"demo.orders\",
      \"DetailType\": \"${detail_type}\",
      \"Detail\": $(jq -c -n --argjson d "${detail_json}" '$d | @json')
    }]" \
    --output json
}

put_event_source() {
  local source="$1"
  local detail_type="$2"
  local detail_json="$3"
  aws events put-events \
    --region "${REGION}" \
    --entries "[{
      \"EventBusName\": \"${BUS_NAME}\",
      \"Source\": \"${source}\",
      \"DetailType\": \"${detail_type}\",
      \"Detail\": $(jq -c -n --argjson d "${detail_json}" '$d | @json')
    }]" \
    --output json
}

query_by_order() {
  local table="$1"
  local order_id="$2"
  aws dynamodb query \
    --region "${REGION}" \
    --table-name "${table}" \
    --index-name by-order \
    --key-condition-expression "orderId = :o" \
    --expression-attribute-values "{\":o\":{\"S\":\"${order_id}\"}}" \
    --output json
}

wait_for_pair() {
  local order_id="$1"
  local min_n="${2:-1}"
  local deadline=$((SECONDS + WAIT_SECONDS + 8))
  local n_count=0 a_count=0
  while (( SECONDS < deadline )); do
    n_count="$(query_by_order "${NOTIF_TABLE}" "${order_id}" | jq '.Items | length')"
    a_count="$(query_by_order "${AUDIT_TABLE}" "${order_id}" | jq '.Items | length')"
    if (( n_count >= min_n && a_count >= min_n )); then
      echo "${n_count} ${a_count}"
      return 0
    fi
    sleep 1
  done
  echo "${n_count} ${a_count}"
  return 1
}

queue_visible() {
  local url="$1"
  aws sqs get-queue-attributes \
    --region "${REGION}" \
    --queue-url "${url}" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes' --output json
}

notif_field() {
  local order_id="$1" field="$2"
  query_by_order "${NOTIF_TABLE}" "${order_id}" \
    | jq -r --arg f "${field}" '.Items[0][$f].S // .Items[0][$f].N // empty'
}

audit_field() {
  local order_id="$1" field="$2"
  query_by_order "${AUDIT_TABLE}" "${order_id}" \
    | jq -r --arg f "${field}" '.Items[0][$f].S // empty'
}

run_scenario() {
  local id="$1"
  if [[ -n "${FILTER_ONLY}" && "${FILTER_ONLY}" != "${id}" ]]; then
    return 0
  fi
  log ""
  log "${DIM}── ${id} ──${RESET}"
  "$2"
}

# ─── Scenarios ───────────────────────────────────────────────────────────────

scenario_e2e_01() {
  local oid; oid="$(new_order_id created)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerId:"cust-e2e",customerEmail:$e,totalAmount:49.98,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-01 "OrderCreated did not produce notification + audit for ${oid}"
    return
  fi
  local status subject action cfg ses
  status="$(notif_field "${oid}" status)"
  subject="$(notif_field "${oid}" subject)"
  action="$(audit_field "${oid}" action)"
  cfg="$(notif_field "${oid}" configurationSet)"
  ses="$(notif_field "${oid}" sesMessageId)"
  if [[ "${status}" == "sent" && "${subject}" == "Order confirmed: ${oid}" \
     && "${action}" == "ORDER_CREATED_RECORDED" && -n "${ses}" ]]; then
    ok E2E-01 "OrderCreated → SES sent (${ses:0:20}…) + audit; configSet=${cfg:-none}"
  else
    fail E2E-01 "unexpected status=${status} subject=${subject} action=${action} ses=${ses}"
  fi
}

scenario_e2e_02() {
  local oid; oid="$(new_order_id cancelled)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:20,currency:"USD",reason:"customer_request"}')"
  put_event "OrderCancelled" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-02 "OrderCancelled did not produce worker rows for ${oid}"
    return
  fi
  local status subject action
  status="$(notif_field "${oid}" status)"
  subject="$(notif_field "${oid}" subject)"
  action="$(audit_field "${oid}" action)"
  if [[ "${status}" == "sent" && "${subject}" == "Order cancelled: ${oid}" \
     && "${action}" == "ORDER_CANCELLED_RECORDED" ]]; then
    ok E2E-02 "OrderCancelled → email + ORDER_CANCELLED_RECORDED"
  else
    fail E2E-02 "status=${status} subject=${subject} action=${action}"
  fi
}

scenario_e2e_03() {
  local oid; oid="$(new_order_id payfail)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:99.5,currency:"USD",failureCode:"card_declined"}')"
  put_event "PaymentFailed" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-03 "PaymentFailed did not produce worker rows for ${oid}"
    return
  fi
  local status subject action
  status="$(notif_field "${oid}" status)"
  subject="$(notif_field "${oid}" subject)"
  action="$(audit_field "${oid}" action)"
  if [[ "${status}" == "sent" && "${subject}" == "Payment failed: ${oid}" \
     && "${action}" == "PAYMENT_FAILED_RECORDED" ]]; then
    ok E2E-03 "PaymentFailed → email + PAYMENT_FAILED_RECORDED"
  else
    fail E2E-03 "status=${status} subject=${subject} action=${action}"
  fi
}

scenario_e2e_04() {
  local oid; oid="$(new_order_id wrongsrc)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:1,currency:"USD"}')"
  put_event_source "demo.customers" "OrderCreated" "${detail}" >/dev/null
  sleep "$(( WAIT_SECONDS / 2 + 2 ))"
  local n a
  n="$(query_by_order "${NOTIF_TABLE}" "${oid}" | jq '.Items | length')"
  a="$(query_by_order "${AUDIT_TABLE}" "${oid}" | jq '.Items | length')"
  if (( n == 0 && a == 0 )); then
    ok E2E-04 "Wrong source (demo.customers) produced no worker rows"
  else
    fail E2E-04 "Unexpected rows notif=${n} audit=${a}"
  fi
}

scenario_e2e_05() {
  local oid; oid="$(new_order_id wrongtype)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,status:"SHIPPED"}')"
  put_event "OrderUpdated" "${detail}" >/dev/null
  sleep "$(( WAIT_SECONDS / 2 + 2 ))"
  local n a
  n="$(query_by_order "${NOTIF_TABLE}" "${oid}" | jq '.Items | length')"
  a="$(query_by_order "${AUDIT_TABLE}" "${oid}" | jq '.Items | length')"
  if (( n == 0 && a == 0 )); then
    ok E2E-05 "OrderUpdated (no rule) produced no worker rows"
  else
    fail E2E-05 "Unexpected rows notif=${n} audit=${a}"
  fi
}

scenario_e2e_06() {
  local oid; oid="$(new_order_id wrongbus)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:1,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" "default" >/dev/null || true
  sleep "$(( WAIT_SECONDS / 2 + 2 ))"
  local n a
  n="$(query_by_order "${NOTIF_TABLE}" "${oid}" | jq '.Items | length')"
  a="$(query_by_order "${AUDIT_TABLE}" "${oid}" | jq '.Items | length')"
  if (( n == 0 && a == 0 )); then
    ok E2E-06 "Wrong bus (default) produced no worker rows"
  else
    fail E2E-06 "Unexpected rows notif=${n} audit=${a}"
  fi
}

scenario_e2e_07() {
  local oid; oid="$(new_order_id fanout)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:10,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-07 "Missing fan-out worker pair for ${oid}"
    return
  fi
  local n_oid a_oid n_eid a_eid
  n_oid="$(notif_field "${oid}" orderId)"
  a_oid="$(audit_field "${oid}" orderId)"
  n_eid="$(notif_field "${oid}" eventId)"
  a_eid="$(audit_field "${oid}" eventId)"
  if [[ "${n_oid}" == "${oid}" && "${a_oid}" == "${oid}" && -n "${n_eid}" && "${n_eid}" == "${a_eid}" ]]; then
    ok E2E-07 "Fan-out identity: same orderId + eventId on notification and audit"
  else
    fail E2E-07 "orderId n/a=${n_oid}/${a_oid} eventId n/a=${n_eid}/${a_eid}"
  fi
}

scenario_e2e_08() {
  # Minimal detail — workers use orderId "unknown"
  local detail='{}'
  local before_n before_a after_n after_a
  before_n="$(aws dynamodb scan --region "${REGION}" --table-name "${NOTIF_TABLE}" --select COUNT --output json | jq '.Count')"
  before_a="$(aws dynamodb scan --region "${REGION}" --table-name "${AUDIT_TABLE}" --select COUNT --output json | jq '.Count')"
  put_event "OrderCreated" "${detail}" >/dev/null
  sleep "${WAIT_SECONDS}"
  # Query by unknown orderId
  local n a
  n="$(query_by_order "${NOTIF_TABLE}" "unknown" | jq '.Items | length')"
  a="$(query_by_order "${AUDIT_TABLE}" "unknown" | jq '.Items | length')"
  after_n="$(aws dynamodb scan --region "${REGION}" --table-name "${NOTIF_TABLE}" --select COUNT --output json | jq '.Count')"
  after_a="$(aws dynamodb scan --region "${REGION}" --table-name "${AUDIT_TABLE}" --select COUNT --output json | jq '.Count')"
  if (( n >= 1 && a >= 1 )) || (( after_n > before_n && after_a > before_a )); then
    ok E2E-08 "Minimal Detail={} still processed (orderId=unknown path)"
  else
    fail E2E-08 "Minimal detail did not land (notif unknown=${n} audit unknown=${a})"
  fi
}

scenario_e2e_09() {
  local oid; oid="$(new_order_id healthy)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:5,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" >/dev/null
  wait_for_pair "${oid}" >/dev/null || true
  sleep 2
  local e_vis a_vis eb_vis
  e_vis="$(queue_visible "${EMAIL_DLQ}" | jq -r '.ApproximateNumberOfMessages')"
  a_vis="$(queue_visible "${AUDIT_DLQ}" | jq -r '.ApproximateNumberOfMessages')"
  eb_vis="$(queue_visible "${EB_DLQ}" | jq -r '.ApproximateNumberOfMessages')"
  if [[ "${e_vis}" == "0" && "${a_vis}" == "0" && "${eb_vis}" == "0" ]]; then
    ok E2E-09 "Healthy path: all DLQs empty (email/audit/eventbridge)"
  else
    fail E2E-09 "DLQ depths email=${e_vis} audit=${a_vis} eventbridge=${eb_vis}"
  fi
}

scenario_e2e_10() {
  if [[ -z "${CONFIG_SET}" || "${CONFIG_SET}" == "None" ]]; then
    skip E2E-10 "SES configuration set not deployed (EnableSesTracking=false?)"
    return
  fi
  local oid; oid="$(new_order_id sescfg)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:7,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-10 "No notification row to check configuration set"
    return
  fi
  local cfg
  cfg="$(notif_field "${oid}" configurationSet)"
  if [[ "${cfg}" == "${CONFIG_SET}" ]]; then
    ok E2E-10 "SES configuration set attached (${cfg})"
  else
    fail E2E-10 "Expected configurationSet=${CONFIG_SET}, got ${cfg}"
  fi
}

scenario_e2e_11() {
  local alarms alarm_state bad=0
  alarms="$(aws cloudwatch describe-alarms \
    --region "${REGION}" \
    --alarm-name-prefix "${STACK_NAME}-" \
    --query 'MetricAlarms[].[AlarmName,StateValue]' \
    --output text)"
  if [[ -z "${alarms}" ]]; then
    fail E2E-11 "No CloudWatch alarms with prefix ${STACK_NAME}-"
    return
  fi
  while IFS=$'\t' read -r name state; do
    [[ -z "${name}" ]] && continue
    if [[ "${state}" == "ALARM" ]]; then
      bad=1
      log "    alarm in ALARM state: ${name}"
    fi
  done <<< "${alarms}"
  local count
  count="$(echo "${alarms}" | grep -c $'\t' || true)"
  if (( bad == 0 && count >= 5 )); then
    ok E2E-11 "Alarms present (${count}+) and none in ALARM state"
  elif (( bad == 0 )); then
    ok E2E-11 "Alarms present and none in ALARM (count≈${count})"
  else
    fail E2E-11 "One or more alarms are in ALARM state"
  fi
}

scenario_e2e_12() {
  local n=3
  local ids=()
  local i oid detail
  for (( i=1; i<=n; i++ )); do
    oid="$(new_order_id burst${i})"
    ids+=("${oid}")
    detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
      '{orderId:$o,customerEmail:$e,totalAmount:1,currency:"USD"}')"
    put_event "OrderCreated" "${detail}" >/dev/null
  done
  local ok_count=0
  for oid in "${ids[@]}"; do
    if wait_for_pair "${oid}" >/dev/null; then
      ok_count=$((ok_count + 1))
    fi
  done
  if (( ok_count == n )); then
    ok E2E-12 "Burst of ${n} OrderCreated events → ${ok_count} worker pairs"
  else
    fail E2E-12 "Expected ${n} pairs, got ${ok_count}"
  fi
}

scenario_e2e_13() {
  # Recipient on notification matches event customerEmail; sender matches stack
  local oid; oid="$(new_order_id recip)"
  local detail
  detail="$(jq -nc --arg o "$oid" --arg e "$RECIPIENT" \
    '{orderId:$o,customerEmail:$e,totalAmount:3,currency:"USD"}')"
  put_event "OrderCreated" "${detail}" >/dev/null
  if ! wait_for_pair "${oid}" >/dev/null; then
    fail E2E-13 "No notification for recipient check"
    return
  fi
  local to from status
  to="$(notif_field "${oid}" recipient)"
  from="$(notif_field "${oid}" sender)"
  status="$(notif_field "${oid}" status)"
  if [[ "${to}" == "${RECIPIENT}" && "${from}" == "${SENDER}" && "${status}" == "sent" ]]; then
    ok E2E-13 "SES envelope: from=${from} to=${to}"
  else
    fail E2E-13 "from=${from} (want ${SENDER}) to=${to} (want ${RECIPIENT}) status=${status}"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  log "OrderPulse E2E tests"
  log "  stack=${STACK_NAME} region=${REGION} recipient=${RECIPIENT}"
  require_stack
  log "  bus=${BUS_NAME} sender=${SENDER} configSet=${CONFIG_SET:-none}"

  run_scenario E2E-01 scenario_e2e_01
  run_scenario E2E-02 scenario_e2e_02
  run_scenario E2E-03 scenario_e2e_03
  run_scenario E2E-04 scenario_e2e_04
  run_scenario E2E-05 scenario_e2e_05
  run_scenario E2E-06 scenario_e2e_06
  run_scenario E2E-07 scenario_e2e_07
  run_scenario E2E-08 scenario_e2e_08
  run_scenario E2E-09 scenario_e2e_09
  run_scenario E2E-10 scenario_e2e_10
  run_scenario E2E-11 scenario_e2e_11
  run_scenario E2E-12 scenario_e2e_12
  run_scenario E2E-13 scenario_e2e_13

  log ""
  log "══════════════════════════════════════"
  for r in "${RESULTS[@]}"; do log "  ${r}"; done
  log "══════════════════════════════════════"
  log "Result: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}, ${YELLOW}${SKIP} skipped${RESET}"
  (( FAIL == 0 ))
}

main
