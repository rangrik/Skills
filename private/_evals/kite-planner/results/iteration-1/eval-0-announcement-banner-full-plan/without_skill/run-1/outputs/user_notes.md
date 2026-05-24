# User Notes

The implementation plan is ready, but research or product should confirm these items before or during implementation:

- Confirm the existing workspace and user primary key types before writing migrations.
- Confirm the local feature-flag mechanism and whether disabled backend routes should return 404 exactly as the system design suggests.
- Confirm whether the optional link should display as the URL itself, a fixed label such as "Learn more", or a separate admin-provided label. The blueprint only says "optional link".
- Confirm whether editing an active announcement should edit only message text, as the blueprint explicitly states, or whether link and schedule edits are also expected.
- Confirm how the product wants concurrent publish conflicts presented: the system design recommends a conflict response for the losing admin, while the blueprint only requires that the system never exposes more than one active banner.
- Confirm retention policy for archived or removed announcements and dismissal rows before adding any cleanup automation.
