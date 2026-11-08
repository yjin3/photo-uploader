"""Run: python pc_server/server.py. Files are stored beside this script."""

from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from starlette.concurrency import run_in_threadpool
import uvicorn

from monitor_crop import crop_monitor_file


app = FastAPI(title="Photo Uploader")
UPLOAD_ROOT = Path(r"d:\\YProject\\AI_CCVS_JODAL\\2_Data\\samsung_upload_image\\")
GUID_NAME = re.compile(
    r"(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.IGNORECASE,
)
IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".jpe", ".png", ".gif", ".webp", ".bmp",
    ".tif", ".tiff", ".heic", ".heif", ".avif", ".dng", ".raw",
    ".arw", ".cr2", ".cr3", ".nef", ".orf", ".rw2", ".pef", ".raf",
}
MIME_EXTENSIONS = {
    "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif",
    "image/webp": ".webp", "image/bmp": ".bmp", "image/tiff": ".tif",
    "image/heic": ".heic", "image/heif": ".heif", "image/avif": ".avif",
}


def safe_name(value: str, fallback: str, limit: int = 100) -> str:
    # Both Windows and POSIX separators/control characters are forbidden.
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f\x7f]', "_", value)
    cleaned = cleaned.strip(" .")[:limit].rstrip(" .")
    if not cleaned or cleaned in {".", ".."}:
        return fallback
    if cleaned.split(".")[0].upper() in {
        "CON", "PRN", "AUX", "NUL",
        *(f"COM{i}" for i in range(1, 10)),
        *(f"LPT{i}" for i in range(1, 10)),
    }:
        cleaned = "_" + cleaned
    return cleaned


def image_extension(header: bytes) -> str:
    """Recognize common photo formats without decoding/re-encoding the image."""
    if header.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if header.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return ".webp"
    if header.startswith((b"II*\x00", b"MM\x00*")):
        return ".tif"
    if header.startswith(b"BM"):
        return ".bmp"
    if header[4:8] == b"ftyp":
        box_size = int.from_bytes(header[:4], "big")
        brands = {header[8:12]} | {
            header[offset:offset + 4]
            for offset in range(16, min(box_size, len(header)), 4)
        }
        if brands & {b"avif", b"avis"}:
            return ".avif"
        if brands & {b"heic", b"heix", b"hevc", b"hevx"}:
            return ".heic"
        if brands & {b"mif1", b"msf1"}:
            return ".heif"
    return ""


def upload_filename(upload: UploadFile, stamp: str, index: int) -> str:
    original = (upload.filename or "").replace("\\", "/").rsplit("/", 1)[-1]
    suffix = Path(original).suffix
    # Inspect a small header and rewind so every uploaded byte is still saved.
    upload.file.seek(0)
    detected = image_extension(upload.file.read(512))
    upload.file.seek(0)
    if suffix.lower() in IMAGE_EXTENSIONS:
        # Preserve genuine names and RAW extensions (DNG also has a TIFF header).
        extension = suffix
    else:
        extension = detected or MIME_EXTENSIONS.get(
            (upload.content_type or "").split(";", 1)[0].strip().lower(), ""
        )
    if not extension:
        raise HTTPException(status_code=415, detail=(
            f"Cannot identify image format: {original or '(no filename)'}. "
            "Original photos have not been deleted."
        ))
    stem = safe_name(Path(original).stem if suffix else original, "")
    if not stem or GUID_NAME.fullmatch(stem):
        stem = f"{stamp}_{index:03d}"
    return stem + extension


def save_batch(files: list[UploadFile], tag: str, crop_monitor: bool = False) -> dict:
    UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    suffix = safe_name(tag.strip(), "", 60)
    base = stamp + (f"_{suffix}" if suffix else "")
    staging = Path(tempfile.mkdtemp(prefix=".upload-", dir=UPLOAD_ROOT))
    names = []
    cropped_names = []
    crop_warning = None
    try:
        for index, upload in enumerate(files, start=1):
            name = upload_filename(upload, stamp, index)
            path = staging / name
            counter = 1
            while path.exists():
                path = staging / f"{Path(name).stem}_{counter}{Path(name).suffix}"
                counter += 1
            with path.open("xb") as output:
                shutil.copyfileobj(upload.file, output, length=1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            names.append(path.name)
            if crop_monitor:
                cropped = staging / f".crop-{index}{path.suffix}"
                try:
                    did_crop = crop_monitor_file(path, cropped)
                except ImportError:
                    crop_warning = "PC 서버에 OpenCV 설치가 필요합니다. 원본을 저장했습니다."
                    did_crop = False
                except Exception:
                    crop_warning = "자동 보정하지 못한 사진은 원본으로 저장했습니다."
                    did_crop = False
                if did_crop:
                    originals = staging / "_originals"
                    originals.mkdir(exist_ok=True)
                    path.replace(originals / path.name)
                    cropped.replace(path)
                    cropped_names.append(path.name)

        # Reserve the destination atomically, including concurrent requests in
        # the same second. Publish only once every file has been fully written.
        counter = 0
        while True:
            destination = UPLOAD_ROOT / (base if counter == 0 else f"{base}_{counter}")
            try:
                destination.mkdir()
                break
            except FileExistsError:
                counter += 1
        try:
            for name in names:
                (staging / name).replace(destination / name)
            if (staging / "_originals").is_dir():
                (staging / "_originals").replace(destination / "_originals")
        except Exception:
            shutil.rmtree(destination)
            raise
        return {"directory": destination.name, "files": names, "count": len(names),
                "cropped": cropped_names, "crop_requested": crop_monitor,
                "crop_warning": crop_warning}
    finally:
        shutil.rmtree(staging, ignore_errors=True)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/upload")
async def upload(
    files: Annotated[list[UploadFile], File()],
    tag: Annotated[str, Form()] = "",
    crop_monitor: Annotated[bool, Form()] = False,
) -> dict:
    if not files:
        raise HTTPException(status_code=400, detail="No files supplied")
    try:
        return await run_in_threadpool(save_batch, files, tag, crop_monitor)
    except OSError as error:
        raise HTTPException(status_code=500, detail=f"File save failed: {error}") from error
    finally:
        for image in files:
            await image.close()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
