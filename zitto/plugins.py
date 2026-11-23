"""Additions installed separately, found through Python entry points. See docs/PLUGINS.md."""

from __future__ import annotations

from functools import cache
from importlib.metadata import entry_points

problems: list[str] = []  # plugins that could not be loaded, and why


def _load(group: str) -> list:
    found = []
    for entry in entry_points(group=group):
        try:
            found.append(entry.load()())
        except Exception as e:  # a broken plugin must not stop the program
            problems.append(f"The plugin {entry.name} could not be loaded: {e or type(e).__name__}")
    return found


@cache
def links() -> tuple:
    """Where links can be opened from: objects of class source.LinkSource."""
    return tuple(_load("zitto.links"))


@cache
def model_set():
    """A models.ModelSet to use instead of the default one, or None."""
    return next(iter(_load("zitto.models")), None)
