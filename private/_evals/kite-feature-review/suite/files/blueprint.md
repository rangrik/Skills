# Behavior Blueprint: App Export Download

## Feature summary

Creators on the Kite platform can export a generated app as a downloadable
`.zip` bundle. The Creator clicks "Export" in the app builder; the platform
assembles the app's current files into a zip, stores it, and gives the Creator
a link to download it. Exports are per-app and tied to the requesting Creator's
workspace.

## Scenarios

### S1 — Creator requests an export (happy path)
Given a Creator viewing an app they own
When they click "Export"
Then an export job is created, the zip is assembled from the app's current
files, stored, and a download link is returned to the Creator.

### S2 — Creator downloads a completed export
Given an export that has finished assembling
When the Creator opens the download link
Then the zip is streamed to them and the export is marked as downloaded.

### S3 — Double-click / retried export request (corner case)
Given a Creator who clicks "Export" twice in quick succession (or whose client
retries the POST after a timeout)
When the second request arrives while the first export for the same app version
is still pending or complete
Then the platform returns the existing export rather than creating a duplicate
export job and duplicate stored artifact.

### S4 — Export of an app the Creator does not own (corner case)
Given a Creator who crafts an export request for an app in another workspace
When the request is received
Then the platform refuses the export — a Creator may only export apps in their
own workspace.

### S5 — Assembly fails partway (edge case)
Given an export job that starts assembling but the file assembly fails (a
source file is missing, storage write errors)
When the failure occurs
Then the export moves to an explicit `failed` terminal state with a reason, the
Creator is shown that the export failed, and no half-written zip is offered as a
valid download.

## Out of scope
- Scheduled / recurring exports.
- Exporting more than one app in a single bundle.
