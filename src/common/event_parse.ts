/** Shared helpers for parsing EventBridge events delivered via SQS. */

export type JsonObject = Record<string, unknown>;

export interface EventFields {
  eventId: string;
  source: string;
  detailType: string;
  time?: string;
  region?: string;
  account?: string;
  detail: JsonObject;
  orderId: string;
  customerId?: string;
  customerEmail?: string;
  totalAmount?: unknown;
  currency?: string;
}

export function parseBody(raw: string | JsonObject): JsonObject {
  let body: JsonObject = typeof raw === "string" ? JSON.parse(raw) : raw;

  // SNS envelope if RawMessageDelivery is ever turned off
  if (
    "Message" in body &&
    !("detail-type" in body) &&
    !("detail" in body)
  ) {
    const msg = body.Message;
    body = typeof msg === "string" ? JSON.parse(msg) : (msg as JsonObject);
  }

  return body;
}

export function extractDetail(body: JsonObject): JsonObject {
  let detail: unknown = body.detail ?? body.Detail ?? {};
  if (typeof detail === "string") {
    try {
      detail = JSON.parse(detail);
    } catch {
      detail = { raw: detail };
    }
  }
  if (typeof detail !== "object" || detail === null || Array.isArray(detail)) {
    return { value: detail };
  }
  return detail as JsonObject;
}

export function eventFields(body: JsonObject): EventFields {
  const detail = extractDetail(body);
  return {
    eventId: String(body.id ?? body.EventId ?? "unknown"),
    source: String(body.source ?? body.Source ?? "unknown"),
    detailType: String(body["detail-type"] ?? body.DetailType ?? "unknown"),
    time: (body.time ?? body.Time) as string | undefined,
    region: body.region as string | undefined,
    account: body.account as string | undefined,
    detail,
    orderId: String(detail.orderId ?? "unknown"),
    customerId: detail.customerId as string | undefined,
    customerEmail: detail.customerEmail as string | undefined,
    totalAmount: detail.totalAmount ?? detail.amount,
    currency: detail.currency as string | undefined,
  };
}
