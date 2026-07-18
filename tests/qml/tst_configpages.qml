// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The settings pages are the one QML surface neither qmllint nor the
// plasmoidviewer smoke ever loads — 2026.7.2 shipped a blank page exactly
// that way. Component COMPILATION (no instantiation, so no plasmoid
// context is needed) catches that whole class: bad imports, duplicate
// properties, assignments to a non-existent default property.
import QtQuick
import QtTest

TestCase {
    name: "ConfigPagesCompile"

    function test_every_settings_page_compiles() {
        var pages = [
            "../../package/contents/config/config.qml",
            "../../package/contents/ui/config/configGeneral.qml",
            "../../package/contents/ui/config/configAppearance.qml",
            "../../package/contents/ui/config/configRecording.qml",
            "../../package/contents/ui/config/configSearch.qml",
        ]
        for (var i = 0; i < pages.length; i++) {
            var c = Qt.createComponent(Qt.resolvedUrl(pages[i]))
            if (c.status === Component.Error)
                fail(pages[i] + ": " + c.errorString())
            compare(c.status, Component.Ready, pages[i])
        }
    }
}
