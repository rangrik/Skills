# Scenario: Member uploads an avatar

## Gherkin

```gherkin
Feature: Avatar upload

  Scenario: Member uploads a new avatar image
    Given an authenticated member "bob"
    When bob uploads a PNG image to POST /api/members/me/avatar
    Then the response status is 200
    And the response includes the URL of the stored avatar
    And the uploaded file is rejected if it is larger than 5 MB
    And the uploaded file is rejected if it is not a PNG or JPEG
```

## Code changes

### backend/app/schemas/avatar.py (new)

```python
from pydantic import BaseModel


class AvatarResponse(BaseModel):
    avatar_url: str
```

### backend/app/services/avatar_service.py (new)

```python
from app.storage.blob_store import BlobStore
from app.schemas.avatar import AvatarResponse


class AvatarService:
    def __init__(self, store: BlobStore):
        self._store = store

    def upload_avatar(self, member_id: str, content: bytes, content_type: str) -> AvatarResponse:
        # Store the file and return its URL.
        key = f"avatars/{member_id}.img"
        url = self._store.put(key, content, content_type=content_type)
        return AvatarResponse(avatar_url=url)
```

### backend/app/routes/avatar_routes.py (new)

```python
from fastapi import APIRouter, Depends, UploadFile
from app.schemas.avatar import AvatarResponse
from app.services.avatar_service import AvatarService

router = APIRouter()


@router.post("/api/members/me/avatar", response_model=AvatarResponse)
async def upload_avatar(
    file: UploadFile,
    member=Depends(get_current_member),
    service: AvatarService = Depends(get_avatar_service),
) -> AvatarResponse:
    content = await file.read()
    return service.upload_avatar(member.id, content, file.content_type)
```

Note: there is no size check and no content-type validation anywhere in these
changes. The file is read and stored as-is regardless of size or type.
