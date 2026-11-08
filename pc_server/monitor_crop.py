"""Find a prominent screen quadrilateral and perspective-correct a copy.

This is geometric detection, not a trained monitor classifier. The caller must
keep the original: windows inside a screen can also have rectangular borders.
"""

from pathlib import Path


def crop_monitor_file(source: Path, destination: Path) -> bool:
    import cv2
    import numpy as np

    if source.suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}:
        return False
    image = cv2.imdecode(np.fromfile(source, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        return False
    height, width = image.shape[:2]
    scale = min(1.0, 1600 / max(width, height))
    sample = cv2.resize(image, None, fx=scale, fy=scale) if scale < 1 else image
    gray = cv2.cvtColor(sample, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(gray, 40, 140)
    edges = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, np.ones((3, 3), dtype=np.uint8))
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    sample_area = sample.shape[0] * sample.shape[1]
    corners = None
    for contour in sorted(contours, key=cv2.contourArea, reverse=True):
        area = cv2.contourArea(contour)
        if not 0.28 * sample_area <= area <= 0.96 * sample_area:
            continue
        polygon = cv2.approxPolyDP(contour, 0.02 * cv2.arcLength(contour, True), True)
        if len(polygon) != 4 or not cv2.isContourConvex(polygon):
            continue
        points = polygon.reshape(4, 2).astype(np.float32)
        center = points.mean(axis=0)
        points = points[np.argsort(np.arctan2(points[:, 1] - center[1], points[:, 0] - center[0]))]
        points = np.roll(points, -np.argmin(points.sum(axis=1)), axis=0)
        if any(abs(np.dot(points[(i - 1) % 4] - points[i], points[(i + 1) % 4] - points[i])) /
               max(np.linalg.norm(points[(i - 1) % 4] - points[i]) *
                   np.linalg.norm(points[(i + 1) % 4] - points[i]), 1) > 0.65 for i in range(4)):
            continue
        if cv2.pointPolygonTest(polygon, (sample.shape[1] / 2, sample.shape[0] / 2), False) < 0:
            continue
        corners = points / scale
        break
    if corners is None:
        return False
    top_left, top_right, bottom_right, bottom_left = corners
    out_width = round(max(np.linalg.norm(top_right - top_left), np.linalg.norm(bottom_right - bottom_left)))
    out_height = round(max(np.linalg.norm(bottom_left - top_left), np.linalg.norm(bottom_right - top_right)))
    if min(out_width, out_height) < 200 or not 0.3 <= out_width / out_height <= 4:
        return False
    target = np.float32([[0, 0], [out_width - 1, 0], [out_width - 1, out_height - 1], [0, out_height - 1]])
    transform = cv2.getPerspectiveTransform(corners.astype(np.float32), target)
    cropped = cv2.warpPerspective(image, transform, (out_width, out_height), flags=cv2.INTER_CUBIC)
    extension = source.suffix.lower()
    parameters = [cv2.IMWRITE_JPEG_QUALITY, 98] if extension in {".jpg", ".jpeg"} else []
    ok, encoded = cv2.imencode(extension, cropped, parameters)
    if not ok:
        return False
    # Bytes/Path support Korean Windows paths, unlike some imwrite builds.
    with destination.open("xb") as output:
        output.write(encoded.tobytes())
        output.flush()
        import os
        os.fsync(output.fileno())
    return True
