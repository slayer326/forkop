#!/usr/bin/env python3
"""Build sing-box source rule sets from YOZH3G/ru-gaming-blocklist game lists.

Each upstream games/<Name>.txt file holds one domain or CIDR per line. The
script converts the selected lists into source-format rule set documents
({"version": 3, "rules": [...]}) that sing-box fetches directly, so routers do
not need the binary .srs toolchain. Output is deterministic (sorted entries),
which lets CI publish only on real changes.

Games already covered by the vendor rule sets of the built-in catalogue
(Battle.net, EA, Epic, Riot, Roblox, Steam, Ubisoft, League of Legends) and
the auxiliary Cloudflare/AWS profile are not duplicated here; the UI picker in
fe-app-forkop/src/constants.ts (SECONDARY_GAME_RULESET_OPTIONS) lists exactly
the rule set ids produced by this script.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
import urllib.request
from pathlib import Path

UPSTREAM_REPO = "YOZH3G/ru-gaming-blocklist"
UPSTREAM_BRANCH = "main"
GAMES_API_URL = (
    f"https://api.github.com/repos/{UPSTREAM_REPO}/contents/games"
    f"?ref={UPSTREAM_BRANCH}"
)
GAMES_RAW_URL = (
    f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{UPSTREAM_BRANCH}/games"
)

# Covered by the built-in vendor rule sets (blizzard, electronicarts,
# epicgames, riot, roblox, valve, ubisoft) or auxiliary (Cloudflare_AWS).
EXCLUDED_FILES = {
    "BattleNet.txt",
    "Cloudflare_AWS.txt",
    "EA_Origin.txt",
    "EpicGames_Fortnite.txt",
    "LeagueOfLegends.txt",
    "RiotGames_Valorant.txt",
    "Roblox.txt",
    "Steam.txt",
    "Ubisoft_Rainbow_Six_Siege.txt",
}

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?"
                       r"(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "forkop-ruleset-build"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def list_game_files() -> list[str]:
    listing = json.loads(fetch(GAMES_API_URL))
    names = [
        entry["name"]
        for entry in listing
        if entry.get("type") == "file" and entry["name"].endswith(".txt")
    ]
    return sorted(name for name in names if name not in EXCLUDED_FILES)


def parse_list(text: str) -> tuple[list[str], list[str], int]:
    """Split list lines into (domain_suffix entries, ip_cidr entries, skipped)."""
    domains: set[str] = set()
    cidrs: set[str] = set()
    skipped = 0

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        candidate = line
        if candidate.startswith("*."):
            candidate = candidate[2:]
        elif candidate.startswith("."):
            candidate = candidate[1:]
        candidate = candidate.strip().lower()
        if not candidate:
            skipped += 1
            continue

        try:
            if "/" in candidate:
                cidrs.add(str(ipaddress.ip_network(candidate, strict=False)))
                continue
            address = ipaddress.ip_address(candidate)
        except ValueError:
            address = None
        if address is not None:
            suffix = 32 if address.version == 4 else 128
            cidrs.add(f"{address}/{suffix}")
            continue

        if DOMAIN_RE.match(candidate):
            # domain_suffix matches the name itself and every subdomain, which
            # is how the community lists treat one-domain-per-line entries.
            domains.add(candidate)
        else:
            skipped += 1

    return sorted(domains), sorted(cidrs, key=_cidr_sort_key), skipped


def _cidr_sort_key(value: str) -> tuple[int, int, int]:
    network = ipaddress.ip_network(value)
    return (network.version, int(network.network_address), network.prefixlen)


def build_ruleset(domains: list[str], cidrs: list[str]) -> dict:
    rule: dict[str, list[str]] = {}
    if domains:
        rule["domain_suffix"] = domains
    if cidrs:
        rule["ip_cidr"] = cidrs
    return {"version": 3, "rules": [rule] if rule else []}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Directory that receives one <id>.json rule set per game list.",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)

    names = list_game_files()
    if not names:
        print("no game lists found upstream", file=sys.stderr)
        return 1

    total_skipped = 0
    for name in names:
        ruleset_id = name[:-4].lower()
        text = fetch(f"{GAMES_RAW_URL}/{name}").decode("utf-8")
        domains, cidrs, skipped = parse_list(text)
        total_skipped += skipped
        document = build_ruleset(domains, cidrs)
        target = args.output / f"{ruleset_id}.json"
        target.write_text(
            json.dumps(document, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(
            f"{ruleset_id}: {len(domains)} domains, {len(cidrs)} subnets"
            + (f", {skipped} lines skipped" if skipped else "")
        )

    if total_skipped:
        print(f"warning: {total_skipped} unparsable lines skipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
