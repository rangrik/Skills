# Scenario: User views their public profile

## Gherkin

```gherkin
Feature: Public profile page

  Scenario: Visitor views a member's public profile
    Given a member "alice" with a public profile
    And alice joined on 2024-03-01
    When a visitor requests GET /api/profiles/alice
    Then the response status is 200
    And the response includes alice's display name
    And the response includes alice's join date
    And the response does NOT include alice's email address
```

## Code changes

### backend/app/schemas/profile.py (new)

```python
from datetime import date
from pydantic import BaseModel


class PublicProfileResponse(BaseModel):
    username: str
    display_name: str
    join_date: date
```

### backend/app/services/profile_service.py (new)

```python
from app.repositories.member_repo import MemberRepo
from app.schemas.profile import PublicProfileResponse


class ProfileService:
    def __init__(self, repo: MemberRepo):
        self._repo = repo

    def get_public_profile(self, username: str) -> PublicProfileResponse:
        member = self._repo.get_by_username(username)
        if member is None or not member.profile_is_public:
            raise NotFoundError(f"profile {username} not found")
        return PublicProfileResponse(
            username=member.username,
            display_name=member.display_name,
            join_date=member.created_at.date(),
        )
```

### backend/app/routes/profile_routes.py (new)

```python
from fastapi import APIRouter, Depends
from app.schemas.profile import PublicProfileResponse
from app.services.profile_service import ProfileService

router = APIRouter()


@router.get("/api/profiles/{username}", response_model=PublicProfileResponse)
def get_public_profile(
    username: str,
    service: ProfileService = Depends(get_profile_service),
) -> PublicProfileResponse:
    return service.get_public_profile(username)
```
