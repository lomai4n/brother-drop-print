"""Offline boundary tests. Never connects to a printer."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENCODER = Path(sys.argv.pop(1)).resolve()
WIDTH, HEIGHT, ROW_BYTES = 4825, 6817, 604
HEADER = f"P4\n{WIDTH} {HEIGHT}\n".encode()
A4_STANDARD = ["A4", "600", "0", "0", "PLAIN"]


def blank_page(width, height):
    return f"P4\n{width} {height}\n".encode() + bytes((width + 7) // 8 * height)


class EncoderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.page = self.root / "page.pbm"
        self.page.write_bytes(HEADER + bytes(ROW_BYTES * HEIGHT))
        self.output = self.root / "output.prn"

    def tearDown(self):
        self.directory.cleanup()

    def encode(self, copies="1", setup=None):
        return subprocess.run(
            [str(ENCODER), str(self.output), copies, *(setup or A4_STANDARD), str(self.page)],
            capture_output=True, timeout=20,
        )

    def test_a4_header_matches_v1_output(self):
        self.assertEqual(self.encode().returncode, 0)
        data = self.output.read_bytes()
        for line in (b"@PJL SET RESOLUTION = 600", b"@PJL SET ECONOMODE = OFF",
                     b"@PJL SET MEDIATYPE = PLAIN", b"@PJL SET DENSITY=0", b"@PJL SET PAPER = A4"):
            self.assertIn(line, data)

    def test_a5_draft_toner_save_header(self):
        # A5 at 300 dpi: (420 - 16) and (595 - 24) points.
        self.page.write_bytes(blank_page(1683, 2379))
        result = self.encode(setup=["A5", "300", "1", "-2", "THIN"])
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.output.read_bytes()
        for line in (b"@PJL SET RESOLUTION = 300", b"@PJL SET ECONOMODE = ON",
                     b"@PJL SET MEDIATYPE = THIN", b"@PJL SET DENSITY=-2", b"@PJL SET PAPER = A5"):
            self.assertIn(line, data)

    def test_raster_must_match_selected_paper(self):
        result = self.encode(setup=["LETTER", "600", "0", "0", "PLAIN"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_invalid_setup_is_rejected(self):
        for setup in (["A3", "600", "0", "0", "PLAIN"], ["A4", "1200", "0", "0", "PLAIN"],
                      ["A4", "600", "2", "0", "PLAIN"], ["A4", "600", "0", "7", "PLAIN"],
                      ["A4", "600", "0", "0", "GLOSSY"]):
            self.assertNotEqual(self.encode(setup=setup).returncode, 0, setup)
            self.assertFalse(self.output.exists())

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
