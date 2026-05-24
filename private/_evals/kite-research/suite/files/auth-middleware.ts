// src/middleware/auth.ts
import { Request, Response, NextFunction } from "express";
import { verifySessionToken } from "../auth/session";

// Express middleware. Rejects unauthenticated requests with 401 and otherwise
// attaches the resolved user id to req.userId.
export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.headers.authorization?.replace("Bearer ", "");
  const userId = token ? verifySessionToken(token) : null;
  if (!userId) {
    return res.status(401).json({ error: "unauthenticated" });
  }
  (req as any).userId = userId;
  next();
}
