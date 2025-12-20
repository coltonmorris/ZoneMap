#!/usr/bin/env python3
"""
Download all Kalimdor ADT tiles from wago.tools by iterating CASC file IDs.

Given:
  start id (Kalimdor_0_0.adt): 782780
  end   id (last):             787830
  step:                        5

This script:
- Downloads each URL: https://wago.tools/api/casc/<id>?download
- Uses the server-provided filename from Content-Disposition (same as your browser)
- Skips files that already exist (non-empty)
- Retries on transient errors (429/5xx/network), with backoff
- Writes atomically via a .part temp file

Example Usage:
    python3 download_kalimdor_adts.py --out kalimdor_adts --start 782780 --end 787830 --step 5 --sleep 0.2

"""

from __future__ import annotations

import argparse
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


DEFAULT_START = 782780
DEFAULT_END = 787830
DEFAULT_STEP = 5


def filename_from_content_disposition(cd: str) -> Optional[str]:
    """
    Parse Content-Disposition for filename / filename*.

    Supports:
      Content-Disposition: attachment; filename="kalimdor_0_0.adt"
      Content-Disposition: attachment; filename*=UTF-8''kalimdor_0_0.adt
    """
    if not cd:
        return None

    # RFC 5987 / 6266 style: filename*=UTF-8''...
    m = re.search(r"filename\*\s*=\s*UTF-8''([^;]+)", cd, re.IGNORECASE)
    if m:
        return urllib.parse.unquote(m.group(1))

    # filename="..."
    m = re.search(r'filename\s*=\s*"([^"]+)"', cd, re.IGNORECASE)
    if m:
        return m.group(1)

    # filename=...
    m = re.search(r"filename\s*=\s*([^;]+)", cd, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    return None


def http_download(
    url: str,
    timeout_s: int,
    headers: dict,
    retries: int,
    backoff_base_s: float,
) -> tuple[bytes, dict]:
    """
    Download URL, returning (body_bytes, response_headers_dict).

    Retries on transient HTTP errors (429, 5xx) and network timeouts.
    """
    last_err: Exception | None = None

    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                body = resp.read()
                # Convert headers to a plain dict (case-insensitive access via .get below is fine)
                hdrs = dict(resp.headers.items())
                return body, hdrs

        except urllib.error.HTTPError as e:
            # Retry on rate limiting and transient server failures
            if e.code in (429, 500, 502, 503, 504):
                last_err = e
                sleep_s = backoff_base_s * attempt
                time.sleep(sleep_s)
                continue
            raise

        except (urllib.error.URLError, TimeoutError) as e:
            last_err = e
            sleep_s = backoff_base_s * attempt
            time.sleep(sleep_s)
            continue

    raise RuntimeError(f"Failed after {retries} retries: {url} ({last_err})")


def safe_basename(name: str) -> str:
    # Prevent path traversal; keep only the base filename
    base = os.path.basename(name)
    base = base.replace("\\", "_").replace("/", "_")
    return base


def normalize_kalimdor_case(name: str, mode: str) -> str:
    """
    mode:
      - "as-is": keep server-provided filename
      - "capitalize": change leading 'kalimdor_' -> 'Kalimdor_'
      - "lower": change leading 'Kalimdor_' -> 'kalimdor_'
    """
    if mode == "as-is":
        return name
    if mode == "capitalize":
        if name.startswith("kalimdor_"):
            return "Kalimdor_" + name[len("kalimdor_") :]
        return name
    if mode == "lower":
        if name.startswith("Kalimdor_"):
            return "kalimdor_" + name[len("Kalimdor_") :]
        return name
    return name


def main() -> int:
    ap = argparse.ArgumentParser(description="Download Kalimdor ADTs from wago.tools CASC API.")
    ap.add_argument("--out", default="kalimdor_adts", help="Output directory")
    ap.add_argument("--start", type=int, default=DEFAULT_START, help="First CASC file id (inclusive)")
    ap.add_argument("--end", type=int, default=DEFAULT_END, help="Last CASC file id (inclusive)")
    ap.add_argument("--step", type=int, default=DEFAULT_STEP, help="Increment between file ids")
    ap.add_argument("--timeout", type=int, default=60, help="HTTP timeout (seconds)")
    ap.add_argument("--retries", type=int, default=6, help="Retries for transient errors")
    ap.add_argument("--backoff", type=float, default=1.5, help="Backoff base seconds (multiplied by attempt)")
    ap.add_argument("--sleep", type=float, default=0.0, help="Sleep between downloads (seconds)")
    ap.add_argument(
        "--name-case",
        choices=["as-is", "capitalize", "lower"],
        default="as-is",
        help="Normalize 'kalimdor_' filename casing",
    )
    args = ap.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    headers = {
        "User-Agent": "kalimdor-adt-downloader/1.0",
        "Accept": "*/*",
    }

    total = ((args.end - args.start) // args.step) + 1
    ok = 0
    missing_404 = 0
    failed = 0

    for idx, file_id in enumerate(range(args.start, args.end + 1, args.step), start=1):
        url = f"https://wago.tools/api/casc/{file_id}?download"

        print(f"[{idx}/{total}] id={file_id} ... ", end="", flush=True)

        try:
            body, resp_headers = http_download(
                url=url,
                timeout_s=args.timeout,
                headers=headers,
                retries=args.retries,
                backoff_base_s=args.backoff,
            )

            cd = resp_headers.get("Content-Disposition", "") or resp_headers.get("content-disposition", "")
            server_name = filename_from_content_disposition(cd) or f"kalimdor_{file_id}.adt"
            server_name = safe_basename(server_name)
            server_name = normalize_kalimdor_case(server_name, args.name_case)

            dest = outdir / server_name
            tmp = outdir / (server_name + ".part")

            # Skip if already present and non-empty
            if dest.exists() and dest.stat().st_size > 0:
                print(f"skip (exists) -> {dest.name}")
                ok += 1
            else:
                if not body:
                    raise RuntimeError("Empty response body")

                with open(tmp, "wb") as f:
                    f.write(body)
                tmp.replace(dest)

                print(f"ok -> {dest.name} ({dest.stat().st_size} bytes)")
                ok += 1

        except urllib.error.HTTPError as e:
            if e.code == 404:
                print("404 (missing)")
                missing_404 += 1
            else:
                print(f"HTTP {e.code}: {e.reason}")
                failed += 1

        except Exception as e:
            print(f"FAILED: {e}")
            failed += 1

        if args.sleep > 0:
            time.sleep(args.sleep)

    print("\nDone.")
    print(f"  downloaded/kept: {ok}")
    print(f"  404 missing:     {missing_404}")
    print(f"  failed:          {failed}")
    print(f"  output dir:      {outdir.resolve()}")
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
