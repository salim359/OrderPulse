# OrderPulse end-to-end test scenarios

Run against the live stack:

```bash
./scripts/run-e2e-tests.sh
./scripts/run-e2e-tests.sh E2E-02          # one scenario
RECIPIENT=you@example.com ./scripts/run-e2e-tests.sh
```

| ID | Scenario | Expect |
|----|----------|--------|
| **E2E-01** | `OrderCreated` happy path | Notification `status=sent` + SES message id; audit `ORDER_CREATED_RECORDED`; subject “Order confirmed…” |
| **E2E-02** | `OrderCancelled` rule | Email “Order cancelled…”; audit `ORDER_CANCELLED_RECORDED` |
| **E2E-03** | `PaymentFailed` rule | Email “Payment failed…”; audit `PAYMENT_FAILED_RECORDED` |
| **E2E-04** | Wrong source `demo.customers` | Event accepted; **no** notification/audit rows |
| **E2E-05** | Wrong type `OrderUpdated` | **No** worker rows (no matching rule) |
| **E2E-06** | Wrong bus `default` | **No** worker rows |
| **E2E-07** | Fan-out identity | Same `orderId` + `eventId` on notification and audit |
| **E2E-08** | Minimal `Detail={}` | Still processed (`orderId=unknown`) |
| **E2E-09** | Healthy DLQs | Email / audit / EventBridge DLQs all depth 0 |
| **E2E-10** | SES configuration set | Notification `configurationSet=notification-sys-email-events` |
| **E2E-11** | CloudWatch alarms | Alarms exist; none in `ALARM` state |
| **E2E-12** | Burst (3× `OrderCreated`) | 3 notification+audit pairs |
| **E2E-13** | SES envelope | `sender` = stack From; `recipient` = `customerEmail` |

## Flow under test

```
put-events → EventBridge rule → SNS → EmailQueue → EmailWorker → SES + DynamoDB
                              └────→ AuditQueue → AuditWorker → DynamoDB
```

## Manual spot checks

```bash
./scripts/publish-event.sh
./scripts/verify-workers.sh ord-1001

./scripts/publish-event.sh events/order-cancelled.json
./scripts/publish-event.sh events/payment-failed.json
```
