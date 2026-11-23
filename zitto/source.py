"""Turn what the user gave, a file or a link that a plugin understands, into a local audio file."""

from __future__ import annotations

import hashlib
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import plugins

Status = Callable[[str], None]
SONG, LIST, SONG_IN_LIST = "song", "list", "song in list"  # what a link leads to


class SourceError(RuntimeError):
    pass


class SourceBlocked(SourceError):
    """A site is refusing this computer: trying other links would not help."""


@dataclass(frozen=True)
class Track:
    path: Path
    title: str
    artist: str = ""

    @property
    def name(self) -> str:
        return full_name(self.artist, self.title)


@dataclass(frozen=True)
class Playlist:
    title: str
    songs: tuple[tuple[str, str], ...]  # (name, link)


class LinkSource:
    """Base of the plugins that open links. See docs/PLUGINS.md."""

    label = "a link"  # what can be pasted, as the window and the command line say it

    def accepts(self, link: str) -> bool:
        raise NotImplementedError

    def get_track(self, link: str, workdir: Path, status: Status) -> Track:
        """Put the audio in `workdir`. Raises SourceError with a text for the user."""
        raise NotImplementedError

    def clean(self, link: str) -> str:
        """One spelling for all the links to the same song."""
        return link.strip()

    def key(self, link: str) -> str:
        """Identifies the song, and is the name of its folder: letters, digits, "-" and "_"."""
        return digest(self.clean(link))

    def kind(self, link: str) -> str:
        """SONG, LIST, or SONG_IN_LIST when it could mean either."""
        return SONG

    def list_id(self, link: str) -> str:
        """Identifies a list, however the link is written."""
        return self.clean(link)

    def read_list(self, link: str, status: Status) -> Playlist:
        raise SourceError("That link is not a list.")


def digest(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]


def plain(text: str) -> str:
    """For comparing and searching: no capitals, no accents, single spaces."""
    text = unicodedata.normalize("NFKD", text.casefold())
    return " ".join("".join(c for c in text if not unicodedata.combining(c)).split())


def full_name(artist: str, title: str) -> str:
    """"Artist - Title", unless the title already says who it is."""
    return f"{artist} - {title}" if artist and plain(artist) not in plain(title) else title


def file_credits(path: Path) -> tuple[str, str]:
    """Artist and title from the tags of a file, or its name."""
    try:
        from tinytag import TinyTag

        tags = TinyTag.get(path, duration=False)
        artist, title = ((text or "").strip() for text in (tags.artist, tags.title))
    except Exception:  # damaged or unknown files have no tags to offer
        artist = title = ""
    return (artist, title) if artist and title else ("", path.stem)


def is_url(source: str) -> bool:
    return bool(re.match(r"https?://", source.strip(), re.IGNORECASE))


def link_source(text: str) -> LinkSource | None:
    """The plugin that opens a link, if there is one."""
    if not is_url(text):
        return None
    return next((s for s in plugins.links() if s.accepts(text.strip())), None)


def need_link_source(link: str) -> LinkSource:
    found = link_source(link)
    if found is None:
        raise SourceError("This is a link, and only files can be opened.")
    return found


def kind(text: str) -> str | None:
    """What a link leads to; None for files and for links that no plugin opens."""
    found = link_source(text)
    return found.kind(text.strip()) if found else None


def read_playlist(link: str, status: Status = print) -> Playlist:
    return need_link_source(link).read_list(link.strip(), status)


def safe_filename(name: str, limit: int = 150) -> str:
    """Make a title usable as a Windows file name."""
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    name = re.sub(r"\s+", " ", name).strip(" .")[:limit].rstrip(" .")
    if re.fullmatch(r"(con|prn|aux|nul|com\d|lpt\d)", name, re.IGNORECASE):
        name = f"_{name}"
    return name or "track"


def get_track(source: str, workdir: Path, status: Status = print) -> Track:
    source = source.strip().strip('"')
    if is_url(source):
        return need_link_source(source).get_track(source, workdir, status)
    path = Path(source).expanduser()
    if not path.is_file():
        raise SourceError(f"File not found: {path}")
    artist, title = file_credits(path)
    return Track(path.resolve(), title, artist)
