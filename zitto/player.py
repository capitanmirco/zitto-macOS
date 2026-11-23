"""The player: parts switched live, waveform with a loop, MIDI transport, saving the mix."""

from __future__ import annotations

import tempfile
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from . import audio, library, midi, settings
from .cli import DEFAULT_OUT
from .library import StemSet
from .mixer import PAUSED, PLAYING, RATE, STOPPED, Mixer, mixdown
from .models import LABELS
from .models import parts as current_parts
from .parts import PartControls
from .source import safe_filename
from .theme import ACCENT, BG, BUTTON, COLORS, DIM, EDGE, TEXT, button
from .waveform import Waveform, clock

NO_PORT = "Off"


class Output:
    """Plays whatever mixer it is given on the default sound card."""

    def __init__(self):
        import sounddevice as sd

        self.mixer: Mixer | None = None
        self.underruns = 0

        def callback(out, frames, time, status):
            self.underruns += bool(status.output_underflow)
            mixer = self.mixer
            out[:] = mixer.render(frames) if mixer else 0

        options = dict(samplerate=RATE, channels=2, dtype="float32", callback=callback, latency=0.05)
        wasapi = next((api for api in sd.query_hostapis() if "WASAPI" in api["name"]), None)
        try:
            if not wasapi or wasapi["default_output_device"] < 0:
                raise sd.PortAudioError("no WASAPI device")
            self._stream = sd.OutputStream(device=wasapi["default_output_device"],
                                           extra_settings=sd.WasapiSettings(auto_convert=True), **options)
        except sd.PortAudioError:
            self._stream = sd.OutputStream(**options)
        self._stream.start()
        self.latency = int(self._stream.latency * RATE)

    def close(self) -> None:
        self._stream.close()


def mix_name(audible: dict[str, bool]) -> str:
    """What to add to the title of a saved mix: " (no voice)", " (only drums, bass)", or nothing."""
    def words(names):
        names = list(names)
        if "lead" in names and "backing" in names:
            names = ["voice"] + [n for n in names if n not in ("lead", "backing")]
        shown = {"lead": "lead voice", "backing": "backing voices"}
        return ", ".join(shown.get(n, n) for n in names)

    on, off = [n for n, a in audible.items() if a], [n for n, a in audible.items() if not a]
    if not off:
        return ""
    return f" (only {words(on)})" if len(on) < len(off) else f" (no {words(off)})"


def heard(on: list[bool], solo: list[bool]) -> list[bool]:
    """Which parts sound: the soloed ones if any, else all; never the muted ones."""
    return [a and (s or not any(solo)) for a, s in zip(on, solo)]


