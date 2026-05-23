# Behavior Spec: Transaction CSV Export

**Status:** Draft · **Date:** 2026-05-22

## 1. Problem & Intent

Users can see their transaction history on the Transactions page, but they have no way
to take that data with them — to analyse it in a spreadsheet, share it with an
accountant, or keep their own records. This feature lets a user select a date range and
download all transactions in that range as a CSV file.

**Primary success outcome:** The user receives a CSV file on their device containing
exactly the transactions whose dates fall within their selected range, and nothing else.

## 2. Actors

| Actor | Role in this feature |
|-------|----------------------|
| User | The authenticated account holder who views the Transactions page and initiates the export. |
| System (web app) | Renders the Transactions page and the date picker, validates the range, and triggers the file download. |
| Export service | The backend component that queries transactions, generates the CSV, and (for large exports) runs the job asynchronously. |
| Browser | Receives the generated file and writes it to the user's device per the user's download settings. |

## 3. Glossary

| Term | Definition |
|------|------------|
| Transaction | A single financial entry shown on the Transactions page, with at least a date, description, and amount. |
| Date range | A start date and an end date, both inclusive, that bound which transactions are exported. |
| Transaction date | The date attribute of a transaction used to decide whether it falls inside the selected range. Distinct from the date a transaction was created or posted if those differ. |
| Export | The act of generating and delivering a CSV file of transactions for the selected range. |
| CSV | A comma-separated-values text file, UTF-8 encoded, with one header row and one row per transaction. |
| In range | A transaction whose transaction date is on or after the start date and on or before the end date, evaluated in the user's account timezone. |
| Large export | An export whose result set exceeds the synchronous-generation threshold and is therefore processed as a background job. |

## 4. Preconditions & Assumptions

**Preconditions**

- The user is authenticated and has an active session.
- The user is on the Transactions page for their own account.
- The user has permission to view the transactions they are exporting.

**Standing assumptions**

- The CSV columns mirror the columns shown on the Transactions page (date, description,
  amount, and any other visible attributes), in the same order. *(Flagged — see §8, A1.)*
- The date range is inclusive of both the start and end dates.
- The range is evaluated in the user's account timezone, not the browser timezone or UTC.
  *(Flagged — see §8, A2.)*
- The export reflects the user's current Transactions-page state at the moment the
  export is requested; column-level filters and search terms applied on the page are
  *not* carried into the export — only the date range scopes it. *(Flagged — see §8, A3.)*
- Exports are generated synchronously and downloaded directly for result sets up to a
  defined threshold; larger result sets are processed as a background job. *(Flagged —
  see §8, A4.)*

## 5. Scope

**In scope**

- Selecting a date range with the date picker on the Transactions page.
- Generating and downloading a CSV of transactions within that range.
- Validation of the selected date range.
- Behavior for empty ranges, very large ranges, and failures during generation.
- Asynchronous handling of large exports.

**Out of scope**

- Export formats other than CSV (XLSX, PDF, OFX, etc.).
- Scheduled or recurring exports.
- Exporting to third-party destinations (cloud storage, accounting integrations).
- Editing, importing, or re-uploading transaction data.
- Column customisation UI for choosing which fields appear in the CSV.
- Exporting transactions for an account other than the user's own.

## 6. Happy-Path Scenarios

```gherkin
Feature: Transaction CSV Export
  Lets a user download their transaction history for a chosen date range as a CSV file.

  Background:
    Given the user is authenticated and viewing the Transactions page for their own account

  @happy-path
  Scenario: Exporting transactions for a selected date range
    Given the user has selected a start date and an end date in the date picker
    And at least one transaction exists within the selected range
    When the user clicks "Export to CSV"
    Then a CSV file is generated containing every transaction whose date is within the range, inclusive of both endpoints
    And the file downloads to the user's device
    And the CSV has a header row followed by one row per transaction
    And no transaction outside the selected range appears in the file

  @happy-path
  Scenario: Exporting a large date range that is processed as a background job
    Given the user has selected a date range whose result set exceeds the synchronous-export threshold
    When the user clicks "Export to CSV"
    Then the user is told the export is being prepared and will be available shortly
    And the user can continue using the Transactions page while it is prepared
    And when the file is ready the user is notified and can download it from that notification
```

## 7. Deviation Scenarios

### 7.1 Incomplete or invalid input

