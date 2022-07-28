# aws-helpers

Assorted scripts I occasionally use for AWS.

## s3:links

A script to create presigned links for the files in s3.

Parameters:

- Bucket (required): string
- Key (required): string
- outputType (optional): "logJson" | "logPretty"

Example:

```bash
yarn s3:links --Bucket=my-bucket --Prefix=event-b-roll --outputType=logPretty
```
