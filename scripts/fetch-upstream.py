#!/usr/bin/env python3
"""Fetch the official macOS OpenAI Codex Sparkle appcasts and emit release metadata.

Parses both the arm64 feed and the x64 feed, takes the newest <item> of each,
and prints a JSON document with version, build, pubDate, download URLs and
lengths per architecture, plus the canonical release tag:

    v<shortVersionString>-b<sparkle:version>   e.g. v26.901.41600-b7982

Stdlib only. Network access via urllib.

Usage:
    scripts/fetch-upstream.py [--arch arm64|x64|all] [--tag-only] [--json]
                              [--timeout SECONDS] [--json-indent N]
    scripts/fetch-upstream.py --help

Output is always JSON; --json is accepted for consistency with the other
scripts and changes nothing.
"""

import argparse
import json
import sys
import urllib.request
import xml.etree.ElementTree as ET

APPCAST_ARM64 = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
APPCAST_X64 = "https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml"

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def fetch_text(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "kodex-fetch/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="replace")


def parse_latest_item(xml_text):
    """Return dict(version, build, pubDate, url, length) for the first <item>."""
    root = ET.fromstring(xml_text)
    item = root.find("./channel/item")
    if item is None:
        raise ValueError("appcast contains no channel/item entries")

    def text_of(tag):
        el = item.find(tag)
        return el.text.strip() if el is not None and el.text else ""

    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("latest appcast item has no enclosure")

    version = text_of(SPARKLE_NS + "shortVersionString") or text_of("title")
    build = text_of(SPARKLE_NS + "version")
    if not version:
        raise ValueError("latest appcast item has no version")
    if not build:
        raise ValueError("latest appcast item has no build number")

    length_raw = (enclosure.get("length") or "").strip()
    try:
        length = int(length_raw) if length_raw else None
    except ValueError:
        length = None

    return {
        "version": version,
        "build": build,
        "pubDate": text_of("pubDate"),
        "url": (enclosure.get("url") or "").strip(),
        "length": length,
    }


def canonical_tag(version, build):
    return "v%s-b%s" % (version, build)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Fetch Codex macOS appcasts and emit upstream release metadata."
    )
    parser.add_argument(
        "--arch",
        choices=("arm64", "x64", "all"),
        default="all",
        help="which architecture entry to emit (default: all)",
    )
    parser.add_argument(
        "--tag-only",
        action="store_true",
        help="print only the canonical tag (single line)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="accepted for consistency; output is always JSON",
    )
    parser.add_argument(
        "--timeout", type=int, default=30, help="HTTP timeout in seconds"
    )
    parser.add_argument(
        "--json-indent", type=int, default=2, help="JSON indent (0 for compact)"
    )
    args = parser.parse_args(argv)

    feeds = {"arm64": APPCAST_ARM64, "x64": APPCAST_X64}
    if args.arch != "all":
        feeds = {args.arch: feeds[args.arch]}

    try:
        entries = {}
        for arch, url in feeds.items():
            entries[arch] = parse_latest_item(fetch_text(url, args.timeout))
            entries[arch]["feed"] = url
    except Exception as exc:  # network or parse failure -> stderr, nonzero exit
        print("fetch-upstream: error: %s" % exc, file=sys.stderr)
        return 2

    if args.tag_only:
        if args.arch == "all":
            tags = {
                canonical_tag(e["version"], e["build"]) for e in entries.values()
            }
            if len(tags) == 1:
                print(tags.pop())
            else:
                # Feeds disagree; emit per-arch tags so callers notice.
                for arch in sorted(entries):
                    e = entries[arch]
                    print("%s=%s" % (arch, canonical_tag(e["version"], e["build"])))
        else:
            e = entries[args.arch]
            print(canonical_tag(e["version"], e["build"]))
        return 0

    doc = {"architectures": entries}
    if args.arch == "all":
        arm, x64 = entries.get("arm64"), entries.get("x64")
        if (
            arm is not None
            and x64 is not None
            and (arm["version"], arm["build"]) == (x64["version"], x64["build"])
        ):
            doc["version"] = arm["version"]
            doc["build"] = arm["build"]
            doc["pubDate"] = arm["pubDate"]
            doc["tag"] = canonical_tag(arm["version"], arm["build"])
            doc["feeds_in_agreement"] = True
        else:
            # Feeds disagree: no single canonical tag; report per-arch tags.
            doc["feeds_in_agreement"] = False
            for arch, e in entries.items():
                e["tag"] = canonical_tag(e["version"], e["build"])
    else:
        e = entries[args.arch]
        doc.update(
            {
                "version": e["version"],
                "build": e["build"],
                "pubDate": e["pubDate"],
                "tag": canonical_tag(e["version"], e["build"]),
            }
        )

    indent = None if args.json_indent == 0 else args.json_indent
    print(json.dumps(doc, indent=indent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