```gherkin
@deviation @invalid-input
Scenario: Clicking Export before selecting a date range
  Given the user has not selected any date range
  When the user clicks "Export to CSV"
  Then no export is generated
  And the user is shown the message "Select a date range to export" next to the date picker

@deviation @invalid-input
Scenario: Selecting an end date earlier than the start date
  Given the user has selected a start date that is later than the selected end date
  When the user attempts to export
  Then no export is generated
  And the date picker shows the message "The end date must be on or after the start date"
  And both selected dates remain in place so the user can correct one of them

@deviation @invalid-input
Scenario: Selecting only one end of the date range
  Given the user has selected a start date but not an end date
  When the user clicks "Export to CSV"
  Then no export is generated
  And the user is prompted to select the missing end date
  And the start date the user already chose remains selected
```

### 7.2 Duplicate submission / retry

```gherkin
@deviation @duplicate-retry
Scenario: Clicking Export to CSV twice in quick succession
  Given the user has selected a valid date range
  When the user clicks "Export to CSV" twice before the first export completes
  Then only one CSV file is generated
  And the "Export to CSV" button shows an in-progress state while the export runs
  And the user receives exactly one downloaded file

@deviation @duplicate-retry
Scenario: Re-exporting the same range after a successful download
  Given the user has already exported a date range successfully
  When the user clicks "Export to CSV" again for the same range
  Then a fresh CSV file is generated and downloaded
  And the file reflects the transactions in that range at the time of the second export
```

### 7.3 Rate limits, quotas, throttling

```gherkin
@deviation @rate-limit @assumption
Scenario: Requesting many exports in a short period
  # Assumption: exports are rate-limited per user to protect the export service;
  # a default cap of 10 exports per 10 minutes is assumed and must be confirmed.
  Given the user has reached the export rate limit for the current window
  When the user clicks "Export to CSV" again
  Then no new export is generated
  And the user is told they have hit the export limit and when they can export again
  And any export already in progress or completed remains unaffected
```

### 7.4 Connectivity loss & interruption

```gherkin
@deviation @connectivity
Scenario: Losing connectivity while the export is being generated
  Given the user has clicked "Export to CSV" and generation is in progress
  And the network connection drops before the file is delivered
  When connectivity is restored
  Then the user is told the export did not complete and can retry
  And the user's selected date range is still in place
  And no partial or corrupt CSV file is presented as if it were complete

@deviation @connectivity
Scenario: Closing the tab before a background export finishes
  Given the user has started a large export processed as a background job
  When the user closes the Transactions tab before the job completes
  Then the export job continues to run server-side
  And when the user returns to the Transactions page the completed export is available to download
```

### 7.5 Abandonment & resumption

```gherkin
@deviation @abandon-resume @assumption
Scenario: Returning to a completed background export later
  # Assumption: completed export files are retained and downloadable for 24 hours,
  # after which they are purged and must be re-generated. Retention window to be confirmed.
  Given the user requested a large export that completed while they were away
  When the user returns to the Transactions page within the retention window
  Then the user can download the completed export
  And the user is shown when that export file will expire
```

### 7.6 Out-of-order actions & navigation

```gherkin
@deviation @out-of-order
Scenario: Changing the date range while an export is still generating
  Given the user has clicked "Export to CSV" and generation is in progress
  When the user changes the date range in the date picker before the export completes
  Then the in-progress export still reflects the range that was selected when it started
  And the new range is not applied until the user clicks "Export to CSV" again
```

### 7.7 Auth & permission changes mid-flow

```gherkin
@deviation @auth-permission
Scenario: Session expires before the export is requested
  Given the user's session has expired while the Transactions page was open
  When the user clicks "Export to CSV"
  Then no export is generated
  And the user is prompted to sign in again
  And after signing in the user returns to the Transactions page with their selected date range intact

@deviation @auth-permission
Scenario: Session expires while a background export is being prepared
  Given the user started a large export and their session expired before it completed
  When the user signs in again and returns to the Transactions page
  Then the completed export is available to download under the re-authenticated session
  And the export contains only transactions the user is permitted to view
```

### 7.8 Concurrency & stale data

