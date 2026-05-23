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

  @deviation @rate-limit @assumption
  Scenario: Requesting many exports in a short period
    # Assumption: exports are rate-limited per user to protect the export service;
    # a default cap of 10 exports per 10 minutes is assumed and must be confirmed.
    Given the user has reached the export rate limit for the current window
    When the user clicks "Export to CSV" again
    Then no new export is generated
    And the user is told they have hit the export limit and when they can export again
    And any export already in progress or completed remains unaffected

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

  @deviation @abandon-resume @assumption
  Scenario: Returning to a completed background export later
    # Assumption: completed export files are retained and downloadable for 24 hours,
    # after which they are purged and must be re-generated. Retention window to be confirmed.
    Given the user requested a large export that completed while they were away
    When the user returns to the Transactions page within the retention window
    Then the user can download the completed export
    And the user is shown when that export file will expire

  @deviation @out-of-order
  Scenario: Changing the date range while an export is still generating
    Given the user has clicked "Export to CSV" and generation is in progress
    When the user changes the date range in the date picker before the export completes
    Then the in-progress export still reflects the range that was selected when it started
    And the new range is not applied until the user clicks "Export to CSV" again

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

  @deviation @state-conflict
  Scenario: Exporting a date range that contains no transactions
    Given the user has selected a valid date range with no transactions in it
    When the user clicks "Export to CSV"
    Then the user is told there are no transactions in the selected range
    And no empty file with only a header is downloaded unless the user confirms they still want it

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
