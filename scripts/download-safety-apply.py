#!/usr/bin/env python3
"""Disable untrusted indexers in Prowlarr and its existing Arr copies."""
import json
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET


def apply():
    config = Path(__file__).resolve().parents[1] / "configs/download-safety.json"
    names = json.loads(config.read_text())["disabled_indexers"]
    for service, port, version in (("prowlarr", 9696, "v1"),
                                   ("sonarr", 8989, "v3"),
                                   ("radarr", 7878, "v3")):
        key = ET.parse(f"/srv/appdata/{service}/config.xml").findtext("ApiKey")
        base = f"http://localhost:{port}/api/{version}/indexer"

        def request(url, data=None):
            req = urllib.request.Request(
                url, data=None if data is None else json.dumps(data).encode(),
                headers={"X-Api-Key": key, "Content-Type": "application/json"},
                method="GET" if data is None else "PUT")
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)

        for indexer in request(base):
            if not any(indexer["name"].casefold() in
                       (name.casefold(), f"{name} (Prowlarr)".casefold())
                       for name in names):
                continue
            fields = ["enable"] if service == "prowlarr" else [
                "enableRss", "enableAutomaticSearch", "enableInteractiveSearch"]
            if any(indexer.get(field) for field in fields):
                indexer.update({field: False for field in fields})
                request(f"{base}/{indexer['id']}", indexer)
            result = request(f"{base}/{indexer['id']}")
            if any(result.get(field) for field in fields):
                raise RuntimeError(f"{service}: indexer remains enabled")
            print(f"{service}: {indexer['name']} disabled")


if __name__ == "__main__":
    apply()
