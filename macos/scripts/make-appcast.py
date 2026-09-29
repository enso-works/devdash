#!/usr/bin/env python3
"""Writes the Sparkle appcast for a release zip, with release notes from CHANGELOG.md.

Usage: make-appcast.py <DevDash-x.y.z-macos.zip> <version> <build number> > appcast.xml

The zip is signed with Sparkle's sign_update: the key in SPARKLE_PRIVATE_KEY (CI) or the
"devdash" key in the login keychain (created by generate_keys --account devdash).
"""

from __future__ import annotations

import html
import os
import re
import subprocess
import sys
import tempfile
from email.utils import formatdate
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SIGN_UPDATE = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
DOWNLOAD = "https://github.com/enso-works/devdash/releases/download"


def signature(archive: Path) -> str:
    """Returns the sparkle:edSignature and length attributes for the archive."""
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not key:
        return subprocess.check_output([SIGN_UPDATE, "--account", "devdash", archive], text=True).strip()
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(key)
    try:
        return subprocess.check_output([SIGN_UPDATE, "--ed-key-file", handle.name, archive], text=True).strip()
    finally:
        os.unlink(handle.name)


def release_notes(version: str) -> str:
    """Converts the CHANGELOG section for the version into simple HTML."""
    text = (REPO / "CHANGELOG.md").read_text()
    match = re.search(rf"^## {re.escape(version)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not match:
        return ""
    out: list[str] = []
    in_list = False
    for line in match.group(1).strip().splitlines():
        item = line.startswith("- ")
        if in_list and not item:
            out.append("</ul>")
            in_list = False
        if not line.strip():
            continue
        content = html.escape(line[2:] if item else line.lstrip("# "))
        content = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", content)
        content = re.sub(r"`(.+?)`", r"<code>\1</code>", content)
        if item:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{content}</li>")
        else:
            out.append(f"<h3>{content}</h3>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    archive, version, build = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    url = f"{DOWNLOAD}/v{version}/{archive.name}"
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DevDash</title>
    <item>
      <title>{version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{release_notes(version)}
      ]]></description>
      <enclosure url="{url}" {signature(archive)} type="application/octet-stream"/>
    </item>
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
