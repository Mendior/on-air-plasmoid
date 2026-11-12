# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""The sliding buffer's folder helper, run against real folders.

The widget cannot list a folder or write a file, so tsslide.sh does both. The
text of a list is the widget's own (SlideLogic.listText); the helper puts it
in place whole and grows it by the segments that are really on disk. What the
player does with a list that names a missing segment was measured on the
bench: 4.1 s of silence.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "package" / "contents" / "ui" / "tsslide.sh"
SEG = 2
HEAD = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%d\n#EXT-X-PLAYLIST-TYPE:EVENT\n"


def _entries(first: int, upto: int) -> str:
    return "".join("#EXTINF:%d,\nseg-%d.ts\n" % (SEG, n) for n in range(first, upto + 1))


def _list_text(first: int, upto: int) -> str:
    return HEAD % (SEG, first) + _entries(first, upto)


def _run(*args: str, stdin: str = "") -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(HELPER), *args], input=stdin, capture_output=True, text=True, timeout=20, check=False)


def _folder(tmp_path: Path, first: int = 100, last: int = 160, listed_from: int | None = None, name: str = "buffer-7.hls") -> Path:
    """A folder as ffmpeg leaves it: finished segments, one being cut, its own list."""
    d = tmp_path / name
    d.mkdir()
    for n in range(first, last + 1):
        (d / ("seg-%d.ts" % n)).write_bytes(b"G" * 188)
    (d / ("seg-%d.ts.tmp" % (last + 1))).write_bytes(b"G" * 94)
    start = first if listed_from is None else listed_from
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:%d" % start]
    for n in range(start, last + 1):
        lines += ["#EXTINF:1.996911,", "seg-%d.ts" % n]
    (d / "live.m3u8").write_text("\n".join(lines) + "\n")
    return d


# ------------------------------------------------------------------- have


def test_have_names_the_oldest_and_the_newest_finished_segment(tmp_path):
    d = _folder(tmp_path)
    r = _run("have", str(d))
    assert r.returncode == 0
    assert r.stdout == "__TS_HAVE__ first=100 last=160\n"


def test_have_takes_ffmpegs_list_at_its_word_about_the_oldest(tmp_path):
    # ffmpeg keeps one segment on disk that its list no longer names, and
    # removes it when the next one is finished: it is not there to open.
    d = _folder(tmp_path, first=99, last=160, listed_from=100)
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=100 last=160\n"


def test_have_reads_a_list_of_one_segment_and_one_ffmpeg_has_closed(tmp_path):
    d = _folder(tmp_path, first=0, last=0)
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=0 last=0\n"
    # A writer that was stopped ends its own list; the segments stay.
    with (d / "live.m3u8").open("a") as f:
        f.write("#EXT-X-ENDLIST\n")
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=0 last=0\n"


def test_have_says_so_when_there_is_nothing_yet(tmp_path):
    d = tmp_path / "buffer-7.hls"
    d.mkdir()
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=-1 last=-1\n"
    # The first segment is still being cut: no list, one .tmp file.
    (d / "seg-0.ts.tmp").write_bytes(b"G")
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=-1 last=-1\n"
    (d / "live.m3u8").write_text("")
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=-1 last=-1\n"
    (d / "live.m3u8").write_text("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n")
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=-1 last=-1\n"


def test_have_refuses_what_is_not_a_buffer_folder(tmp_path):
    for args in ([], [str(tmp_path / "missing" / "buffer-7.hls")], [str(tmp_path)], [""], ["/"]):
        r = _run("have", *args)
        assert r.stdout == "__TS_HAVE__ first=-1 last=-1\n", args
    other = _folder(tmp_path, name="music")
    assert _run("have", str(other)).stdout == "__TS_HAVE__ first=-1 last=-1\n"


def test_have_reads_a_four_hour_window(tmp_path):
    d = tmp_path / "buffer-7.hls"
    d.mkdir()
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:15760800"]
    for n in range(15760800, 15768000):
        lines += ["#EXTINF:1.996911,", "seg-%d.ts" % n]
    (d / "live.m3u8").write_text("\n".join(lines) + "\n")
    assert _run("have", str(d)).stdout == "__TS_HAVE__ first=15760800 last=15767999\n"


