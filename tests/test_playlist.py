"""Playlist tests: no GPU, models or network. ffmpeg must be on PATH."""

import numpy as np
import pytest

from zitto import audio, cli, remover, source
from zitto.targets import resolve
from test_zitto import FakeEngine

LIST = "https://songs.example/list/one"
SONG_IN_LIST = "https://songs.example/alpha?list=one"
VOICE = resolve(["voice"])

pytestmark = pytest.mark.usefixtures("links")


@pytest.mark.parametrize("text, expected", [
    (LIST, source.LIST), (f"  {LIST}  ", source.LIST), (SONG_IN_LIST, source.SONG_IN_LIST),
    ("https://songs.example/alpha", source.SONG), ("https://elsewhere.example/list/one", None),
    (r"C:\music\list\song.mp3", None),
])
def test_what_a_link_leads_to(text, expected):
    assert source.kind(text) == expected


@pytest.fixture
def playlist(monkeypatch, tmp_path):
    """A playlist whose songs are local files; the second one is missing."""
    songs = []
    for name in ("one", "gone", "three"):
        path = tmp_path / f"{name}.wav"
        if name != "gone":
            audio.write_wav(path, np.full((2000, 2), 0.2, np.float32))
        songs.append((name, str(path)))
    monkeypatch.setattr(remover, "read_playlist", lambda url, status: source.Playlist("My: list", tuple(songs)))
    return songs


def run(tmp_path, engine=None, **kwargs):
    return remover.remove_playlist(LIST, VOICE, tmp_path / "out", "flac", status=lambda s: None,
                                   engine=engine or FakeEngine({"voice": lambda m: m * 0.5}), **kwargs)


def names(summary):
    return sorted(p.name for p in summary.folder.iterdir())


def test_one_bad_track_does_not_stop_the_others(playlist, tmp_path):
    summary = run(tmp_path)
    assert summary.folder.name == "My_ list"
    assert names(summary) == ["001 - one (no voice).flac", "003 - three (no voice).flac"]
    assert (summary.done, summary.skipped) == (2, 0) and not summary.complete
    assert "not found" in summary.problems()[0] and summary.problems()[0].startswith("002 - gone")
    assert str(summary) == "2 of 3 tracks done, 1 failed"


def test_running_again_only_does_what_is_missing(playlist, tmp_path):
    run(tmp_path)
    audio.write_wav(tmp_path / "gone.wav", np.full((2000, 2), 0.2, np.float32))
    engine = FakeEngine({"voice": lambda m: m * 0.5})
    summary = run(tmp_path, engine)
    assert (summary.done, summary.skipped, len(engine.calls)) == (1, 2, 1) and summary.complete


def test_skip_also_needs_the_removed_part_when_asked(playlist, tmp_path):
    run(tmp_path)
    summary = run(tmp_path, save_removed=True)
    assert summary.done == 2 and summary.skipped == 0
    assert "001 - one (no voice) - removed part.flac" in names(summary) and len(names(summary)) == 4


def test_other_targets_are_not_mistaken_for_done(playlist, tmp_path):
    run(tmp_path)
    summary = remover.remove_playlist(LIST, resolve(["drums"]), tmp_path / "out", "flac", status=lambda s: None,
                                      engine=FakeEngine({"drums": lambda m: m * 0.5}))
    assert summary.done == 2 and len(names(summary)) == 4


def test_stops_when_the_site_refuses(playlist, tmp_path, monkeypatch):
    calls = []

    def blocked(*args, **kwargs):
        calls.append(args)
        raise source.SourceBlocked("Download failed: too many requests")

    monkeypatch.setattr(remover, "fetch", blocked)
    summary = run(tmp_path)
    assert len(calls) == 1 and "too many requests" in summary.problems()[-1] and not summary.complete


def test_interruption_leaves_no_file_that_looks_finished(playlist, tmp_path, monkeypatch):
    real = audio._ffmpeg

    def interrupted(*args):
        if ".part" in args[-1]:
            with open(args[-1], "w") as f:
                f.write("half")
            raise KeyboardInterrupt
        real(*args)

    monkeypatch.setattr(audio, "_ffmpeg", interrupted)
    with pytest.raises(KeyboardInterrupt):
        run(tmp_path)
    assert not list((tmp_path / "out").rglob("*.flac"))


def test_long_names_fit_the_windows_limit(tmp_path):
    out = remover.output_path(tmp_path / "x", "t" * 400, resolve(["voice", "drums", "bass"]), "flac")
    longest = remover.removed_path(out)
    partial = longest.with_name(f"{longest.stem}.part{longest.suffix}")
    assert len(str(partial.resolve())) < 260 and out.name.endswith("(no voice, drums, bass).flac")
    with pytest.raises(source.SourceError, match="too long"):
        remover.output_path(tmp_path / ("d" * 230), "title", VOICE, "mp3")


def test_removed_part_is_not_overwritten_without_an_explicit_output(tmp_path):
    song = tmp_path / "song.wav"
    audio.write_wav(song, np.full((2000, 2), 0.2, np.float32))
    engine = FakeEngine({"voice": lambda m: m * 0.5})
    first = remover.remove(str(song), VOICE, tmp_path, "flac", save_removed=True, engine=engine, status=lambda s: None)
    first.output.unlink()
    second = remover.remove(str(song), VOICE, tmp_path, "flac", save_removed=True, engine=engine, status=lambda s: None)
    assert second.output == first.output and second.removed != first.removed and first.removed.exists()


@pytest.mark.parametrize("args, message", [
    ([LIST, "-o", "x.mp3"], "use -d"),
    ([SONG_IN_LIST, "--playlist", "-o", "x.mp3"], "use -d"),
    (["https://songs.example/alpha", "--playlist"], "no playlist"),
])
def test_cli_rejects(args, message, capsys):
    with pytest.raises(SystemExit):
        cli.main(args)
    assert message in capsys.readouterr().err


def test_cli_routes_links(monkeypatch, capsys, tmp_path):
    calls = []
    summary = remover.Summary(tmp_path, 3, done=2, failed=[("002 - x", "private")])
    monkeypatch.setattr(remover, "remove_playlist", lambda *a, **k: calls.append("list") or summary)
    monkeypatch.setattr(remover, "remove", lambda *a, **k: calls.append("one") or remover.Result(tmp_path, None))
    assert cli.main([LIST]) == 1  # something failed
    assert cli.main([SONG_IN_LIST, "--playlist"]) == 1
    assert "002 - x: private" in capsys.readouterr().err
    assert cli.main([SONG_IN_LIST]) == 0
    assert "--playlist" in capsys.readouterr().out
    assert calls == ["list", "list", "one"]
