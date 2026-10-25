# Event-Driven Notification Service

Publish an **OrderCreated** event → **EventBridge** matches it → **SNS** fans out → **Email** and **Audit** SQS queues.

Uses **SAM / CloudFormation**, **TypeScript Lambda workers** (`tsc` → Node.js 24) on the Email and Audit queues, and the **AWS CLI**.
Email worker sends real mail via **SES** (`orders@dailynonsensia.site` by default) and logs the result to DynamoDB.

```
  put-events          match         fan-out              workers
┌──────────┐ OrderCreated ┌──────────┐  ┌─────┐  ┌────────────┐  ┌──────────────┐
│ Producer │ ────────────►│EventBridge│─►│ SNS │─►│ EmailQueue │─►│ EmailWorker  │→ SES + Notifications table
└──────────┘              └──────────┘  └──┬──┘  └────────────┘  └──────────────┘
                                           │     ┌────────────┐  ┌──────────────┐
                                           └────►│ AuditQueue │─►│ AuditWorker  │→ Audit trail table
                                                 └────────────┘  └──────────────┘
```


## Prerequisites

- AWS CLI v2 configured (`aws sts get-caller-identity`)
- [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html)
- Node.js 20+ (for `npm` / `tsc` when building workers)
- `jq`
- Region: `us-east-1` (override with `AWS_REGION`)

## Quick start

```bash
# 1. Deploy infrastructure
chmod +x scripts/*.sh
./scripts/deploy.sh

# 2. Publish an OrderCreated event
./scripts/publish-event.sh

# 3. Confirm workers wrote notification + audit rows
./scripts/verify-workers.sh ord-1001

# 4. Run full end-to-end suite (E2E-01 … E2E-13)
./scripts/run-e2e-tests.sh

# 5. Tear down AWS resources
./scripts/cleanup.sh
```

Scenario catalog: [`tests/SCENARIOS.md`](tests/SCENARIOS.md).

## What gets created

| Resource | Purpose |
|----------|---------|
| Event bus `notification-sys-orders` | Isolates order domain events |
| Rule `notification-sys-order-created` | Matches `source=demo.orders` + `detail-type=OrderCreated` |
| SNS topic `notification-sys-order-notifications` | Fan-out hub |
| SQS `notification-sys-email` (+ `-email-dlq`) | Email worker queue + poison DLQ |
| SQS `notification-sys-audit` (+ `-audit-dlq`) | Audit worker queue + poison DLQ |
| SQS `notification-sys-eventbridge-dlq` | Failed EventBridge → SNS deliveries |
| Rules `order-created` / `order-cancelled` / `payment-failed` | Separate EventBridge rules → same SNS |
| Lambda `notification-sys-email-worker` | SES send + DynamoDB notification log |
| Lambda `notification-sys-audit-worker` | TypeScript worker → DynamoDB audit trail |
| DynamoDB `notification-sys-notifications` | Sent/failed email log (`sesMessageId`) |
| DynamoDB `notification-sys-audit-trail` | Audit log of order events |
| SES config set `notification-sys-email-events` | Open / click / bounce → CloudWatch |
| CloudWatch alarms + SNS `…-alarms` | Worker errors + DLQ depth |
| CloudWatch `/aws/vendedlogs/events/event-bus/…-orders` | EventBridge TRACE (ingest, rule match, SNS invoke) |

## Pipeline logs (every hop)

EventBridge TRACE logs **ingest → pattern match → SNS fan-out**. Workers log **queue land → fan-out consume**.

```bash
# Terminal A — follow all pipeline logs
./scripts/tail-pipeline-logs.sh

# Terminal B — publish
./scripts/publish-event.sh
```

**AWS Console**

1. **EventBridge path** — CloudWatch → Log groups →  
   `/aws/vendedlogs/events/event-bus/notification-sys-orders`  
   Look for: `Event Ingested`, `Rule Matching Started`, `Rule Matched` / `No Rules Matched`, `Invocation Succeeded` (SNS).
2. **Queue / fan-out path** —  
   `/aws/lambda/notification-sys-email-worker` and `…-audit-worker`  
   Look for JSON stages: `queue_landed`, `fanout_consumed`, `worker_done`.

Non-matching events (`OrderUpdated`) still show **Event Ingested** + **No Rules Matched** on the bus log group, and never reach the workers.

## Event shape

```json
{
  "Source": "demo.orders",
  "DetailType": "OrderCreated",
  "Detail": "{\"orderId\":\"ord-1001\",\"customerEmail\":\"snoufa3@gmail.com\",\"amount\":49.99}",
  "EventBusName": "<from stack output EventBusName>"
}
```

`scripts/publish-event.sh` fills in the bus name from CloudFormation outputs.

## Manual CLI equivalents

```bash
# After deploy, resolve outputs
aws cloudformation describe-stacks --stack-name notification-sys \
  --query 'Stacks[0].Outputs' --output table

# Publish
aws events put-events --entries file://events/order-created.json

# Peek queues (replace URLs)
aws sqs receive-message --queue-url "$EMAIL_URL" --wait-time-seconds 5
aws sqs receive-message --queue-url "$AUDIT_URL" --wait-time-seconds 5
```

## Cleanup

```bash
./scripts/cleanup.sh
# or
sam delete --stack-name notification-sys --region us-east-1 --no-prompts
```

## SES

- **From:** `SenderEmail` parameter (default `orders@dailynonsensia.site` — verified domain)
- **To:** `detail.customerEmail` on the event
- **Configuration set:** `notification-sys-email-events` (open/click/bounce → CloudWatch). Disable with `ENABLE_SES_TRACKING=false`
- Override sender: `SENDER_EMAIL=you@dailynonsensia.site ./scripts/deploy.sh`
- DynamoDB `status` is `sent` (with `sesMessageId`) or `failed`

## Extra detail-types

```bash
./scripts/publish-event.sh events/order-cancelled.json
./scripts/publish-event.sh events/payment-failed.json
./scripts/verify-workers.sh ord-1001
```

Each type has its **own EventBridge rule**, then the same SNS → Email/Audit fan-out. Workers pick subject/body/audit action from `detail-type`.

## Alarms & DLQs

- After **3** failed receives, messages move to `…-email-dlq` / `…-audit-dlq`
- CloudWatch alarms fire on worker **Errors** and DLQ **depth ≥ 1**
- Confirm the SNS email subscription sent to `AlarmEmail` (default `snoufa3@gmail.com`)
