// src/notifications/notifier.ts
import { enqueue } from "../queue/client";

// Notifications in this codebase are ASYNCHRONOUS ONLY. There is no synchronous
// send path: every notification is enqueued and delivered by a background
// worker. A caller cannot block on or read the delivery result inline.
export async function queueOrderConfirmation(orderId: string): Promise<void> {
  await enqueue("order-confirmation", { orderId });
}
