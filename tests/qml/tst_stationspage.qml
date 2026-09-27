// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The Stations settings page against a stand-in plasmoid, watched the way the
// settings dialog watches it. plasmoidviewer's dialog (plasma-sdk 6.7) lights
// Apply on every cfg_*Changed signal and on configurationChanged, whatever the
// value, and copies the cfg_ keys back before it calls the page's saveConfig();
// the Plasma 6.7 desktop dialog compares values first and copies the keys back
// after saveConfig(). The page must look unchanged to both when the popup
// changes the list underneath it, and a save through either must still write
// what the page holds and nothing stale.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "StationsPage"
    when: windowShown
    width: 800
    height: 600

    readonly property string two: JSON.stringify([
        { name: "Alpha", hostname: "http://a.example/s", favicon: "", active: true },
        { name: "Beta", hostname: "http://b.example/s", favicon: "", active: true }])

    // What the popup writes while the page is open: its logo backfill.
    function withLogo(json, host, logo) {
        var list = JSON.parse(json)
        for (var i = 0; i < list.length; i++)
            if (list[i].hostname === host) list[i].favicon = logo
        return JSON.stringify(list)
    }

    property QtObject plasmoid: QtObject {
        property QtObject configuration: QtObject {
            property string servers: ""
            property real speedfactor: 1
            property int writes: 0
            function writeConfig() { writes++ }
        }
    }
    // The page's labels call i18n(); qmltestrunner has no KLocalizedContext.
    function i18n(s) {
        var out = s
        for (var i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, arguments[i])
        return out
    }

    // The dialog's side of the contract, as far as a page can see it.
    property int dirty: 0
    function watch(page) {
        tc.dirty = 0
        var sig = page["cfg_serversChanged"]
        if (sig) sig.connect(function() { tc.dirty++ })
        if (page.configurationChanged) page.configurationChanged.connect(function() { tc.dirty++ })
    }
    // plasmoidviewer: cfg_ keys first, then the page's own save.
    function saveCfgFirst(page) {
        if ("cfg_servers" in page) plasmoid.configuration.servers = page.cfg_servers
        plasmoid.configuration.writeConfig()
        if (page.hasOwnProperty("saveConfig")) page.saveConfig()
    }
    // The Plasma 6.7 desktop: the page's own save first, then the cfg_ keys.
    function savePageFirst(page) {
        if (page.saveConfig) page.saveConfig()
        if ("cfg_servers" in page) plasmoid.configuration.servers = page.cfg_servers
        plasmoid.configuration.writeConfig()
    }

    function open(json) {
        plasmoid.configuration.servers = json
        var c = Qt.createComponent(Qt.resolvedUrl("../../package/contents/ui/config/configGeneral.qml"))
        compare(c.status, Component.Ready, c.errorString())
        // Like the dialog: every stored key offered as a cfg_ property, which
        // the page may or may not declare (an undeclared one only warns).
        var page = c.createObject(tc, { cfg_servers: json })
        verify(page !== null)
        watch(page)
        return page
    }

    function names(page) {
        return page.getServersArray().map(function(s) { return s.name + (s.favicon ? "+logo" : "") }).join(",")
    }

    function test_a_list_taken_over_from_the_popup_leaves_the_page_unchanged() {
        // Seen on the bench: the popup gave three stations their logos while
        // the page was open, Apply lit up, and leaving the page asked "Apply
        // Settings?" with nothing changed here.
        var page = open(two)
        plasmoid.configuration.servers = withLogo(two, "http://a.example/s", "https://a.example/l.png")
        compare(names(page), "Alpha+logo,Beta", "the page shows what the popup wrote")
        compare(dirty, 0, "a list taken over from the popup reads as an edit")
        page.destroy()
    }

    // The reason the page follows the popup at all: OK with nothing edited
    // must not write the page's older copy over what the popup just saved.
    function test_ok_without_an_edit_leaves_the_popups_list_alone() {
        var saves = [saveCfgFirst, savePageFirst]
        for (var k = 0; k < saves.length; k++) {
            var page = open(two)
            var popup = withLogo(two, "http://b.example/s", "https://b.example/l.png")
            plasmoid.configuration.servers = popup
            saves[k](page)
            compare(plasmoid.configuration.servers, popup, "shell " + k + " saved an older list")
            compare(dirty, 0)
            page.destroy()
        }
    }

    function test_an_edit_lights_apply_and_is_what_gets_saved() {
        var saves = [saveCfgFirst, savePageFirst]
        for (var k = 0; k < saves.length; k++) {
            var page = open(two)
            // What the row's Hide action does.
            page.view.model.setProperty(1, "active", false)
            page._edited()
            verify(dirty > 0, "shell " + k + ": an edit went unannounced")
            saves[k](page)
            var saved = JSON.parse(plasmoid.configuration.servers)
            compare(saved.length, 2)
            compare(saved[1].active, false, "shell " + k + " lost the edit")
            page.destroy()
        }
    }

    // Read in appletsrc on the bench (2026-09-23): one Hide and Apply wrote
    // "objectName":"" into all twenty stations. get() hands back the row's
    // QObject wrapper, and JSON.stringify took its objectName along.
    function test_a_saved_station_carries_its_own_fields_and_nothing_else() {
        var saves = [saveCfgFirst, savePageFirst]
        for (var k = 0; k < saves.length; k++) {
            var page = open(two)
            page.view.model.setProperty(1, "active", false)
            page._edited()
            saves[k](page)
            var saved = JSON.parse(plasmoid.configuration.servers)
            for (var i = 0; i < saved.length; i++)
                compare(Object.keys(saved[i]).sort().join(","), "active,favicon,hostname,name",
                        "shell " + k + ", row " + i)
            page.destroy()
        }
    }

    function test_an_edit_and_a_popup_change_are_both_kept() {
        // Local edits keep the three-way merge they always had: the popup's
        // logo lands on the row this page did not touch, the hidden row stays
        // hidden, and Apply still writes both.
        var page = open(two)
        page.view.model.setProperty(1, "active", false)
        page._edited()
        var marked = dirty
        plasmoid.configuration.servers = withLogo(two, "http://a.example/s", "https://a.example/l.png")
        compare(names(page), "Alpha+logo,Beta")
        savePageFirst(page)
        var saved = JSON.parse(plasmoid.configuration.servers)
        compare(saved[0].favicon, "https://a.example/l.png")
        compare(saved[1].active, false)
        verify(marked > 0)
        page.destroy()
    }

    function test_after_a_save_the_page_follows_the_popup_quietly_again() {
        var page = open(two)
        page.view.model.setProperty(0, "active", false)
        page._edited()
        saveCfgFirst(page)
        tc.dirty = 0                         // what Apply does to the button
        var after = withLogo(plasmoid.configuration.servers, "http://b.example/s", "https://b.example/l.png")
        plasmoid.configuration.servers = after
        compare(names(page), "Alpha,Beta+logo")
        compare(dirty, 0, "the page's own save left it marked as edited")
        saveCfgFirst(page)
        compare(plasmoid.configuration.servers, after)
        page.destroy()
    }

    function test_an_edit_that_changes_nothing_is_not_an_edit() {
        var page = open(two)
        page.view.model.setProperty(0, "active", true)   // it already was
        page._edited()
        page._edited()
        verify(dirty <= 1, "the same list announced itself twice")
        page.destroy()
    }
}
