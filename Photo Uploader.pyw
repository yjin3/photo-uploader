"""Double-click to launch the server without a console window."""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
pythonw = ROOT / ".venv" / "Scripts" / "pythonw.exe"
if pythonw.is_file() and Path(sys.executable).resolve() != pythonw.resolve():
    os.execv(str(pythonw), [str(pythonw), str(Path(__file__).resolve())])
sys.path.insert(0, str(ROOT / "pc_server"))
from server_window import main

main()
