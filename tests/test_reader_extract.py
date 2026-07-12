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