class PlayerView(tk.Frame):
    def __init__(self, parent, k: float):
        super().__init__(parent, bg=BG)
        self.k = k
        self.key: str | None = None
        self.title = ""
        self.stems: StemSet | None = None
        self.mixer: Mixer | None = None
        self.output: Output | None = None
        self.saving = False
        self.names: tuple[str, ...] = ()  # parts of the song that is open
        self.on, self.solo, self.volume = [], [], []
        self._results: list[tuple[bool, str]] = []  # of saving, from its thread
        self._shown: dict = {}  # last options given to each widget

        self.midi: midi.MidiInput | None = None
        self.learning: str | None = None
        self.assign_window: tk.Toplevel | None = None
        self._midi_events: list[tuple[str, tuple]] = []  # from the MIDI thread
        saved = settings.load()
        self.bindings = midi.Bindings(saved.get("midi") if isinstance(saved.get("midi"), dict) else None)
        self.wanted_port = saved.get("midi_port")

        self._build()
        self._apply_levels()
        try:
            self.output = Output()
        except Exception as e:
            self.say(f"No audio output: {e}")
        try:
            self.midi = midi.MidiInput(self.on_midi)
            self._watch_ports()
        except Exception as e:
            self.say(f"MIDI is not available: {e}")

    def px(self, n: float) -> int:
        return round(n * self.k)

    def button(self, parent, text, command, width=None) -> tk.Button:
        return button(parent, text, command, self.k, width)

    # --- layout -----------------------------------------------------------

    def _build(self) -> None:
        self.columnconfigure(1, weight=1)
        self.rowconfigure(1, weight=1)
        side, gap = self.px(14), (0, self.px(6))

        # Only the waveform stretches with the window. The rows stay as they are, on the left:
        # moving every control at each step makes resizing jerky.
        head = tk.Frame(self, bg=BG)
        head.grid(row=0, column=0, columnspan=2, sticky="w", padx=side, pady=(self.px(12), self.px(6)))
        self.time = tk.Label(head, bg=BG, fg=TEXT, font=("Consolas", 15), anchor="w")
        self.time.pack(side="left")
        self.name = tk.Label(head, text="Add songs on the left. Double-click one to open it.",
                             bg=BG, fg=DIM, font=("Segoe UI Semibold", 13), anchor="w")
        self.name.pack(side="left")

        self.scrollbar = ttk.Scrollbar(self, orient="horizontal", takefocus=0)
        self.wave = Waveform(self, self.k, lambda pos: self.do("seek", pos),
                             lambda start, end: self.do("set_loop", start, end), self.scrollbar.set)
        self.scrollbar.configure(command=self.wave.scroll)
        self.wave.grid(row=1, column=1, sticky="nsew", padx=(0, side))
        self.scrollbar.grid(row=2, column=1, sticky="ew", padx=(0, side))
        self.parts: PartControls | None = None
        self._use_parts(current_parts())
        self.wave.bind("<Configure>", lambda e: self._place_parts())

        bar = tk.Frame(self, bg=BG)
        bar.grid(row=3, column=0, columnspan=2, sticky="w", padx=side, pady=(self.px(10), self.px(4)))
        self.buttons = {}
        for text in ("Rewind", "Play", "Pause", "Stop"):
            self.buttons[text] = self.button(bar, text, lambda a=text.lower(): self.do(a), 7)
            self.buttons[text].pack(side="left", padx=gap)
        tk.Frame(bar, bg=EDGE, width=1).pack(side="left", fill="y", padx=self.px(8))
        self.loop_button = self.button(bar, "Loop", self.toggle_loop, 6)
        self.loop_button.pack(side="left", padx=gap)
        self.button(bar, "Clear", lambda: self.do("clear_loop")).pack(side="left", padx=gap)
        self.button(bar, "Zoom to loop", self.wave.show_loop).pack(side="left", padx=gap)
        self.button(bar, "Show all", self.wave.show_all).pack(side="left", padx=gap)
        self.save_button = self.button(bar, "Save...", self.save)
        tk.Frame(bar, bg=EDGE, width=1).pack(side="left", fill="y", padx=self.px(8))
        self.save_button.pack(side="left", padx=gap)
        self.loop_text = tk.Label(bar, bg=BG, fg=DIM, font=("Consolas", 10))
        self.loop_text.pack(side="left", padx=self.px(8))

        foot = tk.Frame(self, bg=BG)
        foot.grid(row=4, column=0, columnspan=2, sticky="w", padx=side, pady=(self.px(4), self.px(12)))
        tk.Label(foot, text="MIDI", bg=BG, fg=DIM, font=("Segoe UI", 10)).pack(side="left", padx=gap)
        self.port = ttk.Combobox(foot, state="readonly", width=24, takefocus=0, values=[NO_PORT])
        self.port.set(NO_PORT)
        self.port.pack(side="left", padx=gap)
        self.port.bind("<<ComboboxSelected>>", lambda e: self._choose_port())
        self.button(foot, "Assign...", self._open_assign).pack(side="left", padx=gap)
        tk.Label(foot, bg=BG, fg=DIM, font=("Segoe UI", 9),
                 text="Drag: loop   Click: move   Wheel: zoom   Space: play/pause   Numbers: parts").pack(
            side="left", padx=self.px(8))
        self.message = tk.Label(foot, bg=BG, fg=TEXT, font=("Segoe UI", 9), anchor="w")
        self.message.pack(side="left", padx=self.px(8))

    def _use_parts(self, names: tuple[str, ...]) -> None:
        """Show the controls of these parts: songs separated with other models have others."""
        if names == self.names:
            return
        self.names = tuple(names)
        self.on, self.solo, self.volume = [True] * len(names), [False] * len(names), [1.0] * len(names)
        if self.parts:
            self.parts.destroy()
        self.parts = PartControls(self, self.k, [LABELS[n] for n in names], [COLORS[n] for n in names],
                                  self.toggle_part, self.toggle_solo, self.set_volume)
        self.parts.grid(row=1, column=0, sticky="ns", padx=(self.px(14), 0))
        self._place_parts()

    def _place_parts(self) -> None:
        self.parts.place_rows([self.wave.lane(i, len(self.names)) for i in range(len(self.names))])

    # --- songs ------------------------------------------------------------

    def leave(self) -> None:
        """Remember how the song was left and fade it out."""
        if self.mixer and self.key:
            library.save_state(self.key, self.state())
            if self.mixer.state == PLAYING:
                self.mixer.pause()

    def open(self, key: str, title: str, stems: StemSet, peaks: list) -> None:
        """Show a song. The previous one must have been left."""
        self.key, self.title, self.stems = key, title, stems
        self.mixer = Mixer(stems.data, stems.gain)
        self._use_parts(stems.names)
        self.name.configure(text=title, fg=TEXT)
        self.wave.set_tracks(peaks, [COLORS[n] for n in stems.names], self.mixer.length)
        self._restore(library.load_state(key))
        if self.output:
            self.output.mixer = self.mixer
        self.refresh()

    def rename(self, title: str) -> None:
        self.title = title
        self.name.configure(text=title)

    def state(self) -> dict:
        loop = self.mixer.loop
        return {"on": dict(zip(self.names, self.on)), "solo": dict(zip(self.names, self.solo)),
                "volume": dict(zip(self.names, self.volume)), "loop": list(loop) if loop else None,
                "loop_on": self.mixer.loop_on, "position": self.mixer.position}

    def _restore(self, state: dict) -> None:
        def part(kind, name, default):
            values = state.get(kind)
            return values.get(name, default) if isinstance(values, dict) else default

        self.on = [bool(part("on", n, True)) for n in self.names]
        self.solo = [bool(part("solo", n, False)) for n in self.names]
        self.volume = [min(max(float(part("volume", n, 1.0)), 0.0), 1.0) for n in self.names]
        loop = state.get("loop")
        if isinstance(loop, list) and len(loop) == 2:
            self.mixer.set_loop(int(loop[0]), int(loop[1]))
            self.mixer.enable_loop(bool(state.get("loop_on")))
        self.mixer.seek(int(state.get("position") or 0))
        self._apply_levels()

    # --- actions ----------------------------------------------------------

    def say(self, text: str) -> None:
        self.message.configure(text=text)

    def do(self, action: str, *args) -> None:
        """A method of the mixer, when there is a song."""
        if self.mixer:
            getattr(self.mixer, action)(*args)

    def toggle_loop(self) -> None:
        if self.mixer and self.mixer.loop is None:
            self.say("Drag on the waveform to choose what to repeat.")
        if self.mixer:
            self.mixer.enable_loop(not self.mixer.loop_on)

    def toggle_part(self, i: int) -> None:
        if i < len(self.on):  # the keys are there for all the parts that can exist
            self.on[i] = not self.on[i]
            self._apply_levels()

    def toggle_solo(self, i: int) -> None:
        self.solo[i] = not self.solo[i]
        self._apply_levels()

    def set_volume(self, i: int, value: float) -> None:
        self.volume[i] = value
        self._apply_levels()

    def audible(self) -> list[bool]:
        return heard(self.on, self.solo)

    def levels(self) -> list[float]:
        # Squared: the slider follows how loud it sounds rather than the amplitude.
        return [v ** 2 if a else 0.0 for v, a in zip(self.volume, self.audible())]

    def _apply_levels(self) -> None:
        audible = self.audible()
        for i, level in enumerate(self.levels()):
            self.do("set_level", i, level)
            self.parts.show(i, audible[i], not self.on[i], self.solo[i], self.volume[i])
        self.wave.set_audible(audible)

    # --- saving -----------------------------------------------------------

    def save(self) -> None:
        """Save what is heard: the parts that are on, at their volumes."""
        if not self.mixer or self.saving:
            return
        levels = self.levels()
        if not any(levels):
            self.say("Every part is off: there is nothing to save.")
            return
        name = safe_filename(self.title, 110) + mix_name(dict(zip(self.names, (bool(v) for v in levels))))
        start = Path(settings.load().get("save_dir") or DEFAULT_OUT)
        start.mkdir(parents=True, exist_ok=True)
        path = filedialog.asksaveasfilename(
            parent=self, initialdir=str(start), initialfile=f"{name}.mp3", defaultextension=".mp3",
            filetypes=[("MP3", "*.mp3"), ("FLAC", "*.flac"), ("WAV", "*.wav")])
        if path:
            settings.save(save_dir=str(Path(path).parent))
            self.save_to(Path(path), levels)

    def save_to(self, path: Path, levels: list[float]) -> None:
        self.saving = True
        self.save_button.configure(state="disabled")
        self.say(f"Saving {path.name}...")
        threading.Thread(target=self._write, args=(path, levels, self.stems, self.key), daemon=True).start()

    def _write(self, path: Path, levels: list[float], stems: StemSet, key: str) -> None:
        try:
            from .remover import limit

            song = library.get(key)
            tags = None
            if song and Path(song.source).is_file() and Path(song.source).resolve() != path.resolve():
                tags = Path(song.source)
            with tempfile.TemporaryDirectory(prefix="zitto_", ignore_cleanup_errors=True) as tmp:
                audio.encode(limit(mixdown(stems.data, stems.gain, levels)), path, Path(tmp), tags,
                             title=song.title if song else "")
            self._results.append((True, f"Saved: {path.name}"))
        except Exception as e:
            self._results.append((False, f"Could not save.\n\n{e or type(e).__name__}"))

    # --- MIDI -------------------------------------------------------------

    def on_midi(self, message) -> None:
        """MIDI thread: acts on the mixer at once, the window catches up at the next refresh."""
        t = midi.trigger(message)
        if t is None:
            return
        if self.learning:
            self._midi_events.append(("learned", (self.learning, t)))
            self.learning = None
            return
        actions = self.bindings.actions(t)
        for action in actions:
            self.do(action)
        self._midi_events.append(("heard", (t, actions)))

    def _handle_midi(self) -> None:
        while self._midi_events:
            kind, value = self._midi_events.pop(0)
            if kind == "learned":
                action, t = value
                self.bindings.learn(action, t)
                settings.save(midi=self.bindings.to_json())
                self.say(f"{midi.describe(t)}: {action}")
                self._refresh_assign()
            else:
                t, actions = value
                self.say(f"MIDI: {midi.describe(t)}" + (f" ({', '.join(actions)})" if actions else ""))

    def _watch_ports(self) -> None:
        """Follow devices being plugged and unplugged; reopen the chosen one when it is back."""
        self.after(2000, self._watch_ports)
        ports = self.midi.ports()
        if list(self.port["values"]) != [NO_PORT, *ports]:
            self.port["values"] = [NO_PORT, *ports]
        if self.midi.name and self.midi.name not in ports:
            self.say(f"MIDI device disconnected: {self.midi.name}")
            self.midi.close()
            self.port.set(NO_PORT)
        if self.wanted_port and not self.midi.name and (name := self.midi.find(self.wanted_port)):
            self._open_port(name)

    def _choose_port(self) -> None:
        name = self.port.get()
        self.port.selection_clear()
        self.wanted_port = None if name == NO_PORT else name
        settings.save(midi_port=self.wanted_port)
        if not self.midi:
            return
        if self.wanted_port:
            self._open_port(name)
        else:
            self.midi.close()
            self.say("")

    def _open_port(self, name: str) -> None:
        try:
            self.midi.open(name)
            self.port.set(name)
            self.say(f"MIDI connected: {name}")
        except OSError as e:
            self.wanted_port = None  # do not insist; choosing it again retries
            self.port.set(NO_PORT)
            self.say(str(e))

    def _open_assign(self) -> None:
        if self.assign_window:
            self.assign_window.lift()
            return
        window = self.assign_window = tk.Toplevel(self, bg=BG, padx=self.px(16), pady=self.px(14))
        window.title("MIDI controls")
        window.resizable(False, False)
        window.transient(self.winfo_toplevel())
        window.protocol("WM_DELETE_WINDOW", self._close_assign)
        tk.Label(window, bg=BG, fg=DIM, font=("Segoe UI", 9), justify="left", anchor="w",
                 text="Press Learn, then the button on your device.\n"
                      "MMC and Start/Continue/Stop messages work without learning.").grid(
            row=0, column=0, columnspan=4, sticky="w", pady=(0, self.px(10)))
        self.assign_rows = {}
        for r, action in enumerate(midi.ACTIONS, 1):
            tk.Label(window, text=action.capitalize(), bg=BG, fg=TEXT, font=("Segoe UI Semibold", 10), width=8,
                     anchor="w").grid(row=r, column=0, sticky="w")
            label = tk.Label(window, bg=BG, fg=TEXT, font=("Segoe UI", 10), width=24, anchor="w")
            label.grid(row=r, column=1, sticky="w")
            learn = self.button(window, "Learn", lambda a=action: self._learn(a), 9)
            learn.grid(row=r, column=2, padx=self.px(4), pady=self.px(3))
            self.button(window, "Clear", lambda a=action: self._unlearn(a)).grid(row=r, column=3)
            self.assign_rows[action] = (label, learn)
        self._refresh_assign()

    def _close_assign(self) -> None:
        self.learning = None
        self.assign_window.destroy()
        self.assign_window = None

    def _learn(self, action: str) -> None:
        self.learning = None if self.learning == action else action
        if self.learning and not (self.midi and self.midi.name):
            self.learning = None
            self.say("Choose a MIDI device first.")
        self._refresh_assign()

    def _unlearn(self, action: str) -> None:
        self.bindings.clear(action)
        settings.save(midi=self.bindings.to_json())
        self._refresh_assign()

    def _refresh_assign(self) -> None:
        if not self.assign_window:
            return
        for action, (label, learn) in self.assign_rows.items():
            t = self.bindings.get(action)
            label.configure(text=midi.describe(t) if t else "not assigned", fg=TEXT if t else DIM)
            waiting = self.learning == action
            learn.configure(text="Waiting..." if waiting else "Learn", bg=ACCENT if waiting else BUTTON,
                            fg=BG if waiting else TEXT)

    # --- refresh ----------------------------------------------------------

    def _set(self, widget, **options) -> None:
        """Configure a widget only when something changes: Tk draws it again in any case."""
        if self._shown.get(widget) != options:
            self._shown[widget] = options
            widget.configure(**options)

    def refresh(self) -> None:
        """Called many times a second by the window."""
        self._handle_midi()
        while self._results:
            good, text = self._results.pop(0)
            self.saving = False
            self.save_button.configure(state="normal")
            self.say(text if good else "Could not save.")
            if not good:
                messagebox.showerror("zitto", text)
        if not self.mixer:
            return
        mixer = self.mixer
        state, loop, loop_on, pos = mixer.state, mixer.loop, mixer.loop_on, mixer.position
        if state == PLAYING and self.output:  # what is heard now left the mixer a moment ago
            first = loop[0] if loop_on and pos >= loop[0] else 0
            pos = max(pos - self.output.latency, first)
        self.wave.set_loop(loop, loop_on)
        self.wave.set_head(pos, state == PLAYING)
        self._set(self.time, text=f"{clock(pos)} / {clock(mixer.length)}   ")
        active = {PLAYING: "Play", PAUSED: "Pause", STOPPED: "Stop"}[state]
        for name, b in self.buttons.items():
            self._set(b, bg=ACCENT if name == active else BUTTON, fg=BG if name == active else TEXT)
        self._set(self.loop_button, bg=ACCENT if loop_on else BUTTON, fg=BG if loop_on else TEXT)
        self._set(self.loop_text,
                  text=f"{clock(loop[0], 2)} - {clock(loop[1], 2)}  ({(loop[1] - loop[0]) / RATE:.2f} s)" if loop else "")

    def close(self) -> None:
        self.leave()
        if self.output:
            self.output.close()
        if self.midi:
            self.midi.close()
