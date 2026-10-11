import pathlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = pathlib.Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "Casks").mkdir()
        for name in ("update-cask.sh", "compare-versions.py"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        self.cask = self.root / "Casks" / "acu.rb"
        self.cask.write_text('cask "acu" do\n  version "0.1.3"\n'
                             '  sha256 "' + "a" * 64 + '"\nend\n')

    def update(self, version, sha="b" * 64):
        return subprocess.run(
            ["sh", str(self.root / "scripts" / "update-cask.sh"), version, sha],
            capture_output=True, text=True,
        )

    def test_older_release_cannot_downgrade_cask(self):
        original = self.cask.read_bytes()
        result = self.update("v0.1.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cask.read_bytes(), original)

    def test_same_version_refreshes_checksum(self):
        result = self.update("v0.1.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "0.1.3"', self.cask.read_text())
        self.assertIn("b" * 64, self.cask.read_text())

    def test_newer_version_updates_cask(self):
        result = self.update("v0.1.10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "0.1.10"', self.cask.read_text())

    def test_invalid_input_does_not_modify_cask(self):
        original = self.cask.read_bytes()
        for version, sha in (("invalid", "b" * 64), ("v0.1.4", "bad")):
            result = self.update(version, sha)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.cask.read_bytes(), original)

    def test_numeric_and_prerelease_version_order(self):
        for left, right, expected in (
            ("0.1.10", "0.1.9", "1"),
            ("0.1.3", "v0.1.3", "0"),
            ("0.1.3-rc.1", "0.1.3", "-1"),
            ("0.1.3-rc.10", "0.1.3-rc.2", "1"),
            ("0.1.3-alpha", "0.1.3-beta", "-1"),
        ):
            with self.subTest(left=left, right=right):
                result = subprocess.run(
                    ["python3", str(SCRIPTS / "compare-versions.py"), left, right],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()
