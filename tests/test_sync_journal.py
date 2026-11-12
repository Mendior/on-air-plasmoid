# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
"""What the sync engine writes into the journal, read as the journal gives it.

On 2026-11-11 the delay map went from 181 to 161 a minute and a half after a
panel restart and the journal had no line for it. Three of the map's four
writers say what they did; the fourth, a hand on the fine-tune, said nothing,
and the hand could only be found by ruling the others out. The same evening
a settle round spent its five reads on probes that could not be read and
ended without a word.

A QML test cannot see a console.log. So one test of tst_syncengine.qml drives
the engine through each of those roads with a marker between them, and what
qmltestrunner prints for it is read here line by line, as it would stand in
the journal after the timestamp.
"""

import os
import subprocess
from pathlib import Path

import pytest

# The module starts qmltestrunner once.
pytestmark = pytest.mark.slow

REPO = Path(__file__).resolve().parent.parent
QMLTESTRUNNER = os.environ.get("QMLTESTRUNNER", "/usr/lib/qt6/bin/qmltestrunner")
WRITER = "SyncEngine::test_the_engine_writes_its_journal_for_the_reader_of_the_lines"
BT = "AA:BB:CC:DD:EE:FF"
HAND = "[ARP] sync: fine-tune set by hand (slider, wheel or ms field) — map "
GAVE_UP = "[ARP] sync: settle gave up its window — "


@pytest.fixture(scope="module")
def steps() -> dict[str, list[str]]:
    """Every line the engine logged, under the step it was logged in."""
    if not os.path.exists(QMLTESTRUNNER):
        pytest.skip("Qt 6 qmltestrunner is not installed")
    done = subprocess.run(
        [QMLTESTRUNNER, "-input", str(REPO / "tests" / "qml" / "tst_syncengine.qml"), WRITER],
        capture_output=True,
        text=True,
        timeout=120,
        env=dict(os.environ, QT_QPA_PLATFORM="offscreen"),
    )
    out = done.stdout + done.stderr
    assert "\nPASS   : qmltestrunner::" + WRITER + "()" in out, out[-3000:]
    found: dict[str, list[str]] = {}
    step = ""
    for line in out.splitlines():
        at = line.find("qml: ")
        if at < 0:
            continue
        said = line[at + len("qml: ") :]
        if said.startswith("STEP "):
            step = said[len("STEP ") :]
            found[step] = []
        elif step:
            found[step].append(said)
    assert "end" in found, sorted(found)
    return found


def _sync(lines: list[str]) -> list[str]:
    return [line for line in lines if line.startswith("[ARP] sync: ")]


def _maps(lines: list[str]) -> list[str]:
    return [line[len("MAP ") :] for line in lines if line.startswith("MAP ")]


def test_a_delay_set_by_hand_leaves_one_line_with_the_map_before_and_after(steps: dict[str, list[str]]) -> None:
    before, after = _maps(steps["hand"])
    assert before == '{"%s":181}' % BT
    assert '"%s":161' % BT in after
    assert _sync(steps["hand"]) == [HAND + before + " -> " + after]


def test_setting_the_delay_it_already_has_leaves_nothing(steps: dict[str, list[str]]) -> None:
    """Nothing at all, not even an empty line."""
    assert steps["same"] == []


def test_every_call_that_moves_the_map_is_its_own_line(steps: dict[str, list[str]]) -> None:
    """The engine does not gather: the popup does, handing over a drag at
    its release and a run of wheel notches once it has stopped. Three calls
    that reach the engine are three changes of the stored map."""
    said = _sync(steps["notches"])
    assert len(said) == 3 and all(line.startswith(HAND) for line in said), said
    for line, (was, now) in zip(said, [(161, 171), (171, 181), (181, 191)], strict=True):
        left, right = line[len(HAND) :].split(" -> ")
        assert '"%s":%d' % (BT, was) in left and '"%s":%d' % (BT, now) in right, line
    assert said[-1].endswith(" -> " + _maps(steps["notches"])[0])


def test_a_hand_that_moves_no_map_leaves_nothing(steps: dict[str, list[str]]) -> None:
    """With no Bluetooth speaker in the group the slider has nobody's delay
    to write: the stored number moves and the map does not."""
    assert steps["no bluetooth"] == []


@pytest.mark.parametrize(
    ("step", "own"),
    [
        ("settle", "[ARP] sync: settle correction from three flat readings — map "),
        ("fold", "[ARP] sync: quiet fold from the median of 3 checks — map "),
        ("calibration", "[ARP] sync: calibration verdict 150 ms"),
        ("verify", "[ARP] sync: verify fold, twice-confirmed — map "),
    ],
)
def test_the_other_writers_of_the_map_keep_their_own_line_and_do_not_borrow_this_one(
    steps: dict[str, list[str]], step: str, own: str
) -> None:
    said = _sync(steps[step])
    assert len([line for line in said if line.startswith(own)]) == 1, said
    assert not [line for line in said if "set by hand" in line], said


def test_a_settle_round_whose_probes_all_came_back_unreadable_says_it_is_over(steps: dict[str, list[str]]) -> None:
    over = [line for line in _sync(steps["unread"]) if line.startswith(GAVE_UP)]
    assert over == [GAVE_UP + "no reads left, 0 of three readings in hand"]


def test_a_settle_round_that_ran_out_two_readings_short_says_how_many_it_had(steps: dict[str, list[str]]) -> None:
    over = [line for line in _sync(steps["short"]) if line.startswith(GAVE_UP)]
    assert over == [GAVE_UP + "no reads left, 2 of three readings in hand"]


def test_a_settle_round_that_made_its_verdict_does_not_say_it_gave_up(steps: dict[str, list[str]]) -> None:
    assert not [line for line in _sync(steps["settle"]) if line.startswith(GAVE_UP)]
