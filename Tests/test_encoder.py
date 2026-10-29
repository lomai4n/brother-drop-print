"""Offline boundary tests. Never connects to a printer."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENCODER = Path(sys.argv.pop(1)).resolve()
WIDTH, HEIGHT, ROW_BYTES = 4825, 6817, 604
HEADER = f"P4\n{WIDTH} {HEIGHT}\n".encode()


class EncoderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.page = self.root / "page.pbm"
        self.page.write_bytes(HEADER + bytes(ROW_BYTES * HEIGHT))
        self.output = self.root / "output.prn"

    def tearDown(self):
        self.directory.cleanup()

    def encode(self, copies="1"):
        return subprocess.run(
            [str(ENCODER), str(self.output), copies, str(self.page)],
            capture_output=True, timeout=20,
        )

    def test_blank_page_is_a_complete_bounded_job(self):
        result = self.encode()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.output.read_bytes()
        self.assertTrue(data.startswith(bytes(128) + b"\x1b%-12345X@PJL"))
        self.assertIn(b"\x1b*b1030m", data)
        self.assertTrue(data.endswith(b"\x1b%-12345X\n"))
        self.assertEqual(data.count(b"1030M\x0c"), 1)

    def test_truncated_page_is_rejected_before_output(self):
        self.page.write_bytes(HEADER + bytes(100))
        self.assertNotEqual(self.encode().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_wrong_geometry_is_rejected(self):
        self.page.write_bytes(b"P4\n100 100\n" + bytes(1250))
        self.assertNotEqual(self.encode().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b"keep this")
        self.assertNotEqual(self.encode().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"keep this")

    def test_invalid_copies_is_rejected(self):
        for value in ("0", "100", "1x"):
            self.assertNotEqual(self.encode(value).returncode, 0)

    def test_copies_produce_expected_pages(self):
        self.assertEqual(self.encode("2").returncode, 0)
        self.assertEqual(self.output.read_bytes().count(b"1030M\x0c"), 2)

    def test_invalid_padding_is_rejected(self):
        data = bytearray(HEADER + bytes(ROW_BYTES * HEIGHT))
        data[len(HEADER) + ROW_BYTES - 1] = 1
        self.page.write_bytes(data)
        self.assertNotEqual(self.encode().returncode, 0)


if __name__ == "__main__":
    unittest.main()
