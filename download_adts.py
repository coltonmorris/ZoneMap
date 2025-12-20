#!/usr/bin/env python3
"""
Download WoW ADT tiles from wago.tools CASC API.

Recommended: use --manifest with lines like:
  782830;world/maps/kalimdor/kalimdor_1_2.adt
  782831;world/maps/kalimdor/kalimdor_1_2_obj0.adt
  ...

Range mode exists, but add a safety cap because large ranges will include unrelated files.
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
from typing import Iterable, Optional, Tuple


ADT_NAME_RE = re.compile(
    r"^(kalimdor|azeroth)_(\d+)_(\d+)(?:_(?:obj|tex)\d+|_lod)?\.adt$",
    re.IGNORECASE,
)


def filename_from_content_disposition(cd: str) -> Optional[str]:
    """Parse Content-Disposition for filename / filename*."""
    if not cd:
        return None

    m = re.search(r"filename\*\s*=\s*UTF-8''([^;]+)", cd, re.IGNORECASE)
    if m:
        return urllib.parse.unquote(m.group(1))

    m = re.search(r'filename\s*=\s*"([^"]+)"', cd, re.IGNORECASE)
    if m:
        return m.group(1)

    m = re.search(r"filename\s*=\s*([^;]+)", cd, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    return None


def safe_basename(name: str) -> str:
    base = os.path.basename(name)
    return base.replace("\\", "_").replace("/", "_")


def http_download(
    url: str,
    timeout_s: int,
    headers: dict,
    retries: int,
    backoff_base_s: float,
) -> Tuple[bytes, dict]:
    """Download URL, returning (body_bytes, response_headers_dict)."""
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                return resp.read(), dict(resp.headers.items())
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504):
                last_err = e
                time.sleep(backoff_base_s * attempt)
                continue
            raise
        except (urllib.error.URLError, TimeoutError) as e:
            last_err = e
            time.sleep(backoff_base_s * attempt)
            continue
    raise RuntimeError(f"Failed after {retries} retries: {url} ({last_err})")


def iter_ids_from_range(start: int, end: int, step: int) -> Iterable[int]:
    return range(start, end + 1, step)


def iter_ids_from_manifest(manifest_path: Path, want_prefix: Optional[str]) -> Iterable[int]:
    """
    Manifest format: <id>;<path>
    Filters to paths starting with want_prefix if provided.
    """
    with manifest_path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ";" not in line:
                continue
            left, right = line.split(";", 1)
            left = left.strip()
            right = right.strip().lower()

            if want_prefix and not right.startswith(want_prefix.lower()):
                continue
            if not right.endswith(".adt"):
                continue

            try:
                yield int(left)
            except ValueError:
                continue


def looks_like_adt_filename(fname: str, allow_map: Optional[str]) -> bool:
    """
    Verify server-provided filename is an ADT we care about, e.g.:
      kalimdor_1_2.adt
      kalimdor_1_2_obj0.adt
      kalimdor_1_2_tex1.adt
      kalimdor_1_2_lod.adt
      azeroth_12_34.adt
    """
    m = ADT_NAME_RE.match(fname)
    if not m:
        return False
    if allow_map and m.group(1).lower() != allow_map.lower():
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Download ADT tiles from wago.tools CASC API.")
    ap.add_argument("--out", default="adts_out", help="Output directory")

    # Manifest mode (recommended)
    ap.add_argument("--manifest", type=str, default=None, help="Path to '<id>;<path>' manifest file")
    ap.add_argument("--want-prefix", type=str, default=None,
                    help="Filter manifest paths, e.g. 'world/maps/azeroth/' or 'world/maps/kalimdor/'")

    # Range mode (use only if you really trust the range)
    ap.add_argument("--start", type=int, default=None)
    ap.add_argument("--end", type=int, default=None)
    ap.add_argument("--step", type=int, default=5)

    # Behavior / safety
    ap.add_argument("--map", choices=["kalimdor", "azeroth", "any"], default="any",
                    help="Only keep files whose server filename matches this map")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--retries", type=int, default=6)
    ap.add_argument("--backoff", type=float, default=1.5)
    ap.add_argument("--sleep", type=float, default=0.0)
    ap.add_argument("--max-count", type=int, default=20000,
                    help="Safety cap on number of IDs processed (range mode).")
    ap.add_argument("--force", action="store_true",
                    help="Allow processing more than --max-count IDs (range mode).")
    args = ap.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    headers = {"User-Agent": "adt-downloader/1.0", "Accept": "*/*"}

    allow_map = None if args.map == "any" else args.map

    # Choose input mode
    if args.manifest:
        ids = list(iter_ids_from_manifest(Path(args.manifest), args.want_prefix))
        mode = "manifest"
    else:
        if args.start is None or args.end is None:
            raise SystemExit("Range mode requires --start and --end (or use --manifest).")
        ids = list(iter_ids_from_range(args.start, args.end, args.step))
        mode = "range"

        if not args.force and len(ids) > args.max_count:
            raise SystemExit(
                f"Refusing to process {len(ids)} IDs in range mode (cap {args.max_count}). "
                f"This looks like an untrusted range. Use --manifest, or pass --force."
            )

    total = len(ids)
    ok = 0
    skipped_nonadt = 0
    missing_404 = 0
    failed = 0

    print(f"Mode: {mode}, total IDs: {total}, output: {outdir.resolve()}")

    for i, file_id in enumerate(ids, start=1):
        url = f"https://wago.tools/api/casc/{file_id}?download"
        print(f"[{i}/{total}] id={file_id} ... ", end="", flush=True)

        try:
            body, resp_headers = http_download(url, args.timeout, headers, args.retries, args.backoff)

            cd = resp_headers.get("Content-Disposition", "") or resp_headers.get("content-disposition", "")
            server_name = filename_from_content_disposition(cd) or f"{file_id}.bin"
            server_name = safe_basename(server_name)

            if not looks_like_adt_filename(server_name, allow_map):
                print(f"skip (not ADT name) -> {server_name}")
                skipped_nonadt += 1
                continue

            dest = outdir / server_name
            tmp = outdir / (server_name + ".part")

            if dest.exists() and dest.stat().st_size > 0:
                print(f"skip (exists) -> {dest.name}")
                ok += 1
                continue

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
    print(f"  ok:              {ok}")
    print(f"  skipped_nonadt:  {skipped_nonadt}")
    print(f"  404 missing:     {missing_404}")
    print(f"  failed:          {failed}")
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
