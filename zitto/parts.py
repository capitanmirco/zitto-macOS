"""The controls beside the waveform: name, mute, solo and volume of each part.

One canvas instead of some forty widgets, which Windows moves and paints one by one: too slow
while the window is being resized.
"""

from __future__ import annotations

import tkinter as tk
from typing import Callable

from .theme import ACCENT, BAD, BG, BUTTON, DIM, PANEL, TEXT

BUTTONS = 0.6  # share of the height of a row for name and buttons; the rest is the volume


def target(x: float, y: float, width: float, height: float, side: float) -> str:
    """What is at a point of a row: "name", "mute", "solo" or "volume"."""
    if y >= height * BUTTONS:
        return "volume"
    if x < width - side:
        return "name"
    return "mute" if y < height * BUTTONS / 2 else "solo"


class PartControls(tk.Canvas):
    """Calls on_mute(i), on_solo(i) and on_volume(i, 0..1)."""

    def __init__(self, parent, scale: float, labels: list[str], colors: list[str],
                 on_mute: Callable[[int], None], on_solo: Callable[[int], None],
                 on_volume: Callable[[int, float], None]):
        super().__init__(parent, bg=BG, width=round(190 * scale), highlightthickness=0, bd=0, cursor="hand2",
                         takefocus=0)
        self._k = scale
        self._colors = colors
        self._on_mute, self._on_solo, self._on_volume = on_mute, on_solo, on_volume
        self._places: list[tuple[int, int]] = []  # top and height of each row
        self._volumes = [1.0] * len(labels)
        self._dragging: int | None = None
        self._rows = [self._build_row(label) for label in labels]
        self.bind("<ButtonPress-1>", self._press)
        self.bind("<B1-Motion>", self._move)
        self.bind("<ButtonRelease-1>", self._release)

    def _build_row(self, label: str) -> dict[str, int]:
        def box(color):
            return self.create_rectangle(0, 0, 0, 0, width=0, fill=color)

        row = {"back": box(PANEL), "name": box(BUTTON), "mute": box(BUTTON), "solo": box(BUTTON),
               "track": box(BUTTON), "level": box(DIM), "knob": box(TEXT)}
        row["label"] = self.create_text(0, 0, text=label, anchor="w", font=("Segoe UI Semibold", 10))
        for name in ("mute", "solo"):
            row[f"{name} text"] = self.create_text(0, 0, text=name[0].upper(), font=("Segoe UI Semibold", 8))
        return row

    @property
    def _side(self) -> int:
        return round(32 * self._k)

    def place_rows(self, places: list[tuple[int, int]]) -> None:
        """Align with the lanes: top and height of each."""
        if places == self._places:
            return
        self._places = places
        width, side = int(self["width"]) - 4, self._side
        for row, (top, height) in zip(self._rows, places):
            bottom = top + height - 2
            buttons = top + round(height * BUTTONS)
            middle = top + round(height * BUTTONS / 2)
            left = width - side + 1
            self.coords(row["back"], 0, top, width, bottom)
            self.coords(row["name"], 0, top, width - side, buttons)
            self.coords(row["label"], 10 * self._k, middle)
            self.coords(row["mute"], left, top, width, middle - 1)
            self.coords(row["solo"], left, middle, width, buttons)
            self.coords(row["mute text"], (left + width) / 2, (top + middle - 1) / 2)
            self.coords(row["solo text"], (left + width) / 2, (middle + buttons) / 2)
        for i in range(len(self._rows)):
            self._place_volume(i)

    def _volume_span(self) -> tuple[float, float]:
        return 10 * self._k, int(self["width"]) - 4 - 10 * self._k

    def _place_volume(self, i: int) -> None:
        if i >= len(self._places):
            return
        top, height = self._places[i]
        first, last = self._volume_span()
        y = top + height * (1 + BUTTONS) / 2 - 1
        x = first + (last - first) * self._volumes[i]
        half, knob = 2 * self._k, 5 * self._k
        row = self._rows[i]
        self.coords(row["track"], first, y - half, last, y + half)
        self.coords(row["level"], first, y - half, x, y + half)
        self.coords(row["knob"], x - half, y - knob, x + half, y + knob)

    def show(self, i: int, heard: bool, muted: bool, solo: bool, volume: float) -> None:
        row, color = self._rows[i], self._colors[i]
        self.itemconfigure(row["name"], fill=color if heard else BUTTON)
        self.itemconfigure(row["label"], fill=BG if heard else DIM)
        self.itemconfigure(row["mute"], fill=BAD if muted else BUTTON)
        self.itemconfigure(row["mute text"], fill=BG if muted else DIM)
        self.itemconfigure(row["solo"], fill=ACCENT if solo else BUTTON)
        self.itemconfigure(row["solo text"], fill=BG if solo else DIM)
        self.itemconfigure(row["level"], fill=color if heard else DIM)
        if volume != self._volumes[i]:
            self._volumes[i] = volume
            self._place_volume(i)

    def _press(self, event) -> None:
        for i, (top, height) in enumerate(self._places):
            if top <= event.y < top + height:
                what = target(event.x, event.y - top, int(self["width"]) - 4, height, self._side)
                if what == "volume":
                    self._dragging = i
                    self._move(event)
                elif what == "solo":
                    self._on_solo(i)
                else:
                    self._on_mute(i)
                return

    def _move(self, event) -> None:
        if self._dragging is not None:
            first, last = self._volume_span()
            self._on_volume(self._dragging, min(max((event.x - first) / (last - first), 0.0), 1.0))

    def _release(self, event) -> None:
        self._dragging = None
