FAIL

Scenario drift: yes. The implementation stores any uploaded file as-is and only satisfies the happy path response shape, not the scenario's validation requirements.

Clause-tied gaps:
- `And the uploaded file is rejected if it is larger than 5 MB`: not implemented. The route reads the entire file and `AvatarService` stores it without any size limit.
- `And the uploaded file is rejected if it is not a PNG or JPEG`: not implemented. `content_type` is passed through to storage but never validated.

Commit readiness: do not commit this as complete. Add size and PNG/JPEG validation, with rejection behavior/tests, before committing.
