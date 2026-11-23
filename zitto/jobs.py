"""Starts and follows the background processes of the window (see worker.py)."""

from __future__ import annotations

import json
import queue
import re
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def _start(*args: str) -> subprocess.Popen:
    python = Path(sys.executable).with_name("python.exe")  # also when the window runs under pythonw
    # -P: do not import from the folder the program was started in.
    return subprocess.Popen(
        [str(python if python.exists() else sys.executable), "-P", "-m", "zitto.worker", *args],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def _lines(child: subprocess.Popen):
    for raw in child.stdout:
        try:
            data = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue  # something a library printed
        if isinstance(data, dict) and "event" in data:
            yield data


class Work:
    """The worker. Puts ("work", data) in `events`; the last one has the event "ended".

    `run` changes at each start and stop: events with another number are late ones, to ignore.
    """

    def __init__(self, events: queue.Queue):
        self._events = events
        self._child: subprocess.Popen | None = None
        self.run = 0

    @property
    def running(self) -> bool:
        return self._child is not None

    def start(self) -> None:
        if not self.running:
            workdir = tempfile.TemporaryDirectory(prefix="zitto_", ignore_cleanup_errors=True)
            self._child = _start(workdir.name)
            self.run += 1
            threading.Thread(target=self._follow, args=(self._child, self.run, workdir), daemon=True).start()
            threading.Thread(target=self._progress, args=(self._child, self.run), daemon=True).start()

    def _send(self, run: int, data: dict) -> None:
        self._events.put(("work", data | {"run": run}))

    def _follow(self, child: subprocess.Popen, run: int, workdir: tempfile.TemporaryDirectory) -> None:
        for data in _lines(child):
            self._send(run, data)
        code = child.wait()
        workdir.cleanup()
        self._send(run, {"event": "ended", "code": code})

    def _progress(self, child: subprocess.Popen, run: int) -> None:
        """Percentages from the progress bars that the libraries draw on stderr."""
        last = None
        while chunk := child.stderr.read1(4096):
            found = re.findall(rb"(\d{1,3})%\|", chunk)
            if found and found[-1] != last:
                last = found[-1]
                self._send(run, {"event": "progress", "percent": int(last)})

    def ended(self) -> None:
        """To be called when the "ended" event is handled: from here it can start again."""
        self._child = None

    def stop(self) -> None:
        child, self._child = self._child, None
        self.run += 1
        if child and child.poll() is None:
            child.kill()
            child.wait(timeout=10)


def add_playlist(link: str, events: queue.Queue) -> None:
    """Read a playlist in the background. Puts ("added", data) in `events`."""
    def follow():
        child = _start("--add", link)
        answer = {"event": "error", "text": "The playlist could not be read."}
        threading.Thread(target=child.stderr.read, daemon=True).start()
        for data in _lines(child):
            answer = data
        child.wait()
        events.put(("added", answer))

    threading.Thread(target=follow, daemon=True).start()
