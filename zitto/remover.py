"""Remove targets from a track: separate, subtract, export."""

from __future__ import annotations

import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import audio
from .engine import Engine
from .library import fetch
from .source import SourceBlocked, SourceError, Status, read_playlist, safe_filename
from .targets import Target, plan

# Peak level of the signal handed to the models: leaves room for a stem to be
# louder than the mix without reaching full scale.
WORKING_PEAK = 0.5
# Windows refuses paths over 259 characters; the margin covers " (2)" and ".part".
MAX_PATH = 245
REMOVED = " - removed part"


@dataclass(frozen=True)
class Result:
    output: Path
    removed: Path | None


@dataclass
class Summary:
    """Outcome of a playlist."""
    folder: Path
    total: int
    done: int = 0
    skipped: int = 0
    failed: list[tuple[str, str]] = field(default_factory=list)  # (track, reason)
    stopped: str | None = None

    @property
    def complete(self) -> bool:
        return not self.failed and not self.stopped

    def __str__(self) -> str:
        parts = [f"{self.done} of {self.total} tracks done"]
        if self.skipped:
            parts.append(f"{self.skipped} already there")
        if self.failed:
            parts.append(f"{len(self.failed)} failed")
        return ", ".join(parts)

    def problems(self) -> list[str]:
        lines = [f"{track}: {reason}" for track, reason in self.failed]
        return lines + [f"Stopped early. {self.stopped}"] if self.stopped else lines


def subtract(mix: np.ndarray, targets: list[Target], engine, workdir: Path,
             status: Status = print) -> np.ndarray:
    """Return `mix` without the targets. Models run in cascade on what is left."""
    peak = float(np.abs(mix).max())
    if peak == 0:
        return mix.copy()
    scale = min(1.0, WORKING_PEAK / peak)
    rest = mix * scale
    for model, group in plan(targets):
        names = ", ".join(t.key for t in group)
        if not engine.is_downloaded(model):
            status(f"Downloading the model for: {names} (first time only)")
        status(f"Separating: {names}")
        stems = engine.stems(rest, model, [t.part for t in group], workdir)
        for t in group:
            rest = rest - stems[t.part]
    return rest / scale


def limit(signal: np.ndarray) -> np.ndarray:
    """Lower the whole signal if it would clip."""
    peak = float(np.abs(signal).max(initial=0.0))
    return signal * (0.999 / peak) if peak > 0.999 else signal


def unique(path: Path) -> Path:
    candidate, n = path, 2
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} ({n}){path.suffix}")
        n += 1
    return candidate


def output_path(folder: Path, title: str, targets: list[Target], fmt: str) -> Path:
    tail = f" (no {', '.join(t.key for t in targets)}).{fmt}"
    room = MAX_PATH - len(str(folder.resolve())) - 1 - len(tail) - len(REMOVED)
    if room < 12:
        raise SourceError(f"The output folder has too long a path: {folder}")
    return folder / (safe_filename(title, min(room, 150)) + tail)


def removed_path(out: Path) -> Path:
    return out.with_name(f"{out.stem}{REMOVED}{out.suffix}")


def remove(source: str, targets: list[Target], out_dir: Path, fmt: str = "mp3",
           output: Path | None = None, save_removed: bool = False,
           engine: Engine | None = None, status: Status = print) -> Result:
    engine = engine or Engine()
    with tempfile.TemporaryDirectory(prefix="zitto_", ignore_cleanup_errors=True) as tmp:
        workdir = Path(tmp)
        track = fetch(source, workdir, status)
        if output and output.resolve() == track.path:
            raise SourceError("The output file is the source file. Choose another name.")
        status("Decoding audio...")
        mix = audio.decode(track.path, workdir)
        rest = subtract(mix, targets, engine, workdir, status)

        out = output or unique(output_path(out_dir, track.name, targets, fmt))
        status("Writing the result...")
        audio.encode(limit(rest), out, workdir, tags_from=track.path)

        removed = None
        if save_removed:
            removed = removed_path(out) if output else unique(removed_path(out))
            audio.encode(limit(mix - rest), removed, workdir, tags_from=track.path)
    return Result(out, removed)


def remove_playlist(url: str, targets: list[Target], out_dir: Path, fmt: str = "mp3",
                    save_removed: bool = False, engine: Engine | None = None,
                    status: Status = print) -> Summary:
    """Process every track into one folder. Tracks already there are skipped."""
    engine = engine or Engine()
    playlist = read_playlist(url, status)
    total = len(playlist.songs)
    summary = Summary(out_dir / safe_filename(playlist.title, 60), total)
    for n, (title, link) in enumerate(playlist.songs, 1):
        track = f"{n:03} - {title}"
        out = output_path(summary.folder, track, targets, fmt)
        if out.exists() and (not save_removed or removed_path(out).exists()):
            summary.skipped += 1
            status(f"[{n}/{total}] Already there: {title}")
            continue
        try:
            remove(link, targets, summary.folder, fmt, out, save_removed, engine,
                   lambda text: status(f"[{n}/{total}] {text}"))
            summary.done += 1
        except SourceBlocked as e:
            summary.stopped = str(e)
            status(f"[{n}/{total}] {e}")
            break
        except Exception as e:  # one bad track must not cost the others
            reason = str(e) or type(e).__name__
            summary.failed.append((track, reason))
            status(f"[{n}/{total}] Failed: {reason}")
    return summary
