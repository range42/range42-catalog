import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORLD_LAYER = ROOT / "05_world_layer"
NACRE = WORLD_LAYER / "sewf" / "nacre"
MISP_STACK = ROOT / "03_container_layer" / "docker" / "admin" / "misp-standalone"


class NacrePackageTests(unittest.TestCase):
    def test_required_upstream_package_files_exist(self) -> None:
        required = [
            WORLD_LAYER / "README.md",
            WORLD_LAYER / "NOTICE",
            WORLD_LAYER / "manifest.json",
            NACRE / "VERSION",
            NACRE / "clusters" / "exercise-world.json",
            NACRE / "galaxies" / "exercise-world.json",
        ]

        missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
        self.assertEqual([], missing, f"missing world package files: {missing}")

    def test_generated_indexes_are_current_and_relationally_valid(self) -> None:
        generator = WORLD_LAYER / "tools" / "generate_indexes.py"
        result = subprocess.run(
            [sys.executable, str(generator), "--check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

        with (NACRE / "derived" / "entities.index.json").open() as handle:
            index = json.load(handle)
        with (NACRE / "derived" / "by-sector.json").open() as handle:
            sectors = json.load(handle)

        self.assertEqual(10, len(index["countries"]))
        self.assertEqual(30, len(index["companies"]))
        self.assertEqual(20, len(index["threat_actors"]))
        self.assertEqual(30, sum(len(companies) for companies in sectors["sectors"].values()))

    def test_catalog_manifest_registers_the_world_layer(self) -> None:
        with (ROOT / "manifest.json").open() as handle:
            catalog = json.load(handle)

        self.assertEqual(
            {
                "path": "05_world_layer",
                "description": "Neutral, versioned narrative worlds for cyber exercises",
                "manifest": "manifest.json",
            },
            catalog["layers"].get("world"),
        )

    def test_misp_stack_pins_a_release_with_nacre(self) -> None:
        expected = "v2.5.44"
        env_example = (MISP_STACK / ".env.example").read_text()
        dockerfile = (MISP_STACK / "Dockerfile").read_text()
        compose = (MISP_STACK / "docker-compose.yml").read_text()

        self.assertIn(f"MISP_VERSION={expected}", env_example)
        self.assertIn(f"ARG MISP_VERSION={expected}", dockerfile)
        self.assertNotIn("v2.5.37", compose)
        self.assertEqual(3, compose.count(expected))

    def test_misp_build_ties_bundled_world_to_vendored_hashes(self) -> None:
        dockerfile = (MISP_STACK / "Dockerfile").read_text()
        version = (NACRE / "VERSION").read_text()

        expected = {
            "55afe65a817c167a46dbd26850515aefb2bf72b9318f651d6adb172e498a44b4":
                "clusters/exercise-world.json",
            "f1fe9a26eae4148542e0d89126cdf4231c803b2c3fd255137b42e2c5f969807a":
                "galaxies/exercise-world.json",
        }
        for digest, relative_path in expected.items():
            self.assertIn(digest, dockerfile)
            self.assertIn(relative_path, dockerfile)
        self.assertIn("sha256sum -c", dockerfile)
        self.assertIn("misp_version=v2.5.44", version)
        self.assertIn(
            "misp_galaxy_commit=041c6d0f3da384626c07b9220c1f6cef640ddf1a",
            version,
        )

    def test_misp_startup_refreshes_bundled_galaxies_in_persisted_volume(self) -> None:
        dockerfile = (MISP_STACK / "Dockerfile").read_text()
        entrypoint = (MISP_STACK / "provisioning" / "entrypoint.sh").read_text()
        refresher = MISP_STACK / "provisioning" / "refresh-galaxy-files.sh"

        self.assertTrue(refresher.is_file(), "missing persisted-volume galaxy refresher")
        self.assertIn("/opt/misp-galaxy", dockerfile)
        self.assertIn("/provisioning/refresh-galaxy-files.sh", entrypoint)
        self.assertLess(
            entrypoint.index("/provisioning/refresh-galaxy-files.sh"),
            entrypoint.index("First-boot bootstrap"),
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            seed = root / "seed"
            target = root / "target"
            (seed / "clusters").mkdir(parents=True)
            (seed / "galaxies").mkdir(parents=True)
            (target / "clusters").mkdir(parents=True)
            (seed / "clusters" / "exercise-world.json").write_text("new bundled data\n")
            (target / "clusters" / "exercise-world.json").write_text("old persisted data\n")

            env = os.environ.copy()
            env.update(
                {
                    "MISP_GALAXY_SEED_DIR": str(seed),
                    "MISP_GALAXY_TARGET_DIR": str(target),
                    "MISP_GALAXY_OWNER": "",
                }
            )
            result = subprocess.run(
                ["bash", str(refresher)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(
                "new bundled data\n",
                (target / "clusters" / "exercise-world.json").read_text(),
            )

    def test_sample_events_use_canonical_nacre_galaxy_tags(self) -> None:
        expected_by_file = {
            "event-01-spearphishing.json": {
                'misp-galaxy:exercise-world="Asterin Union"',
                'misp-galaxy:exercise-world="NovaCore Systems"',
                'misp-galaxy:exercise-world="TA-700 Obsidian Jackal"',
            },
            "event-02-ransomware-c2.json": {
                'misp-galaxy:exercise-world="Velkar Republic"',
                'misp-galaxy:exercise-world="HelixCore Group"',
                'misp-galaxy:exercise-world="TA-701 Silver Mantis"',
            },
        }

        events = MISP_STACK / "provisioning" / "sample-events"
        for filename, expected in expected_by_file.items():
            with (events / filename).open() as handle:
                event = json.load(handle)["Event"]
            actual = {tag["name"] for tag in event["Tag"]}
            self.assertTrue(expected <= actual, f"{filename} missing {sorted(expected - actual)}")

    def test_existing_sample_event_is_updated_from_fixture(self) -> None:
        provisioner = MISP_STACK / "provisioning" / "provision-sample-events.sh"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            events_dir = root / "events"
            bin_dir.mkdir()
            events_dir.mkdir()
            key_file = root / "admin-authkey"
            key_file.write_text("test-key\n")
            event_uuid = "c0ffee01-cafe-4bab-b000-000000000001"
            (events_dir / "fixture.json").write_text(
                json.dumps({"Event": {"uuid": event_uuid, "info": "managed fixture"}})
            )
            curl_log = root / "curl.log"
            fake_curl = bin_dir / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"${CURL_LOG}\"\n"
                "url=\"${!#}\"\n"
                "case \"${url}\" in\n"
                "  */events/view/*) printf '%s\\n' '{\"Event\":{\"uuid\":\""
                + event_uuid
                + "\"}}' ;;\n"
                "  */events/edit/*) printf '%s\\n' '{\"Event\":{\"uuid\":\""
                + event_uuid
                + "\"}}' ;;\n"
                "  *) printf '%s\\n' '{}' ;;\n"
                "esac\n"
            )
            fake_curl.chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "CURL_LOG": str(curl_log),
                    "MISP_ADMIN_KEY_FILE": str(key_file),
                    "MISP_SAMPLE_EVENTS_DIR": str(events_dir),
                }
            )
            result = subprocess.run(
                ["bash", str(provisioner)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            requests = curl_log.read_text()
            self.assertIn(f"/events/edit/{event_uuid}", requests)
            self.assertNotIn("/events/add", requests)
            self.assertIn("Updated", result.stderr)

    def test_provisioner_verifies_nacre_before_importing_events(self) -> None:
        provisioning = MISP_STACK / "provisioning"
        verifier = provisioning / "verify-exercise-world.py"
        self.assertTrue(verifier.is_file(), "missing exercise-world runtime verifier")

        spec = importlib.util.spec_from_file_location("verify_exercise_world", verifier)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        galaxy_id = module.find_exercise_world_galaxy(
            {
                "response": [
                    {
                        "Galaxy": {
                            "id": "42",
                            "type": "exercise-world",
                            "uuid": "3c3de5f0-5982-4c7f-88cf-8abf43b8d6c1",
                        }
                    }
                ]
            }
        )
        self.assertEqual("42", galaxy_id)

        clusters = [
            {
                "uuid": f"00000000-0000-4000-8000-{index:012d}",
                "collection_uuid": "7d6d7f2f-b3d4-4bc5-9f27-43e12f7f4658",
            }
            for index in range(60)
        ]
        try:
            module.verify_cluster_payload({"Galaxy": {"id": "42"}, "GalaxyCluster": clusters})
        except Exception as exc:  # noqa: BLE001 - convert unexpected parser errors into an assertion
            self.fail(f"valid MISP galaxy payload was rejected: {exc}")

        provision_sh = (provisioning / "provision.sh").read_text()
        self.assertLess(
            provision_sh.index("provision-content.sh"),
            provision_sh.index("verify-exercise-world.py"),
        )
        self.assertLess(
            provision_sh.index("verify-exercise-world.py"),
            provision_sh.index("provision-sample-events.sh"),
        )
        compose = (MISP_STACK / "docker-compose.yml").read_text()
        self.assertIn("./provisioning/verify-exercise-world.py:/provisioning/verify-exercise-world.py:ro", compose)


if __name__ == "__main__":
    unittest.main()
