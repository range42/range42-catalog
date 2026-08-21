# Layer 05 — Synthetic Exercise Worlds

This layer contains versioned, politically neutral narrative reference data for Range42
exercises. It is content, not infrastructure: nothing in this directory provisions a VM,
network, container, or service.

## Available worlds

| World | Format | Entities | License | Source |
|---|---|---:|---|---|
| Nacre | MISP Galaxy `exercise-world` v1 | 60 | CC-BY-4.0 | MISP Synthetic Exercise World Format |

Nacre contains 10 countries, 30 companies, and 20 threat actors. It does not contain
personas, infrastructure, injects, IOCs, or scoring rules.

## Layout

```text
05_world_layer/
  manifest.json
  NOTICE
  sewf/nacre/
    VERSION
    clusters/exercise-world.json
    galaxies/exercise-world.json
    derived/
```

The files under `clusters/` and `galaxies/` are byte-identical upstream snapshots. Never edit
them in place. Range42-generated lookup indexes live under `derived/`.

## References

Non-MISP consumers must store stable entity UUIDs, not display names. MISP event fixtures use
the canonical galaxy tag form `misp-galaxy:exercise-world="<entity value>"`.

## Updating Nacre

1. Review upstream changes in both `MISP/Synthetic-Exercise-World-Format` and
   `MISP/misp-galaxy`.
2. Replace the galaxy/cluster snapshots without modifying them.
3. Update `sewf/nacre/VERSION` with commits, retrieval date, and SHA-256 values.
4. Regenerate `derived/` with `python3 05_world_layer/tools/generate_indexes.py`.
5. Run `python3 -m unittest 05_world_layer/tests/test_nacre_world.py -v`.
6. Review the data and generated diff, including neutrality and name-collision checks.

See `NOTICE` for attribution and license details.
