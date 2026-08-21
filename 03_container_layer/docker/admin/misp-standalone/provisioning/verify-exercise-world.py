#!/usr/bin/env python3
"""Fail provisioning unless the pinned Synthetic Exercise World is loaded."""

from __future__ import annotations

import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen


EXPECTED_GALAXY_UUID = "3c3de5f0-5982-4c7f-88cf-8abf43b8d6c1"
EXPECTED_COLLECTION_UUID = "7d6d7f2f-b3d4-4bc5-9f27-43e12f7f4658"
EXPECTED_ENTITY_COUNT = 60


class ExerciseWorldVerificationError(ValueError):
    pass


def _list_items(payload: Any) -> list[Any]:
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("response", "Galaxies", "galaxies"):
        if isinstance(payload.get(key), list):
            return payload[key]
    if isinstance(payload.get("Galaxy"), list):
        return payload["Galaxy"]
    return [payload]


def find_exercise_world_galaxy(payload: Any) -> str:
    for item in _list_items(payload):
        galaxy = item.get("Galaxy", item) if isinstance(item, dict) else {}
        if galaxy.get("type") != "exercise-world":
            continue
        if galaxy.get("uuid") != EXPECTED_GALAXY_UUID:
            raise ExerciseWorldVerificationError(
                f"exercise-world galaxy UUID mismatch: {galaxy.get('uuid')}"
            )
        galaxy_id = galaxy.get("id")
        if galaxy_id is None:
            raise ExerciseWorldVerificationError("exercise-world galaxy is missing its database id")
        return str(galaxy_id)
    raise ExerciseWorldVerificationError("exercise-world galaxy is not loaded")


def verify_cluster_payload(payload: Any) -> None:
    root = payload.get("Galaxy", payload) if isinstance(payload, dict) else {}
    clusters = payload.get("GalaxyCluster") if isinstance(payload, dict) else None
    if not isinstance(clusters, list) and isinstance(root, dict):
        clusters = root.get("GalaxyCluster")
    if not isinstance(clusters, list):
        raise ExerciseWorldVerificationError("exercise-world response has no GalaxyCluster list")

    normalized = [
        item.get("GalaxyCluster", item) if isinstance(item, dict) else {}
        for item in clusters
    ]
    if len(normalized) != EXPECTED_ENTITY_COUNT:
        raise ExerciseWorldVerificationError(
            f"exercise-world entity count mismatch: expected {EXPECTED_ENTITY_COUNT}, got {len(normalized)}"
        )

    entity_uuids = {item.get("uuid") for item in normalized}
    if None in entity_uuids or len(entity_uuids) != EXPECTED_ENTITY_COUNT:
        raise ExerciseWorldVerificationError("exercise-world entity UUIDs are missing or duplicated")
    collection_uuids = {item.get("collection_uuid") for item in normalized}
    if collection_uuids != {EXPECTED_COLLECTION_UUID}:
        raise ExerciseWorldVerificationError(
            f"exercise-world collection UUID mismatch: {sorted(str(value) for value in collection_uuids)}"
        )


def misp_get(base_url: str, auth_key: str, path: str) -> Any:
    request = Request(
        f"{base_url.rstrip('/')}{path}",
        headers={"Authorization": auth_key, "Accept": "application/json"},
    )
    context = ssl._create_unverified_context()
    with urlopen(request, context=context, timeout=30) as response:
        return json.load(response)


def main() -> int:
    base_url = os.environ.get("MISP_URL", "https://misp")
    key_file = Path(os.environ.get("MISP_ADMIN_KEY_FILE", "/keys/admin-authkey"))
    try:
        auth_key = key_file.read_text(encoding="utf-8").strip()
        if not auth_key:
            raise ExerciseWorldVerificationError(f"empty admin auth key: {key_file}")
        galaxy_id = find_exercise_world_galaxy(misp_get(base_url, auth_key, "/galaxies/index.json"))
        verify_cluster_payload(misp_get(base_url, auth_key, f"/galaxies/view/{galaxy_id}.json"))
    except (OSError, json.JSONDecodeError, ExerciseWorldVerificationError) as exc:
        print(f"[verify-exercise-world] ERROR: {exc}", file=sys.stderr)
        return 1

    print(
        f"[verify-exercise-world] verified galaxy {EXPECTED_GALAXY_UUID} "
        f"with {EXPECTED_ENTITY_COUNT} entities",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