# ------------------------------------------------------------------ write


def test_write_puts_the_list_in_place_whole(tmp_path):
    d = _folder(tmp_path)
    text = _list_text(125, 139)
    r = _run("write", str(d), "play-3.m3u8", "139", stdin=text)
    assert r.stdout == "__TS_LIST__ last=139 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == text
    assert not list(d.glob("*.m3u8.tmp")), "the temporary file was left behind"


def test_write_replaces_a_list_of_the_same_name(tmp_path):
    d = _folder(tmp_path)
    (d / "play-3.m3u8").write_text("old\n")
    assert _run("write", str(d), "play-3.m3u8", "160", stdin=_list_text(160, 160)).stdout == "__TS_LIST__ last=160 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(160, 160)


def test_write_refuses_a_list_whose_last_segment_is_not_on_disk(tmp_path):
    d = _folder(tmp_path)
    # 161 is still being cut.
    assert _run("write", str(d), "play-3.m3u8", "161", stdin=_list_text(150, 161)).stdout == "__TS_LIST_FAIL__\n"
    assert not (d / "play-3.m3u8").exists()
    assert not list(d.glob("*.tmp.*")) and not list(d.glob("play-*.tmp"))


def test_write_refuses_names_numbers_and_folders_that_are_not_its_own(tmp_path):
    d = _folder(tmp_path)
    text = _list_text(125, 139)
    bad = [
        ["write", str(d), "../evil.m3u8", "139"],
        ["write", str(d), "live.m3u8", "139"],
        ["write", str(d), "play-3.m3u8/", "139"],
        ["write", str(d), "play-x.m3u8", "139"],
        ["write", str(d), "play-3.m3u8", "-1"],
        ["write", str(d), "play-3.m3u8", "1 2"],
        ["write", str(d), "play-3.m3u8", ""],
        ["write", str(d), "play-3.m3u8"],
        ["write", str(d)],
        ["write"],
        ["write", str(tmp_path), "play-3.m3u8", "139"],
        ["write", str(tmp_path / "gone" / "buffer-7.hls"), "play-3.m3u8", "139"],
    ]
    for args in bad:
        assert _run(*args, stdin=text).stdout == "__TS_LIST_FAIL__\n", args
    assert sorted(p.name for p in d.glob("*.m3u8*")) == ["live.m3u8"]
    assert not (tmp_path / "evil.m3u8").exists()


def test_write_refuses_an_empty_text(tmp_path):
    d = _folder(tmp_path)
    assert _run("write", str(d), "play-3.m3u8", "139", stdin="").stdout == "__TS_LIST_FAIL__\n"
    assert not (d / "play-3.m3u8").exists()


# Two ways a list cannot be put in its place. A folder without write permission is the one a listener
# meets, and it stops nobody who runs as root, which is what a container's build job does: there the
# list was written and both tests failed. A folder standing where the new list is first written stops
# root as well, and ends in the same refusal.
_ROOT = os.geteuid() == 0
UNWRITABLE = [
    pytest.param("read-only", marks=pytest.mark.skipif(_ROOT, reason="root writes into a folder whatever its mode says")),
    "in-the-way",
]


def _unwritable(d: Path, how: str) -> None:
    if how == "read-only":
        d.chmod(0o555)
    else:
        (d / "play-3.m3u8.tmp").mkdir()


def _writable_again(d: Path, how: str) -> None:
    if how == "read-only":
        d.chmod(0o755)
    else:
        (d / "play-3.m3u8.tmp").rmdir()


@pytest.mark.parametrize("how", UNWRITABLE)
def test_write_says_so_when_the_folder_cannot_be_written(tmp_path, how):
    d = _folder(tmp_path)
    _unwritable(d, how)
    try:
        assert _run("write", str(d), "play-3.m3u8", "139", stdin=_list_text(125, 139)).stdout == "__TS_LIST_FAIL__\n"
    finally:
        _writable_again(d, how)
    assert not (d / "play-3.m3u8").exists()


