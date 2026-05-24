FAIL

Clause check:
- Given an authenticated member "carol": satisfied by the route using `get_current_member` and passing that member's id to the service.
- When carol sends `PATCH /api/members/me` with a new `display_name`: satisfied by the PATCH route accepting `UpdateMemberRequest.display_name`.
- Then the response status is 200: satisfied implicitly by returning `MemberResponse` without an alternate status or error path.
- And the response includes the updated `display_name`: satisfied by assigning `member.display_name = req.display_name` and returning it.
- And the `display_name` is persisted for carol: satisfied by saving the fetched current member after updating `display_name`.

Missing or drift:
- Missing for the display-name update behavior: none.
- Drift: `marketing_emails_opt_in` and `theme_preference` are added to the request and response, persisted by the service, and marketing preference changes trigger an email. Those fields and side effects are outside this scenario.

Commit readiness:
- Do not commit this scenario slice as-is. The required display-name behavior is present, but the out-of-scope preference fields and email side effect should be removed from this slice or moved to separate scenarios.
