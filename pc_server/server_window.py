"""Dedicated desktop console for the photo upload server."""
import logging
import os
import queue
import sys
import threading
import traceback
import tkinter as tk
from tkinter import messagebox, ttk
from tkinter.scrolledtext import ScrolledText


class LogStream:
    encoding = "utf-8"

    def __init__(self, messages):
        self.messages = messages

    def write(self, text):
        if text:
            self.messages.put(text)
        return len(text)

    def flush(self):
        pass

    def isatty(self):
        return False


class ServerWindow:
    def __init__(self, root):
        self.root = root
        self.messages = queue.Queue()
        self.worker = None
        self.server = None
        self.closing = False
        self.stopping = False
        self.saved_streams = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = LogStream(self.messages)
        root.title("Photo Uploader · PC 서버")
        root.geometry("1000x620")
        root.minsize(700, 400)
        root.protocol("WM_DELETE_WINDOW", self.close)
        header = ttk.Frame(root, padding=12)
        header.pack(fill="x")
        self.status = tk.StringVar(value="시작 준비 중")
        ttk.Label(header, textvariable=self.status, font=("맑은 고딕", 12, "bold")).pack(side="left")
        self.start_button = ttk.Button(header, text="서버 시작", command=self.start)
        self.start_button.pack(side="right", padx=4)
        self.stop_button = ttk.Button(header, text="서버 중지", command=self.stop)
        self.stop_button.pack(side="right", padx=4)
        ttk.Label(root, text="수신 주소: 0.0.0.0:8000 · 스마트폰에서는 PC의 Tailscale 주소로 접속",
                  padding=(12, 0, 12, 8)).pack(anchor="w")
        self.log = ScrolledText(root, bg="#111827", fg="#e5e7eb", insertbackground="white",
                               font=("Consolas", 11), wrap="word", state="disabled")
        self.log.pack(fill="both", expand=True, padx=12)
        footer = ttk.Frame(root, padding=12)
        footer.pack(fill="x")
        ttk.Label(footer, text="창을 닫으면 진행 중인 요청을 마친 뒤 서버를 종료합니다.").pack(side="left")
        ttk.Button(footer, text="저장 폴더 열기", command=self.open_folder).pack(side="right", padx=4)
        ttk.Button(footer, text="로그 지우기", command=self.clear).pack(side="right", padx=4)
        self.root.after(100, self.poll)
        self.start()

    def start(self):
        if self.closing or (self.worker and self.worker.is_alive()):
            return
        self.server = None
        self.stopping = False
        self.status.set("서버 시작 중…")
        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self.worker = threading.Thread(target=self.run_server, daemon=False)
        self.worker.start()

    def run_server(self):
        try:
            import uvicorn
            from server import app, UPLOAD_ROOT
            config = uvicorn.Config(app, host="0.0.0.0", port=8000, use_colors=False)
            self.server = uvicorn.Server(config)
            logging.getLogger("uvicorn.error").info("사진 저장 폴더: %s", UPLOAD_ROOT.resolve())
            if not self.stopping:
                self.server.run()
        except BaseException:
            traceback.print_exc()
            print("서버를 실행하지 못했습니다. 위 오류를 확인하세요.")
            print("의존성 설치: .\\.venv\\Scripts\\python -m pip install -r pc_server/requirements.txt")

    def stop(self):
        if self.worker and self.worker.is_alive():
            self.stopping = True
            self.status.set("서버 종료 중… 진행 중인 요청을 기다립니다.")
            self.stop_button.configure(state="disabled")
            if self.server:
                self.server.should_exit = True

    def close(self):
        self.closing = True
        self.start_button.configure(state="disabled")
        self.stop()

    def clear(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def open_folder(self):
        try:
            from server import UPLOAD_ROOT
            UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
            os.startfile(str(UPLOAD_ROOT.resolve()))
        except Exception as error:
            messagebox.showerror("저장 폴더 열기 실패", str(error), parent=self.root)

    def poll(self):
        chunks = []
        for _ in range(500):
            try:
                chunks.append(self.messages.get_nowait())
            except queue.Empty:
                break
        if chunks:
            at_bottom = self.log.yview()[1] >= 0.99
            self.log.configure(state="normal")
            self.log.insert("end", "".join(chunks))
            lines = int(self.log.index("end-1c").split(".")[0])
            if lines > 10000:
                self.log.delete("1.0", f"{lines - 10000}.0")
            if at_bottom:
                self.log.see("end")
            self.log.configure(state="disabled")
        alive = self.worker is not None and self.worker.is_alive()
        if not alive:
            self.stop_button.configure(state="disabled")
            if self.closing:
                sys.stdout, sys.stderr = self.saved_streams
                self.root.destroy()
                return
            self.start_button.configure(state="normal")
            self.status.set("서버 중지됨 · 시작 실패 시 아래 로그를 확인하세요.")
        elif self.server and self.server.started and not self.stopping:
            self.status.set("● 서버 실행 중 · 포트 8000")
        self.root.after(100, self.poll)


def main():
    root = tk.Tk()
    ServerWindow(root)
    root.mainloop()


if __name__ == "__main__":
    main()
