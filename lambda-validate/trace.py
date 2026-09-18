from validate import s3, BUCKET, EXPECTED_COLUMNS
import csv

def fetch_header_and_sample_TRACED(key, sample_rows=5):
    print(f"\n--- fetch_header_and_sample('{key}') called ---")
    
    obj = s3.get_object(Bucket=BUCKET, Key=key, Range="bytes=0-8192")
    print(f"1) got response from S3, obj type = {type(obj)}")
    
    raw_bytes = obj["Body"].read()
    print(f"2) raw_bytes = first 60 bytes shown: {raw_bytes[:60]}")
    
    text = raw_bytes.decode("utf-8-sig", errors="replace")
    print(f"3) text (decoded string) = first 80 chars: {text[:80]!r}")
    
    lines = text.splitlines()
    print(f"4) lines = split into {len(lines)} lines, first line = {lines[0]!r}")
    
    reader = csv.reader(lines)
    rows = list(reader)
    print(f"5) rows = parsed as CSV, {len(rows)} rows total")
    print(f"   rows[0] (the header) = {rows[0]}")
    print(f"   rows[1] (first data row) = {rows[1]}")
    
    header = rows[0]
    sample = rows[1:sample_rows+1]
    print(f"6) RETURNING: header={header}")
    print(f"   RETURNING: sample = {len(sample)} rows")
    return header, sample


def validate_file_TRACED(key):
    print(f"\n=== validate_file('{key}') called ===")
    
    if key not in EXPECTED_COLUMNS:
        print("-> key not tracked, returning SKIPPED")
        return {"key": key, "status": "SKIPPED"}
    
    header, sample = fetch_header_and_sample_TRACED(key)
    
    print(f"\n7) back in validate_file. header = {header}")
    header_set = set(header)
    print(f"8) header_set (as a set) = {header_set}")
    
    required = EXPECTED_COLUMNS[key]
    print(f"9) required (from our rulebook) = {required}")
    
    missing = required - header_set
    print(f"10) missing = required - header_set = {missing}")
    
    if missing:
        print("-> missing is non-empty, returning REJECTED")
        return {"key": key, "status": "REJECTED", "reason": f"missing columns: {missing}"}
    
    print("-> nothing missing, returning ACCEPTED")
    return {"key": key, "status": "ACCEPTED"}


if __name__ == "__main__":
    result = validate_file_TRACED("encounters.csv")
    print(f"\n=== FINAL RESULT: {result} ===")