```gherkin
@deviation @concurrency
Scenario: A new transaction is added after the page loaded but before export
  Given the user loaded the Transactions page some time ago
  And a new transaction within the selected range was recorded since then
  When the user clicks "Export to CSV"
  Then the CSV reflects the transaction data as of the moment the export is generated, including the newer transaction
  And the export does not silently use the stale page snapshot

@deviation @concurrency
Scenario: Exporting the same range from two browser tabs at once
  Given the user has the Transactions page open in two tabs
  When the user clicks "Export to CSV" in both tabs for the same range
  Then each tab produces its own CSV file independently
  And neither export interferes with or corrupts the other
```

### 7.9 Precondition satisfied / state conflict

```gherkin
@deviation @state-conflict
Scenario: Exporting a date range that contains no transactions
  Given the user has selected a valid date range with no transactions in it
  When the user clicks "Export to CSV"
  Then the user is told there are no transactions in the selected range
  And no empty file with only a header is downloaded unless the user confirms they still want it
```

### 7.10 Empty, boundary & scale extremes

```gherkin
@deviation @boundary
Scenario: Exporting a single-day range
  Given the user has selected the same date as both the start and end of the range
  When the user clicks "Export to CSV"
  Then the CSV contains every transaction dated on that single day
  And transactions from the days immediately before and after are excluded

@deviation @boundary
Scenario: Brand-new user with no transaction history exports
  Given the user has never had any transactions
  When the user opens the date picker to export
  Then the user is shown that there is no transaction history to export
  And the export action does not produce a broken or empty download

@deviation @boundary @assumption
Scenario: Exporting a range with more transactions than can be generated synchronously
  # Assumption: result sets above a defined row threshold are handed to the background
  # job pipeline rather than failing; the threshold value must be confirmed.
  Given the user has selected a range containing far more transactions than the synchronous threshold
  When the user clicks "Export to CSV"
  Then the export is processed as a background job
  And the complete file is delivered once ready without truncating any rows
  And the user is kept informed of the export's progress

@deviation @boundary
Scenario: Transaction with unusual field values appears in the export
  Given a transaction in the selected range has a description containing commas, quotes, or line breaks
  When the user exports the range
  Then the affected field is correctly quoted and escaped in the CSV
  And the file opens in a spreadsheet application with columns correctly aligned
```

### 7.11 Environment & device capability

```gherkin
@deviation @environment
Scenario: Exporting from a mobile browser
  Given the user opens the Transactions page on a narrow mobile viewport
  When the user selects a date range and clicks "Export to CSV"
  Then the date picker and export control are fully usable without horizontal scrolling
  And the CSV file is saved through the mobile browser's standard download or share flow

@deviation @environment @assumption
Scenario: Browser blocks the automatic file download
  # Assumption: when an automatic download is blocked, the app exposes an explicit
  # download link as a fallback rather than failing silently.
  Given the user's browser is configured to block automatic downloads
  When the user clicks "Export to CSV" and the file is generated
  Then the user is shown an explicit link or button to download the generated file manually
  And the export is not reported as failed
```

### 7.12 External dependency failure

```gherkin
@deviation @external-failure
Scenario: The export service fails while generating the file
  Given the user has selected a valid date range
  When the user clicks "Export to CSV" and the export service returns an error
  Then no file is downloaded
  And the user is told the export could not be completed and is offered a retry, without a raw technical error
  And the user's selected date range remains in place

@deviation @external-failure @assumption
Scenario: A large background export job fails partway through
  # Assumption: the user is notified of a failed background export by the same channel
  # used to notify them of a completed one (in-app and/or email). Channel to be confirmed.
  Given the user started a large export processed as a background job
  When the job fails before producing a complete file
  Then the user is notified that the export failed and can retry it
  And no partial file is presented to the user as a successful export
```

### 7.13 Time, expiry & scheduling

```gherkin
@deviation @time-expiry @assumption
Scenario: Date range is interpreted consistently across timezones
  # Assumption: range boundaries are evaluated in the user's account timezone; a
  # transaction's date is compared on that same clock. To be confirmed.
  Given the user's account timezone differs from the browser's local timezone
  When the user selects a date range and exports
  Then a transaction's inclusion is decided by its date in the user's account timezone
  And the same range produces the same result regardless of the browser's timezone

@deviation @time-expiry
Scenario: Downloading a background export after its file has expired
  Given the user requested a large export whose generated file has since expired
  When the user attempts to download that expired export
  Then the user is told the export file is no longer available
  And the user can re-run the export for the same date range in one action
```

