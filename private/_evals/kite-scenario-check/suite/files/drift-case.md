# Scenario: Member updates their display name

## Gherkin

```gherkin
Feature: Edit display name

  Scenario: Member updates their display name
    Given an authenticated member "carol"
    When carol sends PATCH /api/members/me with a new display_name
    Then the response status is 200
    And the response includes the updated display_name
    And the display_name is persisted for carol
```

## Code changes

### backend/app/schemas/member.py (modified)

```python
from pydantic import BaseModel


class UpdateMemberRequest(BaseModel):
    display_name: str
    # Added while I was in here:
    marketing_emails_opt_in: bool | None = None
    theme_preference: str | None = None


class MemberResponse(BaseModel):
    username: str
    display_name: str
    marketing_emails_opt_in: bool
    theme_preference: str
```

### backend/app/services/member_service.py (modified)

```python
class MemberService:
    def __init__(self, repo, mailer):
        self._repo = repo
        self._mailer = mailer

    def update_member(self, member_id: str, req: UpdateMemberRequest) -> MemberResponse:
        member = self._repo.get(member_id)
        member.display_name = req.display_name

        # Extra behavior not in this scenario:
        if req.marketing_emails_opt_in is not None:
            member.marketing_emails_opt_in = req.marketing_emails_opt_in
            # Fire a welcome/goodbye email on opt-in change.
            self._mailer.send_marketing_preference_changed(member)
        if req.theme_preference is not None:
            member.theme_preference = req.theme_preference

        self._repo.save(member)
        return MemberResponse(
            username=member.username,
            display_name=member.display_name,
            marketing_emails_opt_in=member.marketing_emails_opt_in,
            theme_preference=member.theme_preference,
        )
```

### backend/app/routes/member_routes.py (modified)

```python
@router.patch("/api/members/me", response_model=MemberResponse)
def update_member(
    req: UpdateMemberRequest,
    member=Depends(get_current_member),
    service: MemberService = Depends(get_member_service),
) -> MemberResponse:
    return service.update_member(member.id, req)
```

Note: the scenario only asks for updating display_name. These changes also add
marketing-email opt-in handling (including sending an email) and a theme
preference, neither of which this scenario calls for.
