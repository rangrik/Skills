// src/orders/schema.ts
// Persisted shape of an order. There is intentionally no `email` column on the
// user-facing order; contact details are resolved from the user record.
export interface Order {
  id: string;
  userId: string;
  status: "pending" | "paid" | "shipped" | "cancelled";
  totalCents: number;
  createdAt: string;
}
