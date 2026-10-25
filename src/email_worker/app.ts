/**
 * Email worker — consumes EmailQueue, sends mail via SES, logs to DynamoDB.
 */
import type { SQSEvent, SQSHandler, SQSRecord } from "aws-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

import { eventFields, parseBody } from "../common/event_parse";
import { notifyCopy } from "../common/notify_copy";
import { pipelineLog } from "../common/pipeline_log";

const TABLE_NAME = process.env.NOTIFICATIONS_TABLE!;
const QUEUE_NAME = process.env.QUEUE_NAME ?? "email";
const SENDER_EMAIL = process.env.SENDER_EMAIL!;
const SES_CONFIG_SET = process.env.SES_CONFIGURATION_SET || undefined;

const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
const ses = new SESv2Client({});

function isPermanentSesError(err: unknown): boolean {
  const name = (err as { name?: string })?.name || "";
  return [
    "MessageRejected",
    "MailFromDomainNotVerifiedException",
    "FromEmailAddressNotVerifiedException",
    "AccountSuspendedException",
    "BadRequestException",
  ].includes(name);
}

async function processRecord(record: SQSRecord): Promise<Record<string, unknown>> {
  pipelineLog("queue_landed", "Message landed on EmailQueue (SNS fan-out)", {
    queue: QUEUE_NAME,
    sqsMessageId: record.messageId,
    approximateReceiveCount: record.attributes?.ApproximateReceiveCount,
  });

  const body = parseBody(record.body);
  const fields = eventFields(body);
  const copy = notifyCopy(fields);
  const now = new Date().toISOString();

  pipelineLog("fanout_consumed", "Email path consuming fan-out event", {
    queue: QUEUE_NAME,
    eventId: fields.eventId,
    orderId: fields.orderId,
    source: fields.source,
    detailType: fields.detailType,
  });

  const recipient =
    fields.customerEmail ||
    (fields.customerId
      ? `${fields.customerId}@example.com`
      : "orders@example.com");

  const item: Record<string, unknown> = {
    notificationId: `email#${fields.eventId}`,
    channel: "email",
    status: "pending",
    eventId: fields.eventId,
    orderId: fields.orderId,
    recipient,
    sender: SENDER_EMAIL,
    subject: copy.subject,
    body: copy.text,
    detail: fields.detail,
    createdAt: now,
    source: fields.source,
    detailType: fields.detailType,
    configurationSet: SES_CONFIG_SET || null,
  };

  try {
    const sendRes = await ses.send(
      new SendEmailCommand({
        FromEmailAddress: SENDER_EMAIL,
        Destination: { ToAddresses: [recipient] },
        Content: {
          Simple: {
            Subject: { Data: copy.subject, Charset: "UTF-8" },
            Body: {
              Text: { Data: copy.text, Charset: "UTF-8" },
              Html: { Data: copy.html, Charset: "UTF-8" },
            },
          },
        },
        EmailTags: [
          { Name: "messageType", Value: fields.detailType },
          { Name: "orderId", Value: fields.orderId },
        ],
        ...(SES_CONFIG_SET
          ? { ConfigurationSetName: SES_CONFIG_SET }
          : {}),
      }),
    );

    item.status = "sent";
    item.sesMessageId = sendRes.MessageId;
    item.sentAt = new Date().toISOString();

    pipelineLog("ses_sent", "SES accepted email", {
      queue: QUEUE_NAME,
      orderId: fields.orderId,
      detailType: fields.detailType,
      recipient,
      sesMessageId: sendRes.MessageId,
      configurationSet: SES_CONFIG_SET || null,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const name = (err as { name?: string })?.name || "SesError";
    item.status = "failed";
    item.error = `${name}: ${message}`;
    item.failedAt = new Date().toISOString();

    pipelineLog("ses_failed", "SES send failed", {
      queue: QUEUE_NAME,
      orderId: fields.orderId,
      recipient,
      error: item.error,
    });

    await doc.send(
      new PutCommand({
        TableName: TABLE_NAME,
        Item: item,
      }),
    );

    if (isPermanentSesError(err)) {
      return item;
    }
    throw err;
  }

  await doc.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: item,
    }),
  );

  pipelineLog("worker_done", "notification_sent", {
    queue: QUEUE_NAME,
    notificationId: item.notificationId,
    orderId: item.orderId,
    recipient: item.recipient,
    status: item.status,
    sesMessageId: item.sesMessageId,
  });

  return item;
}

export const handler: SQSHandler = async (event: SQSEvent) => {
  const records = event.Records ?? [];
  pipelineLog("worker_batch", "Email worker invoked from SQS", {
    queue: QUEUE_NAME,
    batchSize: records.length,
  });

  for (const record of records) {
    await processRecord(record);
  }

  return;
};
