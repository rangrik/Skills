# Behavior Spec: Invite Teammates to a Workspace

## 1. Overview

Workspace admins can invite teammates by email. The admin opens the Members
settings page, opens an Invite dialog, enters one or more email addresses,
chooses a role, and sends. Each invitee receives an invitation email. Clicking
**Accept** brings them into the workspace: existing users log in, new users
create an account first, and either path ends with the invitee as an active
member of the workspace.

This document is the source of truth for the feature's behavior. The
accompanying `.feature` files (Gherkin) are the executable expression of these
scenarios for QA.

## 2. Scope

### In scope
- Inviting one or more teammates by email from the Members settings page.
- Sending invitation emails.
- Accepting an invitation as an existing user (logged out or logged in).
- Accepting an invitation as a new user (account creation).
- Pending invitation lifecycle: resend, revoke, expire.
- Role assignment at invitation time.
- Permission checks (only admins can invite).
- Common error and edge cases (duplicate invites, already-a-member, malformed
  email, seat limits).

### Out of scope (not covered by these specs)
- Bulk invite via CSV upload.
- Invite links / "anyone with the link can join" flows.
- SSO / SCIM-provisioned membership.
- Domain-based auto-join.
- Billing/payment collection when adding a seat (assumed handled elsewhere;
  only the seat-limit gate is referenced).
- Removing or downgrading existing members.

## 3. Roles & Actors

| Actor | Description |
|-------|-------------|
| **Admin** | A workspace member with the `admin` role. Can invite, resend, and revoke invitations. |
| **Member** | A standard workspace member. Cannot invite (in this spec). |
| **Invitee** | The person receiving the invitation email. May or may not already have an account. |
| **System** | The application: validation, email delivery, account/membership state. |

## 4. Key Concepts & Definitions

- **Invitation** — A record tying an email address to a workspace, with a role,
  a status, an inviter, a unique token, and an expiry timestamp.
- **Invitation statuses** — `pending`, `accepted`, `revoked`, `expired`.
- **Invitation token** — A single-use, unguessable value embedded in the
  Accept link. Identifies the invitation and is consumed on acceptance.
- **Expiry window** — An invitation is valid for **7 days** from the time it is
  sent (or last resent). After that it is `expired` and cannot be accepted.
- **Seat limit** — The maximum number of members allowed by the workspace's
  current plan. Pending invitations count toward the limit.
- **Active member** — A user who appears in the workspace Members list and can
  access workspace resources per their role.

## 5. Preconditions & Assumptions

- The acting admin is authenticated and viewing a workspace where they hold the
  `admin` role.
- Email delivery is available; "an email is sent" means the system enqueues a
  message to the provider successfully.
- Email addresses are matched case-insensitively and trimmed of surrounding
  whitespace.
- Account identity is keyed on email address; one account = one email.
- The default role offered in the Invite dialog is `member`.
- Roles selectable at invite time: `member` and `admin`.

## 6. Happy Path (Narrative)

1. The admin opens **Settings → Members**.
2. The admin clicks **Invite**. An invite dialog opens.
3. The admin types one or more email addresses and selects a role.
4. The admin clicks **Send**.
5. The system creates a `pending` invitation per address and sends each invitee
   an invitation email containing an **Accept** link.
6. Each pending invitation appears in the Members page under a
   "Pending invitations" section.
7. An invitee opens the email and clicks **Accept**.
8. If the invitee has no account, they are taken to a sign-up screen, create an
   account, and are then joined to the workspace.
9. If the invitee already has an account, they log in (or are already logged
   in) and are joined to the workspace.
10. The invitation status becomes `accepted`; the invitee becomes an active
    member with the assigned role and lands inside the workspace.

## 7. Detailed Behavior Rules

### 7.1 Sending invitations
- The Invite action is only available to admins. Members and non-members must
  not see or be able to trigger it.
- Multiple addresses may be entered at once; each produces its own invitation
  and its own email.
- Each address is validated for format. If any address is malformed, the admin
  is shown which ones are invalid and **no** invitations are sent until they
  are corrected or removed.
- If an entered address already belongs to an **active member** of the
  workspace, that address is rejected with a clear message; valid remaining
  addresses still send.
