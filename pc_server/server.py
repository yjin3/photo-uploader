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


app = FastAPI(title="Photo Uploader")
UPLOAD_ROOT = Path(__file__).resolve().parent / "uploads"


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


def save_batch(files: list[UploadFile], tag: str) -> dict:
    UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    suffix = safe_name(tag.strip(), "", 60)
    base = stamp + (f"_{suffix}" if suffix else "")
    staging = Path(tempfile.mkdtemp(prefix=".upload-", dir=UPLOAD_ROOT))
    names = []
    try:
        for index, upload in enumerate(files, start=1):
            name = safe_name(upload.filename or "", f"image_{index}.jpg")
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
        except Exception:
            shutil.rmtree(destination)
            raise
        return {"directory": destination.name, "files": names, "count": len(names)}
    finally:
        shutil.rmtree(staging, ignore_errors=True)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/upload")
async def upload(
    files: Annotated[list[UploadFile], File()],
    tag: Annotated[str, Form()] = "",
) -> dict:
    if not files:
        raise HTTPException(status_code=400, detail="No files supplied")
    try:
        return await run_in_threadpool(save_batch, files, tag)
    except OSError as error:
        raise HTTPException(status_code=500, detail=f"File save failed: {error}") from error
    finally:
        for image in files:
            await image.close()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
