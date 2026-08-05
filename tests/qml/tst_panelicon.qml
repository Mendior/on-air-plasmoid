// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
//
// The panel icon's last rung. A listener on openSUSE switched icon themes and
// the panel went empty (GitHub #4): both names the widget defaults to —
// audio-radio-symbolic and radio-symbolic — are Breeze's own, and neither is
// in the freedesktop naming spec. CompactRepresentation now falls through to
// an icon that ships inside the widget, so there is always something to draw.
//
// What this pins is the MECHANISM: that a name no theme has really does end
// up as Kirigami.Icon.Error (the signal the fallback hangs on), and that the
// bundled file loads. That the two are wired together is pinned by
// test_the_widget_ships_its_own_panel_icon_and_falls_back_to_it.
import QtQuick
import QtTest
import org.kde.kirigami as Kirigami

Item {
    id: harness
    width: 64
    height: 64

    Kirigami.Icon {
        id: missing
        source: "on-air-test-no-such-icon-anywhere"
        fallback: "on-air-test-no-such-fallback-either"
        width: 22
        height: 22
    }

    Kirigami.Icon {
        id: bundled
        source: Qt.resolvedUrl("../../package/contents/icons/on-air.svg")
        width: 22
        height: 22
        isMask: true
    }

    TestCase {
        name: "PanelIcon"
        when: windowShown

        // Without this the fallback has nothing to react to: the whole fix
        // hangs on a missing name reaching Error rather than sitting at
        // Loading or quietly resolving to something else.
        function test_a_name_no_theme_carries_reports_error() {
            tryCompare(missing, "status", Kirigami.Icon.Error, 3000);
        }

        // The rung itself. A path that does not load would turn a blank panel
        // into a different blank panel.
        function test_the_bundled_icon_loads() {
            tryCompare(bundled, "status", Kirigami.Icon.Ready, 3000);
            verify(bundled.valid);
        }

        // isMask is what lets one monochrome file sit on a light panel and a
        // dark one; dropping it would leave the icon painted in its own ink.
        function test_the_bundled_icon_is_drawn_as_a_mask() {
            verify(bundled.isMask);
        }
    }
}
