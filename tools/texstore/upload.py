"""Upload the local store to Cloudflare R2: objects R2 doesn't have yet, then the images/ pointers.

  uv run --no-project --with boto3 python -I tools/texstore/upload.py [--dry-run] [-j N]

Credentials come from the macOS Keychain, never from the repo: one generic password, service `taudot-r2`, whose
value is JSON {"account_id": ..., "bucket": ..., "access_key_id": ..., "secret_access_key": ...}, made with
  security add-generic-password -s taudot-r2 -a texstore -w '<json>'
The token only needs Object Read & Write on the one bucket.

R2's own listing decides what is new (ListObjectsV2, 1,000 keys a call), so an interrupted upload resumes, and
objects are never rewritten: a key under files/ names its content.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import texstore as ts  # noqa: E402

IMMUTABLE = "public, max-age=31536000, immutable"


def creds():
    r = subprocess.run(["security", "find-generic-password", "-s", "taudot-r2", "-w"], capture_output=True, text=True)
    if r.returncode:
        sys.exit("no Keychain item `taudot-r2` (see this script's docstring)")
    return json.loads(r.stdout)


def local_keys():
    keys = {f"files/{n}" for n in os.listdir(os.path.join(ts.STORE, "files")) if len(n) == 128}
    images = []
    d = os.path.join(ts.STORE, "images")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        images += [f"images/{name}/{date}" for date in sorted(os.listdir(os.path.join(d, name)))]
    return keys, images


def main(a):
    dry = "--dry-run" in a
    jobs = int(a[a.index("-j") + 1]) if "-j" in a else 32
    import boto3
    from botocore.config import Config
    c = creds()
    s3 = boto3.client("s3", endpoint_url=f"https://{c['account_id']}.r2.cloudflarestorage.com",
                      aws_access_key_id=c["access_key_id"], aws_secret_access_key=c["secret_access_key"],
                      region_name="auto", config=Config(max_pool_connections=jobs, retries={"max_attempts": 5}))
    bucket = c["bucket"]
    have = set()
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="files/"):
        have |= {o["Key"] for o in page.get("Contents", [])}
    keys, images = local_keys()
    todo = sorted(keys - have)
    nbytes = sum(os.path.getsize(os.path.join(ts.STORE, k)) for k in todo)
    print(f"{len(keys)} objects locally, {len(have)} in R2, {len(todo)} to upload ({nbytes / 1e9:.2f} GB)", flush=True)
    if dry:
        return 0

    def put(k, ctype, cache):
        with open(os.path.join(ts.STORE, k), "rb") as f:
            s3.put_object(Bucket=bucket, Key=k, Body=f.read(), ContentType=ctype, CacheControl=cache)

    done, fails = 0, []
    with ThreadPoolExecutor(jobs) as ex:
        futs = {ex.submit(put, k, "application/gzip", IMMUTABLE): k for k in todo}
        for fu in as_completed(futs):
            try:
                fu.result()
            except Exception as e:  # noqa: BLE001 - listed at the end; a rerun retries
                fails.append(f"{futs[fu]}: {e}")
            done += 1
            if done % 5000 == 0:
                print(f"  {done}/{len(todo)}", flush=True)
    if fails:
        print("\n".join(fails[:20]))
        sys.exit(f"{len(fails)} uploads failed; images/ pointers not written. Rerun to retry.")
    # Pointers last, so an image is only visible once everything it names is there.
    for k in images:
        put(k, "text/plain", "public, max-age=300")
        print(f"{k}: written")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
