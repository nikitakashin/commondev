import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "draft-notices.py"


class DraftNoticesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name) / "gateway"
        self.root.mkdir()
        (self.root / "LICENSE-FreeLLMAPI").write_text("FreeLLMAPI test license")
        (self.root / "LICENSE-Node").write_text("Node test license")
        self.modules = self.root / "node_modules"
        self.modules.mkdir()

    def package(self, name, version, license_text=None):
        directory = self.modules / name
        directory.mkdir(parents=True)
        (directory / "package.json").write_text(json.dumps({
            "name": name, "version": version, "license": "MIT",
        }))
        if license_text is not None:
            (directory / "LICENSE").write_text(license_text)
        return directory

    def generate(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.root)], check=True,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout

    def test_local_notices_and_missing_bundle_are_explicit(self):
        self.package("example", "1.2.3", "Example license text")
        self.package("missing", "2.0.0")
        text = self.generate()
        self.assertIn("DRAFT; REVIEW REQUIRED", text)
        self.assertIn("not a compliance determination", text)
        self.assertIn("FreeLLMAPI test license", text)
        self.assertIn("Node test license", text)
        self.assertIn("Example license text", text)
        self.assertIn("missing@2.0.0", text)
        self.assertIn("MISSING LOCAL LICENSE/NOTICE", text)
        self.assertIn("Status: unavailable", text)

    def test_bundle_provenance_and_hash_mismatch_are_reported(self):
        self.package("example", "1.2.3", "Example license text")
        (self.root / "server.mjs").write_text("test bundle")
        bundle = {
            "server_sha256": hashlib.sha256(b"another bundle").hexdigest(),
            "input_count": 2,
            "packages": [
                {"name": "example", "version": "1.2.3", "declared_license": "MIT",
                 "path": "node_modules/example", "license_notice_files": ["LICENSE"]},
                {"name": "bundled-only", "version": "3", "declared_license": "MIT",
                 "path": "packages/bundled-only", "license_notice_files": []},
            ],
            "packages_without_license_notice": [],
            "external_imports": ["sharp"],
            "unresolved_inputs": [{"input": "unknown.js", "reason": "unresolved"}],
        }
        (self.root / "server-input-inventory.json").write_text(json.dumps(bundle))
        text = self.generate()
        self.assertIn("Status: available", text)
        self.assertIn("Bundle SHA-256 matches inventory: NO", text)
        self.assertIn("example@1.2.3 | declared=MIT", text)
        self.assertIn("bundled-only@3 | declared=MIT", text)
        self.assertIn("matching node_modules package=NO", text)
        self.assertIn("External imports: sharp", text)
        self.assertIn("Unresolved input: unknown.js", text)

    def test_notice_symlink_cannot_read_outside_artifact(self):
        outside = pathlib.Path(self.temp.name) / "secret.txt"
        outside.write_text("THIS MUST NOT APPEAR")
        package = self.package("example", "1.0.0")
        (package / "LICENSE").symlink_to(outside)
        text = self.generate()
        self.assertIn("MISSING OR OUTSIDE SIDECAR", text)
        self.assertNotIn("THIS MUST NOT APPEAR", text)


if __name__ == "__main__":
    unittest.main()
