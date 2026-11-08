from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from io import BytesIO

import cv2
import numpy as np
from fastapi import UploadFile

from monitor_crop import crop_monitor_file
import server


def monitor_photo() -> bytes:
    image = np.full((800, 1200, 3), 25, dtype=np.uint8)
    corners = np.int32([[170, 180], [1060, 120], [1020, 670], [140, 650]])
    cv2.fillConvexPoly(image, corners, (245, 245, 245))
    cv2.putText(image, 'MONITOR TEST', (280, 360), cv2.FONT_HERSHEY_SIMPLEX, 2, (20, 20, 20), 3)
    return cv2.imencode('.jpg', image)[1].tobytes()


class MonitorCropTests(unittest.TestCase):
    def test_detects_large_monitor_and_rectifies_a_separate_copy(self):
        original = monitor_photo()
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / '모니터.jpg'
            target = Path(temporary) / '보정.jpg'
            source.write_bytes(original)
            self.assertTrue(crop_monitor_file(source, target))
            cropped = cv2.imdecode(np.fromfile(target, dtype=np.uint8), cv2.IMREAD_COLOR)
            self.assertLess(cropped.shape[0], 800)
            self.assertLess(cropped.shape[1], 1200)
            self.assertGreater(cropped.shape[1], 700)
            self.assertEqual(source.read_bytes(), original)

    def test_no_monitor_keeps_original_without_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'blank.png'
            target = Path(temporary) / 'crop.png'
            source.write_bytes(cv2.imencode('.png', np.full((600, 900, 3), 80, np.uint8))[1].tobytes())
            self.assertFalse(crop_monitor_file(source, target))
            self.assertFalse(target.exists())

    def test_crop_is_opt_in_and_unmodified_original_is_archived(self):
        content = monitor_photo()
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, 'UPLOAD_ROOT', Path(temporary)):
            upload = UploadFile(filename='screen.jpg', file=BytesIO(content))
            result = server.save_batch([upload], 'monitor', crop_monitor=True)
            folder = Path(temporary) / result['directory']
            self.assertEqual(result['cropped'], ['screen.jpg'])
            self.assertEqual((folder / '_originals' / 'screen.jpg').read_bytes(), content)
            self.assertNotEqual((folder / 'screen.jpg').read_bytes(), content)
            result = server.save_batch([UploadFile(filename='screen.jpg', file=BytesIO(content))], '')
            folder = Path(temporary) / result['directory']
            self.assertEqual(result['cropped'], [])
            self.assertEqual((folder / 'screen.jpg').read_bytes(), content)
            self.assertFalse((folder / '_originals').exists())

    def test_crop_failure_still_saves_original_and_reports_warning(self):
        content = monitor_photo()
        with tempfile.TemporaryDirectory() as temporary, patch.object(server, 'UPLOAD_ROOT', Path(temporary)), \
                patch.object(server, 'crop_monitor_file', side_effect=RuntimeError('detector failure')):
            result = server.save_batch([UploadFile(filename='screen.jpg', file=BytesIO(content))], '', True)
            self.assertTrue(result['crop_warning'])
            self.assertEqual((Path(temporary) / result['directory'] / 'screen.jpg').read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