### 7.14 Adversarial & abuse input

```gherkin
@deviation @adversarial @assumption
Scenario: A transaction field contains a spreadsheet formula payload
  # Assumption: cell values that begin with =, +, -, or @ are neutralized (prefixed or
  # quoted) to prevent CSV formula injection when the file is opened. To be confirmed.
  Given a transaction in the selected range has a field whose value begins with "="
  When the user exports the range and opens the CSV in a spreadsheet application
  Then the value is displayed as inert text and not executed as a formula
  And no formula in the file can read other cells or perform an action

@deviation @adversarial
Scenario: An export request is tampered with to target another account
  Given a request attempts to export transactions for an account other than the requester's
  When the export service receives that request
  Then the request is rejected
  And only transactions belonging to the authenticated user can ever be exported
```

## 8. Flagged Assumptions

| # | Scenario | Assumed behavior | Needs confirmation |
|---|----------|------------------|--------------------|
| A1 | Standing assumption | CSV columns mirror the Transactions-page columns (date, description, amount, and other visible attributes) in the same order. | Confirm the exact column set, order, and headers — especially whether hidden/internal fields are included. |
| A2 | Date range is interpreted consistently across timezones | Range boundaries and transaction dates are evaluated in the user's account timezone. | Confirm the governing timezone (account vs. browser vs. UTC). |
| A3 | Standing assumption | Only the date range scopes the export; page-level search and column filters are not carried into the CSV. | Confirm whether on-page filters/search should also constrain the export. |
| A4 | Exporting a large date range; large-export boundary scenario | Exports above a row threshold are processed as a background job rather than failing or truncating. | Confirm that async export is in scope for v1 and set the threshold value. |
| A5 | Requesting many exports in a short period | Exports are rate-limited per user (assumed 10 per 10 minutes). | Confirm whether a rate limit applies and, if so, the cap and window. |
| A6 | Returning to a completed background export later | Completed export files are retained and downloadable for 24 hours, then purged. | Confirm the retention window for generated export files. |
| A7 | Browser blocks the automatic file download | When auto-download is blocked, an explicit manual download link is offered as a fallback. | Confirm the desired fallback behavior for blocked downloads. |
| A8 | A large background export job fails partway through | The user is notified of a failed background export via the same channel used for completion (in-app and/or email). | Confirm the notification channel(s) for background export completion and failure. |
| A9 | A transaction field contains a spreadsheet formula payload | Cell values beginning with `=`, `+`, `-`, or `@` are neutralized to prevent CSV formula injection. | Confirm the CSV-injection mitigation approach. |

## 9. Coverage Checklist

| # | Deviation category | Covered | Scenarios / Reason if N/A |
|---|--------------------|---------|---------------------------|
| 1 | Incomplete or invalid input | Yes | 3 scenarios — no range, end before start, only one endpoint selected. |
| 2 | Duplicate submission / retry | Yes | 2 scenarios — double-click, re-export of same range. |
| 3 | Rate limits, quotas, throttling | Yes | 1 scenario — export rate limit reached (assumption-flagged). |
| 4 | Connectivity loss & interruption | Yes | 2 scenarios — drop during generation, tab closed during background job. |
| 5 | Abandonment & resumption | Yes | 1 scenario — returning to a completed background export. |
| 6 | Out-of-order actions & navigation | Yes | 1 scenario — changing the range while an export is in progress. |
| 7 | Auth & permission changes mid-flow | Yes | 2 scenarios — session expiry before export and during a background job. |
| 8 | Concurrency & stale data | Yes | 2 scenarios — new transaction after page load, two-tab export. |
| 9 | Precondition satisfied / state conflict | Yes | 1 scenario — exporting an empty date range. |
| 10 | Empty, boundary & scale extremes | Yes | 4 scenarios — single-day range, new user with no history, oversized range, special characters in fields. |
| 11 | Environment & device capability | Yes | 2 scenarios — mobile browser export, blocked automatic download. |
| 12 | External dependency failure | Yes | 2 scenarios — export service error, background job failure. |
| 13 | Time, expiry & scheduling | Yes | 2 scenarios — cross-timezone interpretation, downloading an expired export file. |
| 14 | Adversarial & abuse input | Yes | 2 scenarios — CSV formula injection, request tampered to target another account. |
