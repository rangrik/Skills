// src/users/service.ts
import { db } from "../db/client";
import { User } from "./types";

// Fetches the full user record by primary key.
// NOTE: assumes the caller has already authenticated; performs no auth check.
export async function getUserById(id: string): Promise<User | null> {
  const row = await db.query("SELECT * FROM users WHERE id = $1", [id]);
  return row ?? null;
}

// Updates mutable profile columns. Not paginated; touches a single row.
export async function updateUserProfile(
  id: string,
  patch: Partial<Pick<User, "displayName" | "bio">>,
): Promise<User> {
  return db.update("users", id, patch);
}
