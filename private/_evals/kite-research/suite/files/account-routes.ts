// src/routes/account.ts
import { Router } from "express";
import { requireAuth } from "../middleware/auth";
import { getUserById, updateUserProfile } from "../users/service";

const router = Router();

// GET the authenticated user's own account record.
router.get("/account", requireAuth, async (req, res) => {
  const user = await getUserById(req.userId);
  res.json(user);
});

// PATCH the authenticated user's account record.
router.patch("/account", requireAuth, async (req, res) => {
  const updated = await updateUserProfile(req.userId, req.body);
  res.json(updated);
});

export default router;
