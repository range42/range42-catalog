#!/usr/bin/env python3
"""Validate the pinned Nacre world and generate deterministic lookup indexes."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


WORLD_LAYER = Path(__file__).resolve().parents[1]
NACRE = WORLD_LAYER / "sewf" / "nacre"
CLUSTER_PATH = NACRE / "clusters" / "exercise-world.json"
GALAXY_PATH = NACRE / "galaxies" / "exercise-world.json"
DERIVED = NACRE / "derived"

EXPECTED_GALAXY_UUID = "3c3de5f0-5982-4c7f-88cf-8abf43b8d6c1"
EXPECTED_COLLECTION_UUID = "7d6d7f2f-b3d4-4bc5-9f27-43e12f7f4658"
EXPECTED_COUNTS = {"country": 10, "company": 30, "threat-actor": 20}


class WorldValidationError(ValueError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def one(meta: dict[str, Any], key: str, entity: str) -> str:
    values = meta.get(key)
    if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], str) or not values[0]:
        raise WorldValidationError(f"{entity}: meta.{key} must contain exactly one non-empty string")
    return values[0]


def validate_and_group(
    cluster: dict[str, Any], galaxy: dict[str, Any]
) -> tuple[dict[str, list[dict[str, Any]]], str]:
    if galaxy.get("uuid") != EXPECTED_GALAXY_UUID:
        raise WorldValidationError("unexpected Nacre galaxy UUID")
    if cluster.get("uuid") != EXPECTED_COLLECTION_UUID:
        raise WorldValidationError("unexpected Nacre collection UUID")
    if galaxy.get("type") != cluster.get("type") or cluster.get("type") != "exercise-world":
        raise WorldValidationError("galaxy and cluster types must both be exercise-world")
    if galaxy.get("version") != cluster.get("version") or cluster.get("version") != 1:
        raise WorldValidationError("galaxy and cluster versions must both be 1")

    values = cluster.get("values")
    if not isinstance(values, list):
        raise WorldValidationError("cluster.values must be an array")

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    uuids: set[str] = set()
    names: set[str] = set()
    planets: set[str] = set()

    for item in values:
        name = item.get("value")
        entity_uuid = item.get("uuid")
        meta = item.get("meta")
        if not isinstance(name, str) or not name:
            raise WorldValidationError("every entity must have a non-empty value")
        if not isinstance(entity_uuid, str) or not entity_uuid:
            raise WorldValidationError(f"{name}: missing uuid")
        if entity_uuid in uuids:
            raise WorldValidationError(f"duplicate entity uuid: {entity_uuid}")
        if name in names:
            raise WorldValidationError(f"duplicate entity value: {name}")
        if not isinstance(meta, dict):
            raise WorldValidationError(f"{name}: missing meta object")
        for key, meta_values in meta.items():
            if not isinstance(meta_values, list) or not all(isinstance(value, str) for value in meta_values):
                raise WorldValidationError(f"{name}: meta.{key} must be an array of strings")

        entity_type = one(meta, "entity-type", name)
        planet = one(meta, "planet", name)
        if entity_type not in EXPECTED_COUNTS:
            raise WorldValidationError(f"{name}: unsupported entity type {entity_type}")

        uuids.add(entity_uuid)
        names.add(name)
        planets.add(planet)
        grouped[entity_type].append(item)

    if planets != {"Nacre"}:
        raise WorldValidationError(f"all entities must belong to Nacre, got {sorted(planets)}")
    actual_counts = {entity_type: len(grouped[entity_type]) for entity_type in EXPECTED_COUNTS}
    if actual_counts != EXPECTED_COUNTS:
        raise WorldValidationError(f"unexpected entity counts: {actual_counts}")

    countries = {item["value"] for item in grouped["country"]}
    for company in grouped["company"]:
        headquarters = one(company["meta"], "headquarters", company["value"])
        if headquarters not in countries:
            raise WorldValidationError(f"{company['value']}: unknown headquarters {headquarters}")
    for actor in grouped["threat-actor"]:
        origin = one(actor["meta"], "origin", actor["value"])
        if origin not in countries:
            raise WorldValidationError(f"{actor['value']}: unknown origin {origin}")

    for items in grouped.values():
        items.sort(key=lambda item: (item["value"].casefold(), item["uuid"]))
    return dict(grouped), "Nacre"


def render_documents(cluster: dict[str, Any], grouped: dict[str, list[dict[str, Any]]], planet: str) -> dict[Path, str]:
    country_uuids = {item["value"]: item["uuid"] for item in grouped["country"]}
    index = {
        "schema_version": "1.0",
        "world": {
            "name": cluster["name"],
            "planet": planet,
            "type": cluster["type"],
            "uuid": cluster["uuid"],
            "version": cluster["version"],
        },
        "countries": grouped["country"],
        "companies": grouped["company"],
        "threat_actors": grouped["threat-actor"],
    }

    by_sector: dict[str, list[dict[str, str]]] = defaultdict(list)
    for company in grouped["company"]:
        headquarters = one(company["meta"], "headquarters", company["value"])
        sector = one(company["meta"], "sector", company["value"])
        by_sector[sector].append(
            {
                "uuid": company["uuid"],
                "value": company["value"],
                "headquarters": headquarters,
                "headquarters_uuid": country_uuids[headquarters],
            }
        )
    sectors = {
        "schema_version": "1.0",
        "world_uuid": cluster["uuid"],
        "sectors": {key: by_sector[key] for key in sorted(by_sector, key=str.casefold)},
    }

    return {
        DERIVED / "entities.index.json": json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        DERIVED / "by-sector.json": json.dumps(sectors, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated indexes are missing or stale")
    args = parser.parse_args()

    try:
        cluster = load_json(CLUSTER_PATH)
        galaxy = load_json(GALAXY_PATH)
        grouped, planet = validate_and_group(cluster, galaxy)
        documents = render_documents(cluster, grouped, planet)
    except (OSError, json.JSONDecodeError, WorldValidationError) as exc:
        parser.error(str(exc))

    if args.check:
        stale = [path for path, expected in documents.items() if not path.is_file() or path.read_text() != expected]
        if stale:
            for path in stale:
                print(f"stale generated file: {path.relative_to(WORLD_LAYER)}")
            return 1
        return 0

    DERIVED.mkdir(parents=True, exist_ok=True)
    for path, content in documents.items():
        path.write_text(content, encoding="utf-8")
        print(f"wrote {path.relative_to(WORLD_LAYER)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
