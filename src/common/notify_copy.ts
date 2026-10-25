/** Subject/body copy for each OrderPulse detail-type. */

import type { EventFields } from "./event_parse";

export interface NotifyCopy {
  subject: string;
  text: string;
  html: string;
  auditAction: string;
}

export function notifyCopy(fields: EventFields): NotifyCopy {
  const amount = fields.totalAmount;
  const currency = fields.currency || "USD";
  const orderId = fields.orderId;

  switch (fields.detailType) {
    case "OrderCancelled":
      return {
        subject: `Order cancelled: ${orderId}`,
        text:
          `Your order ${orderId} has been cancelled.\n\n` +
          (amount != null ? `Amount: ${amount} ${currency}\n\n` : "") +
          `— OrderPulse`,
        html:
          `<p>Your order <strong>${orderId}</strong> has been cancelled.</p>` +
          (amount != null
            ? `<p>Amount: <strong>${amount} ${currency}</strong></p>`
            : "") +
          `<p style="color:#666">— OrderPulse</p>`,
        auditAction: "ORDER_CANCELLED_RECORDED",
      };
    case "PaymentFailed":
      return {
        subject: `Payment failed: ${orderId}`,
        text:
          `Payment for order ${orderId} could not be completed.\n\n` +
          (amount != null ? `Amount: ${amount} ${currency}\n\n` : "") +
          `Please update your payment method and try again.\n\n— OrderPulse`,
        html:
          `<p>Payment for order <strong>${orderId}</strong> could not be completed.</p>` +
          (amount != null
            ? `<p>Amount: <strong>${amount} ${currency}</strong></p>`
            : "") +
          `<p>Please update your payment method and try again.</p>` +
          `<p style="color:#666">— OrderPulse</p>`,
        auditAction: "PAYMENT_FAILED_RECORDED",
      };
    case "OrderCreated":
    default:
      return {
        subject: `Order confirmed: ${orderId}`,
        text:
          `Thanks for your order ${orderId}.\n\n` +
          `Total: ${amount} ${currency}\n\n` +
          `— OrderPulse`,
        html:
          `<p>Thanks for your order <strong>${orderId}</strong>.</p>` +
          `<p>Total: <strong>${amount} ${currency}</strong></p>` +
          `<p style="color:#666">— OrderPulse</p>`,
        auditAction: "ORDER_CREATED_RECORDED",
      };
  }
}
