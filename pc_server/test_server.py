"""Run: python -m unittest discover -s pc_server -p test_*.py"""

from io import BytesIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastapi import HTTPException, UploadFile
from starlette.datastructures import Headers

import server


JPEG = b"\xff\xd8\xff\xe0photo-bytes\xff\xd9"
PNG = b"\x89PNG\r\n\x1a\nphoto-bytes"
GUID = "b531857e-1905-4680-be15-ff5c1fba02f9"
STAMP = "20261106_153000"


def photo(name: str, content: bytes = JPEG, mime: str = "application/octet-stream") -> UploadFile:
    return UploadFile(file=BytesIO(content), filename=name,
                      headers=Headers({"content-type": mime}))


class FilenameTests(unittest.TestCase):
    def test_original_names_are_preserved(self):
        for name in ["IMG_20261106_123456.jpg", "여행 사진.PNG", "IMG_001.HEIC"]:
            with self.subTest(name=name):
                self.assertEqual(server.upload_filename(photo(name), STAMP, 1), name)

    def test_guids_and_empty_names_use_timestamp_and_sequence(self):
        for name in [GUID, f"{GUID}.jpg", GUID.replace("-", ""), ""]:
            with self.subTest(name=name):
                self.assertEqual(server.upload_filename(photo(name), STAMP, 2),
                                 f"{STAMP}_002.jpg")

    def test_extensionless_original_keeps_name_and_gains_real_extension(self):
        self.assertEqual(server.upload_filename(photo("DSC1234", PNG), STAMP, 1), "DSC1234.png")

    def test_headers_identify_images_even_with_generic_mime(self):
        cases = [
            (JPEG, ".jpg"), (PNG, ".png"), (b"GIF89a" + b"x" * 8, ".gif"),
            (b"RIFF\x00\x00\x00\x00WEBP", ".webp"),
            (b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic", ".heic"),
            (b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00avifmif1", ".avif"),
            (b"II*\x00" + b"x" * 8, ".tif"), (b"BM" + b"x" * 8, ".bmp"),
        ]
        for content, extension in cases:
            with self.subTest(extension=extension):
                self.assertEqual(server.upload_filename(photo(GUID, content), STAMP, 1),
                                 f"{STAMP}_001{extension}")

    def test_raw_extension_is_not_replaced_by_tiff(self):
        self.assertEqual(server.upload_filename(photo("IMG_1.dng", b"II*\x00"), STAMP, 1),
                         "IMG_1.dng")

    def test_mime_fallback_and_unknown_format(self):
        self.assertEqual(server.upload_filename(photo(GUID, b"opaque", "image/heic"), STAMP, 1),
                         f"{STAMP}_001.heic")
        with self.assertRaises(HTTPException) as error:
            server.upload_filename(photo(GUID, b"unknown"), STAMP, 1)
        self.assertEqual(error.exception.status_code, 415)

    def test_path_and_reserved_names_are_safe(self):
        for name in ["../../photo.jpg", r"C:\photos\photo.jpg", "CON.jpg", "a:b.jpg"]:
            with self.subTest(name=name):
                result = server.upload_filename(photo(name), STAMP, 1)
                self.assertNotRegex(result, r'[<>:"/\\|?*]')
                self.assertNotEqual(Path(result).stem.upper(), "CON")

    def test_batch_preserves_contents_and_avoids_overwrites(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, "UPLOAD_ROOT", Path(temporary)):
            images = [photo(GUID), photo(GUID, PNG), photo("original.jpg"), photo("original.jpg", JPEG + b"2")]
            result = server.save_batch(images, "여행")
            folder = Path(temporary) / result["directory"]
            self.assertRegex(result["files"][0], r"^\d{8}_\d{6}_001\.jpg$")
            self.assertRegex(result["files"][1], r"^\d{8}_\d{6}_002\.png$")
            self.assertEqual(result["files"][2:], ["original.jpg", "original_1.jpg"])
            for image, name in zip(images, result["files"]):
                self.assertEqual((folder / name).read_bytes(), image.file.getvalue())

    def test_unknown_format_does_not_publish_a_partial_batch(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, "UPLOAD_ROOT", Path(temporary)):
            with self.assertRaises(HTTPException):
                server.save_batch([photo("valid.jpg"), photo(GUID, b"unknown")], "")
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_success_log_contains_time_tag_count_and_full_destination(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, "UPLOAD_ROOT", Path(temporary)):
            with self.assertLogs("uvicorn.error", level="INFO") as logs:
                result = server.save_batch([photo("one.jpg"), photo("two.jpg")], "여행")
            message = logs.output[0]
            self.assertRegex(message, r"시간: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")
            self.assertIn("태그: 여행 | 파일: 2개", message)
            self.assertIn(str((Path(temporary) / result["directory"]).resolve()), message)

    def test_empty_tag_is_logged_and_failed_batch_has_no_success_log(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, "UPLOAD_ROOT", Path(temporary)):
            with self.assertLogs("uvicorn.error", level="INFO") as logs:
                server.save_batch([photo("one.jpg")], "")
            self.assertIn("태그: (없음)", logs.output[0])
            with self.assertNoLogs("uvicorn.error", level="INFO"):
                with self.assertRaises(HTTPException):
                    server.save_batch([photo(GUID, b"unknown")], "실패")


if __name__ == "__main__":
    unittest.main()
