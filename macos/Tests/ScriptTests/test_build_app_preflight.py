import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildAppPreflightTests(unittest.TestCase):
    def test_missing_native_dependencies_are_rejected_before_app_creation(self):
        script = Path(__file__).resolve().parents[2] / "scripts" / "build-app.sh"
        with tempfile.TemporaryDirectory(prefix="commondev-preflight-test-") as temporary:
            root = Path(temporary)
            gateway = root / "gateway"
            gateway.mkdir()
            (gateway / "node").write_text("#!/bin/sh\nexit 1\n")
            (gateway / "node").chmod(0o755)
            (gateway / "server.mjs").touch()
            (gateway / "gateway-entry.mjs").touch()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (fake_bin / "lipo").write_text("#!/bin/sh\nexit 0\n")
            (fake_bin / "lipo").chmod(0o755)
            output = root / "Incomplete.app"
            environment = dict(os.environ)
            environment["PATH"] = str(fake_bin) + os.pathsep + environment.get("PATH", "")
            environment["COMMONDEV_GATEWAY_DIR"] = str(gateway)
            result = subprocess.run(["bash", str(script), str(output)], env=environment,
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Gateway dependencies failed to load", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
