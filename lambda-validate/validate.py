import boto3
import csv
import io

s3 = boto3.client("s3")
BUCKET = "carepulse-raw-preetham-2026"

# The columns each file MUST have, based on what we actually inspected earlier.
# Keys match the S3 object names.
EXPECTED_COLUMNS = {
    "patients.csv":    {"Id", "BIRTHDATE", "GENDER"},
    "encounters.csv":  {"Id", "START", "STOP", "PATIENT", "ENCOUNTERCLASS"},
    "conditions.csv":  {"START", "PATIENT", "CODE", "DESCRIPTION"},
    "medications.csv": {"START", "PATIENT", "CODE", "DESCRIPTION"},
    "procedures.csv":  {"START", "PATIENT", "CODE", "DESCRIPTION"},
    "observations.csv":{"DATE", "PATIENT", "CODE", "VALUE"},
}

def fetch_header_and_sample(key, sample_rows=5):
    """Read just the first chunk of an S3 object -- not the whole file --
    enough to get the header row and a few sample rows."""
    obj = s3.get_object(Bucket=BUCKET, Key=key, Range="bytes=0-8192")
    text = obj["Body"].read().decode("utf-8-sig", errors="replace")
    lines = text.splitlines()
    reader = csv.reader(lines)
    rows = list(reader)
    return rows[0] if rows else [], rows[1:sample_rows+1]

def validate_file(key):
    if key not in EXPECTED_COLUMNS:
        return {"key": key, "status": "SKIPPED", "reason": "not a tracked file"}

    try:
        header, sample = fetch_header_and_sample(key)
    except Exception as e:
        return {"key": key, "status": "REJECTED", "reason": f"could not read: {e}"}

    if not header:
        return {"key": key, "status": "REJECTED", "reason": "empty file, no header"}

    header_set = set(header)
    required = EXPECTED_COLUMNS[key]
    missing = required - header_set
    if missing:
        return {"key": key, "status": "REJECTED", "reason": f"missing columns: {missing}"}

    if not sample:
        return {"key": key, "status": "REJECTED", "reason": "header present but no data rows"}

    return {"key": key, "status": "ACCEPTED", "reason": f"{len(header)} columns, sample OK"}
def quarantine_file(key, reason):
    """Move a rejected file to quarantine/ instead of leaving it in the main prefix."""
    copy_source = {"Bucket": BUCKET, "Key": key}
    dest_key = f"quarantine/{key}"
    s3.copy_object(Bucket=BUCKET, CopySource=copy_source, Key=dest_key)
    s3.delete_object(Bucket=BUCKET, Key=key)
    print(f"  -> moved to {dest_key} (reason: {reason})")

def lambda_handler(event, context):
    results = []
    for record in event["Records"]:
        key = record["s3"]["object"]["key"]

        if key.startswith("quarantine/"):
            print(f"SKIPPED    {key:20} (quarantine write, ignored to avoid re-trigger loop)")
            continue

        result = validate_file(key)
        results.append(result)
        print(f"{result['status']:10} {result['key']:20} {result.get('reason','')}")

        if result["status"] == "REJECTED":
            quarantine_file(key, result["reason"])

    return {"results": results}


if __name__ == "__main__":
    # Local test: fake an S3 event shape, same as Lambda would receive
    fake_event = {
        "Records": [
            {"s3": {"bucket": {"name": "carepulse-raw-preetham-2026"}, "object": {"key": "encounters.csv"}}}
        ]
    }
    output = lambda_handler(fake_event, None)
    print(output)