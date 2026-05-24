FAIL

- The `Then the response status is 200` and `And the response includes the URL of the stored avatar` clauses are implemented for the happy path: the route stores the upload and returns `avatar_url`.
- The `And the uploaded file is rejected if it is larger than 5 MB` clause is not implemented. The route reads the entire file and stores it without any size check.
- The `And the uploaded file is rejected if it is not a PNG or JPEG` clause is not implemented. The service accepts and stores any `content_type`.
- Scenario drift: no obvious extra behavior beyond storing the uploaded avatar was added.

Should commit: no. This scenario is not ready until size and PNG/JPEG validation are implemented.
