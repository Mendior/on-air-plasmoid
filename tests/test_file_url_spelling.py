# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""PathLogic.fileUrl against a real FolderListModel.

The widget asks "is this the file that is playing" by comparing two URL
strings, one from the folder model and one built from a file name. They
differed in the brackets every download carries, and nothing noticed. The
table in tst_pathlogic.qml holds what Qt 6.12 wrote; this asks the Qt that
is installed, with a file for every ASCII character and the Unicode that
tends to get special treatment.

QML cannot create files, so the folder is made here and the test that reads
it is written next to it.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PATHLOGIC = ROOT / "package" / "contents" / "ui" / "PathLogic.js"
RUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")

QML = """
import QtQuick
import QtTest
import Qt.labs.folderlistmodel
import "PathLogic.js" as PathLogic

TestCase {
    name: "FileUrlSpelling"
    when: flm.status === FolderListModel.Ready
    property url asThePlayerHoldsIt
    FolderListModel { id: flm; folder: %(folder)s; showDirs: false }
    function test_every_file_is_spelled_as_the_model_spells_it() {
        tryCompare(flm, "count", %(count)d, 10000)
        for (var i = 0; i < flm.count; i++) {
            var fromModel = flm.get(i, "fileUrl").toString()
            var built = PathLogic.fileUrl(flm.get(i, "filePath"))
            compare(built, fromModel)
            asThePlayerHoldsIt = built
            compare(asThePlayerHoldsIt.toString(), fromModel)
        }
        console.log("SPELLED " + flm.count)
    }
}
"""


def _names() -> list[str]:
    names = [
        "Episode 12 [3f1c9a7e].mp3",
        "100% pure #42 [aaaaaaaa].mp3",
        "what? [bbbbbbbb].mp3",
        "a+b & c=d; e@f, g! (h) ~i [cccccccc].mp3",
        "curly {x} ^caret [eeeeeeee].mp3",
        "percent %41 %zz %5B [22222222].mp3",
        "\u00c4\u00f6 \u0436 \u8a9e \U0001f3a7 e\u0301 [dddddddd].mp3",
    ]
    points = [c for c in range(1, 0x80) if c != ord("/")]
    points += range(0x80, 0xA1)
    points += [0xAD, 0x34F, 0x61C, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x202E]
    points += [0x2060, 0x3000, 0xFDD0, 0xFEFF, 0xFFFD, 0xFFFE, 0xFFFF, 0xE000]
    points += [0x1F3A7, 0xE0001, 0x10FFFF]
    names += ["%06x a%sb.mp3" % (c, chr(c)) for c in points]
    return names


def test_a_built_file_url_is_the_folder_models_own(tmp_path: Path) -> None:
    if RUNNER == "none" or not os.access(RUNNER, os.X_OK):
        pytest.skip(f"no Qt 6 qmltestrunner at {RUNNER}; the qml job has one")
    # No "#" in the folder itself: FolderListModel on Qt 6.12 lists nothing
    # under such a path (status stays Null), with or without this code.
    pods = tmp_path / "my [music] 100% {x}" / "Podcasts"
    pods.mkdir(parents=True)
    names = _names()
    for name in names:
        (pods / name).touch()
    shutil.copy(PATHLOGIC, tmp_path / "PathLogic.js")
    test = tmp_path / "tst_fileurlspelling.qml"
    test.write_text(
        QML % {"folder": json.dumps(pods.as_uri()), "count": len(names)},
        encoding="utf-8",
    )
    p = subprocess.run(
        [RUNNER, "-input", str(test)],
        env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
        capture_output=True,
        text=True,
        timeout=60,
    )
    out = p.stdout + p.stderr
    assert p.returncode == 0, out[-4000:]
    # A QML file the runner could not load fails quietly, so the test body
    # has to say that it ran, and over how many files.
    assert f"SPELLED {len(names)}" in out, out[-4000:]