def test_write_takes_a_whole_window(tmp_path):
    d = _folder(tmp_path, first=1000, last=1000)
    (d / "seg-8199.ts").write_bytes(b"G")
    text = _list_text(1000, 8199)
    assert _run("write", str(d), "play-9.m3u8", "8199", stdin=text).stdout.startswith("__TS_LIST__ last=8199 ")
    assert (d / "play-9.m3u8").read_text() == text


# ------------------------------------------------------------------- grow


def test_grow_adds_the_segments_that_are_there(tmp_path):
    d = _folder(tmp_path)
    _run("write", str(d), "play-3.m3u8", "139", stdin=_list_text(125, 139))
    r = _run("grow", str(d), "play-3.m3u8", "140", "145", stdin=_entries(140, 145))
    assert r.stdout == "__TS_LIST__ last=145 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(125, 145)
    assert not list(d.glob("*.m3u8.tmp"))


def test_grow_stops_at_the_first_segment_not_yet_finished(tmp_path):
    d = _folder(tmp_path)
    _run("write", str(d), "play-3.m3u8", "157", stdin=_list_text(150, 157))
    # 158..160 are finished, 161 is being cut, 162 does not exist.
    r = _run("grow", str(d), "play-3.m3u8", "158", "162", stdin=_entries(158, 162))
    assert r.stdout == "__TS_LIST__ last=160 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(150, 160)


def test_grow_adds_nothing_when_the_next_segment_is_not_there(tmp_path):
    d = _folder(tmp_path)
    _run("write", str(d), "play-3.m3u8", "160", stdin=_list_text(150, 160))
    before = (d / "play-3.m3u8").stat().st_mtime_ns
    r = _run("grow", str(d), "play-3.m3u8", "161", "164", stdin=_entries(161, 164))
    assert r.stdout == "__TS_LIST__ last=160 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(150, 160)
    assert (d / "play-3.m3u8").stat().st_mtime_ns == before, "an unchanged list was written again"


def test_grow_does_not_step_over_a_gap(tmp_path):
    d = _folder(tmp_path)
    (d / "seg-152.ts").unlink()
    _run("write", str(d), "play-3.m3u8", "150", stdin=_list_text(140, 150))
    r = _run("grow", str(d), "play-3.m3u8", "151", "155", stdin=_entries(151, 155))
    assert r.stdout == "__TS_LIST__ last=151 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(140, 151)


def test_a_segment_with_nothing_in_it_is_not_there(tmp_path):
    """Measured on a 300 KiB tmpfs: when the disk is full ffmpeg goes on
    making a file for every segment, with nothing in it, and says nothing.
    A list that named one would send the player into it."""
    d = _folder(tmp_path)
    (d / "seg-152.ts").write_bytes(b"")
    _run("write", str(d), "play-3.m3u8", "150", stdin=_list_text(140, 150))
    r = _run("grow", str(d), "play-3.m3u8", "151", "155", stdin=_entries(151, 155))
    assert r.stdout == "__TS_LIST__ last=151 newest=160\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(140, 151)
    # Nor may a new list end in one.
    assert _run("write", str(d), "play-4.m3u8", "152", stdin=_list_text(140, 152)).stdout == "__TS_LIST_FAIL__\n"
    assert not (d / "play-4.m3u8").exists()


def test_grow_refuses_a_list_that_is_not_there_and_arguments_that_are_not_its_own(tmp_path):
    d = _folder(tmp_path)
    ent = _entries(140, 145)
    assert _run("grow", str(d), "play-3.m3u8", "140", "145", stdin=ent).stdout == "__TS_LIST_FAIL__\n"
    assert not (d / "play-3.m3u8").exists()
    # Also when no segment is there to add: a list that is gone has not grown.
    assert _run("grow", str(d), "play-3.m3u8", "161", "165", stdin=_entries(161, 165)).stdout == "__TS_LIST_FAIL__\n"
    _run("write", str(d), "play-3.m3u8", "139", stdin=_list_text(125, 139))
    bad = [
        ["grow", str(d), "live.m3u8", "140", "145"],
        ["grow", str(d), "../play-3.m3u8", "140", "145"],
        ["grow", str(d), "play-3.m3u8", "145", "140"],
        ["grow", str(d), "play-3.m3u8", "x", "145"],
        ["grow", str(d), "play-3.m3u8", "140", ""],
        ["grow", str(d), "play-3.m3u8", "140"],
        ["grow", str(d)],
        ["grow"],
        ["grow", str(tmp_path), "play-3.m3u8", "140", "145"],
    ]
    for args in bad:
        assert _run(*args, stdin=ent).stdout == "__TS_LIST_FAIL__\n", args
    assert (d / "play-3.m3u8").read_text() == _list_text(125, 139)


