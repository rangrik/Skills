FAIL

Clause check:
- Given an authenticated member "bob": satisfied assuming `get_current_member` provides the authenticated member; `member.id` is used for storage.
- When bob uploads a PNG image to `POST /api/members/me/avatar`: satisfied; the route accepts an uploaded file and passes its content/type to `AvatarService`.
- Then the response status is 200: satisfied for successful uploads by the default FastAPI POST response.
- And the response includes the URL of the stored avatar: satisfied; `AvatarService.upload_avatar` stores the blob and returns `AvatarResponse(avatar_url=url)`.
- And the uploaded file is rejected if it is larger than 5 MB: not satisfied; the route reads the entire file and stores it with no size check.
- And the uploaded file is rejected if it is not a PNG or JPEG: not satisfied; `file.content_type` is passed through to storage with no allowed-type validation.

Missing or drift:
- Missing size validation and rejection response for files larger than 5 MB.
- Missing content-type validation and rejection response for non-PNG/JPEG files.
- No material drift beyond the scenario.

Commit readiness:
- Do not commit this scenario yet; the successful upload path is implemented, but the required rejection behavior is missing.
