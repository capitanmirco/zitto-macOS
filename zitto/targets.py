"""What can be removed from a track, and which model does it."""

from __future__ import annotations

from dataclasses import dataclass

from .models import Model, provider


@dataclass(frozen=True)
class Target:
    key: str
    label: str
    part: str
    aliases: tuple[str, ...] = ()


TARGETS: tuple[Target, ...] = (
    Target("voice", "Voice (all singing)", "voice", ("vocals", "vocal", "voices", "voce", "voci", "canto")),
    Target("lead-voice", "Lead voice only (keeps backing vocals)", "lead", ("lead", "voce-principale", "solista")),
    Target("drums", "Drums", "drums", ("drum", "batteria")),
    Target("bass", "Bass", "bass", ("basso",)),
    Target("guitar", "Guitar", "guitar", ("guitars", "chitarra", "chitarre")),
    Target("piano", "Piano", "piano", ("pianoforte",)),
    Target("wind", "Wind (sax, flute, brass)", "wind", ("winds", "woodwinds", "sax", "flute", "fiati", "flauto")),
    Target("other", "Everything else (synths, strings...)", "other", ("altro",)),
)


class UnknownTarget(ValueError):
    pass


def available() -> tuple[Target, ...]:
    """The targets that the current models can find."""
    return tuple(t for t in TARGETS if provider(t.part))


def resolve(names: list[str]) -> list[Target]:
    """Turn user-supplied names into targets, in catalogue order, without duplicates."""
    offered = available()
    by_name = {name: t for t in offered for name in (t.key, *t.aliases)}
    chosen = set()
    for raw in names:
        for name in raw.lower().replace(",", " ").split():
            if name not in by_name:
                known = ", ".join(t.key for t in offered)
                raise UnknownTarget(f"Unknown target '{name}'. Choose from: {known}")
            chosen.add(by_name[name].key)
    if not chosen:
        raise UnknownTarget("Nothing to remove was specified.")
    if "voice" in chosen:
        chosen.discard("lead-voice")  # already part of the voice
    return [t for t in offered if t.key in chosen]


def plan(targets: list[Target]) -> list[tuple[Model, list[Target]]]:
    """Group targets by model so each model runs once."""
    steps: dict[Model, list[Target]] = {}
    for t in targets:
        steps.setdefault(provider(t.part), []).append(t)
    return list(steps.items())
