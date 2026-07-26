# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""extract_field/decode_meta edge cases — ICY metadata is hostile input:
apostrophes in titles, semicolons in values, missing terminators, mixed
encodings."""


def test_simple_title_and_url(reader_funcs):
    ef = reader_funcs["extract_field"]
    raw = b"StreamTitle='Artist - Song';StreamUrl='http://x/';"
    assert ef(raw, b"StreamTitle=") == "Artist - Song"
    assert ef(raw, b"StreamUrl=") == "http://x/"


def test_semicolon_inside_value_is_kept(reader_funcs):
    ef = reader_funcs["extract_field"]
    raw = b"StreamTitle='AC/DC; Live at River Plate';"
    assert ef(raw, b"StreamTitle=") == "AC/DC; Live at River Plate"


def test_apostrophe_inside_title_survives(reader_funcs):
    ef = reader_funcs["extract_field"]
    raw = b"StreamTitle='Rockin' All Night';"
    assert ef(raw, b"StreamTitle=") == "Rockin' All Night"


def test_leading_apostrophe_title(reader_funcs):
    # Queen's "'39": only ONE delimiter quote may be stripped per side
    ef = reader_funcs["extract_field"]
    raw = b"StreamTitle=''39';"
    assert ef(raw, b"StreamTitle=") == "'39"


def test_missing_terminator_runs_to_end(reader_funcs):
    ef = reader_funcs["extract_field"]
    assert ef(b"StreamTitle='Unfinished", b"StreamTitle=") == "Unfinished"


def test_missing_terminator_with_closing_quote(reader_funcs):
    ef = reader_funcs["extract_field"]
    assert ef(b"StreamTitle='Done'", b"StreamTitle=") == "Done"


def test_unquoted_value_falls_back_to_bare_semicolon(reader_funcs):
    ef = reader_funcs["extract_field"]
    assert ef(b"StreamTitle=NoQuotes;rest", b"StreamTitle=") == "NoQuotes"


def test_absent_key_is_empty(reader_funcs):
    ef = reader_funcs["extract_field"]
    assert ef(b"StreamTitle='X';", b"StreamUrl=") == ""


def test_latin1_fallback(reader_funcs):
    # 0xE9 is not valid standalone UTF-8; Latin-1 maps it to é
    ef = reader_funcs["extract_field"]
    assert ef(b"StreamTitle='Beyonc\xe9';", b"StreamTitle=") == "Beyoncé"


def test_utf8_preferred(reader_funcs):
    ef = reader_funcs["extract_field"]
    raw = "StreamTitle='Sigur Rós';".encode("utf-8")
    assert ef(raw, b"StreamTitle=") == "Sigur Rós"


def test_decode_meta_never_raises(reader_funcs):
    dm = reader_funcs["decode_meta"]
    assert dm(b"\xff\xfe\x00garbage") != ""


def test_resolve_url_reads_token_url_from_file(reader_funcs, tmp_path):
    """The URL is handed over as a 0600 file (kept off /proc argv). resolve_url
    reads it back verbatim, including any per-listener token, minus whitespace."""
    ru = reader_funcs["resolve_url"]
    f = tmp_path / "src"
    f.write_text("https://cast.example/stream?token=SECRET123\n")
    assert ru(str(f)) == "https://cast.example/stream?token=SECRET123"


def test_resolve_url_passthrough_for_bare_url(reader_funcs):
    """A direct URL (test/manual invocation, no file) is used as-is."""
    ru = reader_funcs["resolve_url"]
    assert ru("http://direct.example/stream") == "http://direct.example/stream"


def test_resolve_url_blank_file_is_empty(reader_funcs, tmp_path):
    """A blank/cleared file yields '' so the caller exits quietly, not a crash."""
    ru = reader_funcs["resolve_url"]
    f = tmp_path / "empty"
    f.write_text("")
    assert ru(str(f)) == ""


def test_resolve_url_missing_file_is_empty(reader_funcs, tmp_path):
    """A MISSING file must yield '' (quiet retry), never the path itself — the
    path would reach requests.get() as a bogus URL and pin the station off."""
    ru = reader_funcs["resolve_url"]
    missing = tmp_path / "gone"
    assert ru(str(missing)) == ""


def test_resolve_url_https_passthrough(reader_funcs):
    """https URLs pass through too (scheme check, not a file probe)."""
    ru = reader_funcs["resolve_url"]
    assert ru("https://secure.example/stream") == "https://secure.example/stream"