- If an entered address already has a **pending** invitation for this
  workspace, the system does not create a duplicate; it offers to resend
  instead.
- The same email may be sent multiple times across the batch only once — exact
  duplicates within a single submission are de-duplicated.
- A confirmation is shown summarizing how many invitations were sent.

### 7.2 Pending invitations
- Pending invitations are listed on the Members page with the invitee email,
  assigned role, inviter, and sent date.
- An admin can **resend** a pending invitation; this re-sends the email and
  resets the 7-day expiry from the resend time.
- An admin can **revoke** a pending invitation; the invitation becomes
  `revoked` and its Accept link no longer works.

### 7.3 Accepting invitations
- The Accept link carries the invitation token. The system resolves the token
  to an invitation and checks its status before proceeding.
- **Valid + new user:** the invitee is routed to sign-up with the invited email
  pre-filled. On successful account creation they are joined to the workspace
  and the invitation is marked `accepted`.
- **Valid + existing user, logged out:** the invitee is asked to log in. After
  login they are joined to the workspace and the invitation is marked
  `accepted`.
- **Valid + existing user, already logged in:** if the logged-in account's
  email matches the invitation, they are joined immediately. If it does not
  match, the system warns them and offers to switch accounts / log in as the
  invited email.
- **Already accepted:** the link shows that the invitation was already used;
  if the user is the invitee they are taken into the workspace.
- **Revoked:** the link shows the invitation is no longer valid.
- **Expired:** the link shows the invitation has expired and suggests asking an
  admin to resend.
- On acceptance the role is taken from the invitation, not chosen by the
  invitee.

### 7.4 Seat limits
- Before sending, if accepting the new invitations would exceed the workspace
  seat limit, the admin is blocked and informed; no invitations are sent.
- If seats fill between sending and acceptance, acceptance is blocked with a
  message advising the invitee to contact an admin.

## 8. Error & Edge Cases

| Case | Expected behavior |
|------|-------------------|
| Malformed email entered | Address flagged inline; Send blocked for that address; valid addresses unaffected once invalid ones removed. |
| Email already an active member | Address rejected with message; other valid addresses still sent. |
| Email already has a pending invite | No duplicate created; admin offered "Resend". |
| Duplicate addresses within one submission | De-duplicated; one invitation sent. |
| Non-admin attempts to invite | Action not visible/available; direct API attempt denied. |
| Accept link with invalid/unknown token | Generic "invitation not found / no longer valid" page. |
| Accept an expired invitation | Expired page; offer to request a resend. |
| Accept a revoked invitation | "No longer valid" page. |
| Accept an already-accepted invitation | Informational page; invitee taken into workspace. |
| Logged-in user accepts invite for a different email | Warned; offered to switch accounts. |
| Seat limit would be exceeded on send | Send blocked; admin informed. |
| Seat limit reached before acceptance | Acceptance blocked; invitee told to contact an admin. |
| Email delivery provider fails | Invitation still created as `pending`; admin sees a delivery warning and can resend. |

## 9. Acceptance Criteria (Summary)

- [ ] Only admins can open the Invite dialog and send invitations.
- [ ] An admin can invite one or multiple emails in a single submission.
- [ ] Each invitee receives one invitation email with a working Accept link.
- [ ] Malformed emails block sending and are clearly flagged.
- [ ] Existing members and existing pending invites are handled without
      creating duplicates.
- [ ] A new user who accepts can create an account and ends up inside the
      workspace as a member.
- [ ] An existing user who accepts logs in and ends up inside the workspace as
      a member.
- [ ] Accepted invitees have the role assigned by the admin.
- [ ] Pending invitations can be resent and revoked.
- [ ] Expired and revoked invitations cannot be accepted.
- [ ] Seat limits are enforced both on send and on accept.

## 10. Feature Files Index

The Gherkin specs are split by area:

| File | Covers |
|------|--------|
| `send-invitations.feature` | Sending invitations from the Members page; validation; duplicates; permissions; seat limits. |
| `accept-invitation.feature` | Accepting as new vs. existing user; expired/revoked/used links; account mismatch. |
| `manage-pending-invitations.feature` | Listing, resending, and revoking pending invitations. |