def test_grow_refuses_a_text_shorter_than_the_segments_it_is_for(tmp_path):
    d = _folder(tmp_path)
    _run("write", str(d), "play-3.m3u8", "139", stdin=_list_text(125, 139))
    assert _run("grow", str(d), "play-3.m3u8", "140", "145", stdin=_entries(140, 142)).stdout == "__TS_LIST_FAIL__\n"
    assert _run("grow", str(d), "play-3.m3u8", "140", "145", stdin="").stdout == "__TS_LIST_FAIL__\n"
    assert (d / "play-3.m3u8").read_text() == _list_text(125, 139)


@pytest.mark.parametrize("how", UNWRITABLE)
def test_grow_says_so_when_the_folder_cannot_be_written(tmp_path, how):
    d = _folder(tmp_path)
    _run("write", str(d), "play-3.m3u8", "139", stdin=_list_text(125, 139))
    _unwritable(d, how)
    try:
        assert _run("grow", str(d), "play-3.m3u8", "140", "145", stdin=_entries(140, 145)).stdout == "__TS_LIST_FAIL__\n"
    finally:
        _writable_again(d, how)
    assert (d / "play-3.m3u8").read_text() == _list_text(125, 139)


def test_grow_keeps_a_list_that_has_grown_for_hours(tmp_path):
    d = _folder(tmp_path, first=0, last=0)
    for n in (7200, 7201):
        (d / ("seg-%d.ts" % n)).write_bytes(b"G")
    (d / "play-1.m3u8").write_text(_list_text(0, 7199))
    r = _run("grow", str(d), "play-1.m3u8", "7200", "7231", stdin=_entries(7200, 7231))
    assert r.stdout.startswith("__TS_LIST__ last=7201 ")
    assert (d / "play-1.m3u8").read_text() == _list_text(0, 7201)


# ----------------------------------------------------------- the real writer


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is not installed")
def test_have_reads_the_folder_ffmpeg_really_writes(tmp_path):
    """The widget's own ffmpeg arguments, fed eleven seconds of MP3."""
    d = tmp_path / "buffer-7.hls"
    d.mkdir()
    made = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=11",
         "-c:a", "libmp3lame", "-b:a", "64k", "-f", "mp3", str(tmp_path / "in.mp3")],
        capture_output=True, text=True, timeout=60, check=False)
    if made.returncode != 0:
        pytest.skip("this ffmpeg cannot encode MP3: " + made.stderr.strip()[:120])
    cut = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", str(tmp_path / "in.mp3"), "-c", "copy",
         "-f", "hls", "-hls_time", str(SEG), "-hls_list_size", "3", "-hls_segment_type", "mpegts",
         "-hls_flags", "delete_segments+temp_file", "-hls_segment_filename", str(d / "seg-%d.ts"), "-y", str(d / "live.m3u8")],
        capture_output=True, text=True, timeout=60, check=False)
    assert cut.returncode == 0, cut.stderr
    on_disk = sorted(int(p.stem.split("-")[1]) for p in d.glob("seg-*.ts"))
    out = _run("have", str(d)).stdout
    assert out == "__TS_HAVE__ first=%d last=%d\n" % (on_disk[-3], on_disk[-1]), (out, on_disk)
    # Every segment the answer names is a file, and ffmpeg kept one more.
    assert len(on_disk) == 4, on_disk
    assert _run("write", str(d), "play-1.m3u8", str(on_disk[-1]), stdin=_list_text(on_disk[-3], on_disk[-1])).stdout == (
        "__TS_LIST__ last=%d newest=%d\n" % (on_disk[-1], on_disk[-1]))


def test_an_unknown_word_is_a_usage_error():
    r = _run("sweep", "/tmp")
    assert r.returncode == 2
    assert "usage" in r.stderr
    assert _run().returncode == 2
