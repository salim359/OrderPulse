/**
 * Audit worker — consumes AuditQueue and appends an immutable-style audit trail row.
 */
import type { SQSEvent, SQSHandler, SQSRecord } from "aws-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

import { eventFields, parseBody } from "../common/event_parse";
import { notifyCopy } from "../common/notify_copy";
import { pipelineLog } from "../common/pipeline_log";

const TABLE_NAME = process.env.AUDIT_TABLE!;
const QUEUE_NAME = process.env.QUEUE_NAME ?? "audit";

const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

async function processRecord(record: SQSRecord): Promise<Record<string, unknown>> {
  pipelineLog("queue_landed", "Message landed on AuditQueue (SNS fan-out)", {
    queue: QUEUE_NAME,
    sqsMessageId: record.messageId,
    approximateReceiveCount: record.attributes?.ApproximateReceiveCount,
  });

  const body = parseBody(record.body);
  const fields = eventFields(body);
  const copy = notifyCopy(fields);
  const now = new Date().toISOString();

  pipelineLog("fanout_consumed", "Audit path consuming fan-out event", {
    queue: QUEUE_NAME,
    eventId: fields.eventId,
    orderId: fields.orderId,
    source: fields.source,
    detailType: fields.detailType,
  });

  const item = {
    auditId: `audit#${fields.eventId}`,
    eventId: fields.eventId,
    orderId: fields.orderId,
    action: copy.auditAction,
    source: fields.source,
    detailType: fields.detailType,
    eventTime: fields.time || now,
    recordedAt: now,
    detail: fields.detail,
    sqsMessageId: record.messageId,
  };

  await doc.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: item,
    }),
  );

  pipelineLog("worker_done", "audit_recorded", {
    queue: QUEUE_NAME,
    auditId: item.auditId,
    orderId: item.orderId,
    action: item.action,
    detailType: item.detailType,
    eventId: item.eventId,
  });

  return item;
}

export const handler: SQSHandler = async (event: SQSEvent) => {
  const records = event.Records ?? [];
  pipelineLog("worker_batch", "Audit worker invoked from SQS", {
    queue: QUEUE_NAME,
    batchSize: records.length,
  });

  for (const record of records) {
    await processRecord(record);
  }

  return;
};
