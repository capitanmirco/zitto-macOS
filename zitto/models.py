"""The separation models: what each one finds, where it comes from and under which terms.

None is part of the program. Each is downloaded, the first time it is needed, from where its
authors or the audio-separator project published it. See NOTICE.md for the credits.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import plugins

# The parts of a song, in the order they are shown. A set of models may tell apart only some.
NAMES = ("lead", "backing", "drums", "bass", "guitar", "piano", "wind", "other")
LABELS = {"lead": "Lead voice", "backing": "Backing voices", "drums": "Drums", "bass": "Bass",
          "guitar": "Guitar", "piano": "Piano", "wind": "Wind", "other": "Other"}


@dataclass(frozen=True)
class Model:
    name: str
    file: str
    parts: dict[str, str] = field(hash=False)  # part ("voice", "lead", "drums"...) -> its name in the model
    terms: str = ""
    page: str = ""
    backend: str = "separator"  # or "openunmix"
    overlap: int | None = None  # how many times each moment is computed, where the model allows it


@dataclass(frozen=True)
class ModelSet:
    main: tuple[Model, ...]  # run in this order on the song, each on what the others left
    lead: Model  # the lead voice, inside the voice
    wind: Model  # the wind instruments, in what is left


_UVR = {"terms": "MIT, with credit to UVR and its developers (as their README asks)",
        "page": "https://github.com/Anjok07/ultimatevocalremovergui"}

VOICE = Model("UVR-MDX-NET Main", "UVR_MDXNET_Main.onnx", {"voice": "Vocals"}, **_UVR)
BAND = Model("Open-Unmix UMX-L", "umxl", {"drums": "drums", "bass": "bass", "other": "other"},
             "CC BY-NC-SA 4.0: not for commercial use", "https://zenodo.org/records/5069601", backend="openunmix")
LEAD = Model("UVR 6_HP-Karaoke", "6_HP-Karaoke-UVR.pth", {"lead": "Vocals"}, **_UVR)
WIND = Model("UVR 17_HP-Wind_Inst", "17_HP-Wind_Inst-UVR.pth", {"wind": "Woodwinds"}, **_UVR)

DEFAULT = ModelSet((VOICE, BAND), LEAD, WIND)


def current() -> ModelSet:
    return plugins.model_set() or DEFAULT


def provider(part: str) -> Model | None:
    """The model that finds a part in a whole song."""
    chosen = current()
    return next((m for m in (*chosen.main, chosen.lead, chosen.wind) if part in m.parts), None)


def parts() -> tuple[str, ...]:
    """The parts that the current models tell apart."""
    found = {"lead", "backing", "wind", "other"}.union(*(m.parts for m in current().main))
    return tuple(n for n in NAMES if n in found)
