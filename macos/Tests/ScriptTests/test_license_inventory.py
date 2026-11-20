"""Offline regression tests for metadata inventory; no license conclusion is implied."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


MACOS = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = MACOS / "scripts"


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def json_command(*command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class LicenseInventoryTests(unittest.TestCase):
    def test_third_party_license_and_notice_are_found_in_both_inventories_and_draft(self):
        with tempfile.TemporaryDirectory(prefix="commondev-license-test-") as temp:
            root = pathlib.Path(temp)
            package = root / "node_modules" / "sample"
            write(package / "package.json", json.dumps({"name": "sample", "version": "1.0.0", "license": "MIT"}))
            write(package / "index.js", "export default 1;\n")
            write(package / "LICENSE", "Fixture primary license")
            write(package / "THIRD-PARTY-LICENSE", "Fixture bundled license")
            write(package / "THIRD-PARTY-NOTICES.md", "Fixture bundled notices")
            server = root / "server.mjs"
            metadata = root / "metafile.json"
            write(server, "// fixture bundle\n")
            write(metadata, json.dumps({"inputs": {"node_modules/sample/index.js": {"bytes": 18}}, "outputs": {}}))
            packaged = json_command(sys.executable, str(SCRIPTS / "inventory-licenses.py"), str(root))
            bundle = json_command("node", str(SCRIPTS / "inventory-bundle.mjs"), str(metadata), str(root), str(server))
            expected = ["LICENSE", "THIRD-PARTY-LICENSE", "THIRD-PARTY-NOTICES.md"]
            self.assertEqual(packaged["packages"][0]["license_notice_files"], expected)
            self.assertEqual(bundle["packages"][0]["license_notice_files"], expected)
            draft = subprocess.run([sys.executable, str(SCRIPTS / "draft-notices.py"), str(root)],
                                   check=True, capture_output=True, text=True).stdout
            self.assertIn("Fixture bundled license", draft)
            self.assertIn("Fixture bundled notices", draft)

    def test_bundle_metadata_identifies_workspace_external_and_missing_inputs(self):
        with tempfile.TemporaryDirectory(prefix="commondev-license-test-") as temp:
            root = pathlib.Path(temp) / "source"
            workspace = root / "desktop"
            dependency = root / "node_modules" / "@scope" / "library"
            write(workspace / "package.json", json.dumps({"name": "workspace", "version": "1.0.0", "license": "MIT"}))
            write(workspace / "entry.js", "export const x = 1;\n")
            write(dependency / "package.json", json.dumps({"name": "@scope/library", "version": "2.0.0", "license": "ISC"}))
            write(dependency / "LICENSE", "Example test license")
            write(dependency / "index.js", "export default 1;\n")
            metadata = {
                "inputs": {
                    "desktop/entry.js": {"bytes": 20},
                    "node_modules/@scope/library/index.js": {"bytes": 18},
                    "missing.js": {"bytes": 1},
                },
                "outputs": {"../server.mjs": {"imports": [{"path": "sharp", "external": True}]}},
            }
            metadata_path = pathlib.Path(temp) / "meta.json"
            server_path = pathlib.Path(temp) / "server.mjs"
            write(metadata_path, json.dumps(metadata))
            write(server_path, "// fixture bundle\n")

            inventory = json_command("node", str(SCRIPTS / "inventory-bundle.mjs"), str(metadata_path), str(root), str(server_path))
            self.assertEqual(inventory["server_sha256"], hashlib.sha256(server_path.read_bytes()).hexdigest())
            self.assertEqual(inventory["input_count"], 2)
            self.assertEqual({item["name"] for item in inventory["packages"]}, {"workspace", "@scope/library"})
            self.assertEqual([item["name"] for item in inventory["packages_without_license_notice"]], ["workspace"])
            self.assertEqual(inventory["external_imports"], ["sharp"])
            self.assertEqual(inventory["unresolved_inputs"][0]["input"], "missing.js")
            self.assertNotIn(str(root), json.dumps(inventory))

    def test_packaged_inventory_reports_old_mismatched_and_invalid_metadata(self):
        with tempfile.TemporaryDirectory(prefix="commondev-license-test-") as temp:
            root = pathlib.Path(temp)
            package = root / "node_modules" / "sample"
            write(package / "package.json", json.dumps({"name": "sample", "version": "1.0.0", "license": "MIT"}))
            write(package / "LICENSE", "Example test license")
            server = root / "server.mjs"
            write(server, "// original\n")

            def inspect():
                return json_command(sys.executable, str(SCRIPTS / "inventory-licenses.py"), str(root))

            self.assertEqual(inspect()["bundle_inventory"]["status"], "unavailable")
            bundle = {
                "server_sha256": hashlib.sha256(server.read_bytes()).hexdigest(),
                "input_count": 1,
                "packages": [],
                "packages_without_license_notice": [],
                "external_imports": [],
                "unresolved_inputs": [],
            }
            bundle_path = root / "server-input-inventory.json"
            write(bundle_path, json.dumps(bundle))
            self.assertTrue(inspect()["bundle_inventory"]["server_sha256_matches"])
            write(server, "// changed\n")
            self.assertFalse(inspect()["bundle_inventory"]["server_sha256_matches"])
            write(bundle_path, "[]")
            self.assertEqual(inspect()["bundle_inventory"]["status"], "invalid")

    def test_bundle_does_not_disclose_symlinked_inputs_outside_source(self):
        with tempfile.TemporaryDirectory(prefix="commondev-license-test-") as temp:
            root = pathlib.Path(temp) / "source"
            root.mkdir()
            outside = pathlib.Path(temp) / "outside.js"
            write(outside, "export default 1;\n")
            (root / "link.js").symlink_to(outside)
            metadata = pathlib.Path(temp) / "meta.json"
            bundle = pathlib.Path(temp) / "server.mjs"
            write(metadata, json.dumps({"inputs": {"link.js": {"bytes": 1}}, "outputs": {}}))
            write(bundle, "// bundle\n")
            inventory = json_command("node", str(SCRIPTS / "inventory-bundle.mjs"), str(metadata), str(root), str(bundle))
            self.assertEqual(inventory["input_count"], 0)
            self.assertEqual(inventory["unresolved_inputs"][0]["input"], "[outside source root]")
            self.assertNotIn(str(outside), json.dumps(inventory))


if __name__ == "__main__":
    unittest.main()
