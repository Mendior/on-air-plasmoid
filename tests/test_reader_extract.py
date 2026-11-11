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


def test_a_windows_1252_dash_is_a_dash(reader_funcs):
    """Windows-1252 has an en dash at 0x96, where Latin-1 has a control
    character. Read as Latin-1 the line did not split into artist and
    title."""
    ef = reader_funcs["extract_field"]
    raw = "StreamTitle='A – B';".encode("cp1252")
    assert ef(raw, b"StreamTitle=") == "A – B"


def test_windows_1252_quotes_and_the_euro_sign(reader_funcs):
    dm = reader_funcs["decode_meta"]
    assert dm("Don’t Stop “Believin’”".encode("cp1252")) == "Don’t Stop “Believin’”"
    assert dm("Tõnis Mägi — Koit".encode("cp1252")) == "Tõnis Mägi — Koit"
    assert dm(b"\x80 5") == "€ 5"


def test_utf8_stays_first(reader_funcs):
    """The same dash in UTF-8 is three bytes, each of which Windows-1252 would
    read as a letter or a quote of its own."""
    dm = reader_funcs["decode_meta"]
    assert dm("A – B".encode("utf-8")) == "A – B"
    assert dm(b"") == ""
    assert dm(b"plain ascii") == "plain ascii"


def test_a_byte_windows_1252_leaves_undefined_still_decodes(reader_funcs):
    """Windows-1252 has no character at 0x81, 0x8d, 0x8f, 0x90 and 0x9d. A
    title with one of those is read as Latin-1 from end to end, as before."""
    dm = reader_funcs["decode_meta"]
    for byte in (0x81, 0x8D, 0x8F, 0x90, 0x9D):
        raw = b"Caf\xe9 " + bytes([byte])
        assert dm(raw) == "Café " + chr(byte)
    # The fallback is the whole line, not byte by byte.
    assert dm(b"A \x96 B \x81") == "A \x96 B \x81"


def test_a_full_metadata_block_of_dashes(reader_funcs):
    """255 * 16 bytes is the largest block ICY can carry."""
    dm = reader_funcs["decode_meta"]
    assert dm(b"\x96" * 4080) == "–" * 4080


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
