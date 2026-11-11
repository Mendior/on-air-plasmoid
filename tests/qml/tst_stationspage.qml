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

    readonly property string three: JSON.stringify([
        { name: "Alpha", hostname: "http://a.example/s", favicon: "", active: true },
        { name: "Beta", hostname: "http://b.example/edge", favicon: "", active: true,
          uuid: "1ee96040-bfb6-4209-9ab8-14a26ff73ad0" },
        { name: "Gamma", hostname: "http://g.example/s", favicon: "", active: true }])

    // What the popup writes when a heal moves a station: new hostname, the
    // old one kept as prev.
    function moved(json, from, to) {
        var list = JSON.parse(json)
        for (var i = 0; i < list.length; i++)
            if (list[i].hostname === from) { list[i].hostname = to; list[i].prev = from }
        return JSON.stringify(list)
    }
    function hosts(page) {
        return page.getServersArray().map(function(s) { return s.name + "@" + s.hostname }).join(",")
    }

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
    function i18np(one, many, n) {
        return (n === 1 ? one : many).replace("%1", n)
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

    function test_a_station_removed_here_stays_removed_when_the_popup_writes() {
        // Measured on the page (2026-11-02): with Beta removed here and Apply
        // not yet pressed, any write from the popup (a logo, a door, an
        // identity) brought Beta back, and Apply saved it.
        var page = open(three)
        page.view.model.remove(1)
        page._edited()
        plasmoid.configuration.servers = withLogo(three, "http://a.example/s", "https://a.example/l.png")
        compare(names(page), "Alpha+logo,Gamma")
        page.destroy()
    }

    function test_a_station_the_popup_moved_keeps_its_place() {
        var page = open(three)
        page.view.model.setProperty(2, "active", false)
        page._edited()
        plasmoid.configuration.servers = moved(three, "http://b.example/edge", "http://b.example/router")
        compare(hosts(page), "Alpha@http://a.example/s,Beta@http://b.example/router,Gamma@http://g.example/s")
        page.destroy()
    }

    function test_a_move_of_a_station_edited_here_is_no_second_row() {
        var page = open(three)
        page.view.model.setProperty(1, "name", "Beta Mine")
        page._edited()
        plasmoid.configuration.servers = moved(three, "http://b.example/edge", "http://b.example/router")
        // The rename stays and the heal's move lands on it: kept on the old
        // address, the popup's next load lost the station's favorite.
        compare(hosts(page), "Alpha@http://a.example/s,Beta Mine@http://b.example/router,Gamma@http://g.example/s")
        compare(page.getServersArray()[1].prev, "http://b.example/edge")
        page.destroy()
    }

    function test_a_move_of_a_station_removed_here_does_not_bring_it_back() {
        var page = open(three)
        page.view.model.remove(1)
        page._edited()
        plasmoid.configuration.servers = moved(three, "http://b.example/edge", "http://b.example/router")
        compare(hosts(page), "Alpha@http://a.example/s,Gamma@http://g.example/s")
        page.destroy()
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

    // ── Import ───────────────────────────────────────────────────────────
    // The page reads the picked file through its shell and takes the answer
    // from the shell's exited signal; the test gives that answer itself.
    function shell(page) {
        var kids = page.contentData
        for (var i = 0; i < kids.length; i++)
            if (kids[i] && kids[i].exited !== undefined && kids[i].exec !== undefined) return kids[i]
        return null
    }
    function importFile(page, text) {
        var sh = shell(page)
        verify(sh !== null, "the page has no shell to read a file through")
        sh.exited("head -c 2097152 '/home/me/stations.arp'", 0, 0, text, "")
    }
    // The line under the list that says how the import went.
    function notice(page) {
        var todo = [page.footer]
        while (todo.length) {
            var it = todo.shift()
            if (it.positive !== undefined && it.showCloseButton !== undefined) return it
            var kids = it.children || []
            for (var i = 0; i < kids.length; i++) todo.push(kids[i])
        }
        return null
    }

    function test_a_file_with_no_station_in_it_leaves_the_list_as_it_was() {
        // Seen on the page with Alpha, Beta and Gamma in the list: each of
        // these emptied it or left half of it, three of them said the
        // configuration had been loaded, and the next Apply saved the loss.
        var files = [
            ["{}", "an object"],
            [JSON.stringify({ "stations": JSON.parse(three) }), "a list wrapped in an object"],
            ["[]", "an empty list"],
            ["\"http://a.example/s\"", "a JSON string"],
            [JSON.stringify([{ "title": "Jazz", "url": "http://j.example/s" }, { "id": 7 }]),
             "another program's list"],
            ["[null, null]", "a list of nothing"],
            ["#EXTM3U\nhttp://a.example/s\n", "a playlist"],
            ["", "an empty file"]
        ]
        var saves = [saveCfgFirst, savePageFirst]
        for (var f = 0; f < files.length; f++) {
            var page = open(three)
            importFile(page, files[f][0])
            compare(hosts(page), "Alpha@http://a.example/s,Beta@http://b.example/edge,Gamma@http://g.example/s",
                    files[f][1] + " changed the list")
            compare(dirty, 0, files[f][1] + " read as an edit")
            var said = notice(page)
            verify(said !== null, "the page has no line to say how the import went")
            compare(said.positive, false, files[f][1] + " was reported as loaded")
            compare(said.text, "Error loading configuration. Try choosing a different file.")
            // And the next edit saves the whole list, not what was left of it.
            page.view.model.setProperty(0, "active", false)
            page._edited()
            saves[f % 2](page)
            compare(JSON.parse(plasmoid.configuration.servers).length, 3, files[f][1] + ": the save lost stations")
            page.destroy()
        }
    }

    function test_a_file_with_a_broken_row_brings_in_the_rest() {
        var page = open(two)
        importFile(page, JSON.stringify([
            { name: "Delta", hostname: "http://d.example/s", favicon: "", active: true },
            null,
            { name: "No address" },
            { name: "Epsilon", hostname: "http://e.example/s", favicon: "", active: false }]))
        compare(hosts(page), "Delta@http://d.example/s,Epsilon@http://e.example/s")
        compare(notice(page).positive, true)
        // A backup that is partly broken looks whole in a list of hundreds.
        // The line says how many rows did not make it.
        compare(notice(page).text,
                "Configuration has been loaded, but 2 rows of the file were left out. Click 'Apply' to save changes.")
        verify(dirty > 0, "an import went unannounced")
        page.destroy()
    }

    function test_the_import_line_counts_one_row_as_one_and_none_as_none() {
        var page = open(two)
        importFile(page, JSON.stringify([
            { name: "Delta", hostname: "http://d.example/s", favicon: "", active: true }, null]))
        compare(notice(page).text,
                "Configuration has been loaded, but one row of the file was left out. Click 'Apply' to save changes.")
        importFile(page, JSON.stringify([
            { name: "Delta", hostname: "http://d.example/s", favicon: "", active: true }]))
        compare(notice(page).text, "Configuration has been loaded. Click 'Apply' to save changes.")
        page.destroy()
    }

    function test_the_pages_own_export_comes_back_as_it_left() {
        // Read on the page: {"codec":"flac","bitrate":900} was gone after an
        // export and an import, and with the codec the relay an Ogg stream
        // needs to play past its first second.
        var list = JSON.stringify([
            { name: "Alpha", hostname: "http://a.example/s", favicon: "https://a.example/l.png", active: true,
              country: "Estonia" },
            { name: "Mast FLAC", hostname: "https://f.example/flac", favicon: "", active: false,
              codec: "flac", bitrate: 900, uuid: "1ee96040-bfb6-4209-9ab8-14a26ff73ad0",
              prev: "https://old.example/flac" },
            { name: "Gamma", hostname: "http://g.example/s", favicon: "", active: true }])
        var saves = [saveCfgFirst, savePageFirst]
        for (var k = 0; k < saves.length; k++) {
            var page = open(list)
            // What Export writes is the list the page holds.
            var exported = JSON.stringify(page.getServersArray())
            page.destroy()
            page = open(two)
            importFile(page, exported)
            compare(JSON.stringify(page.getServersArray()), exported, "shell " + k)
            compare(notice(page).positive, true)
            verify(dirty > 0, "shell " + k + ": an import went unannounced")
            saves[k](page)
            var saved = JSON.parse(plasmoid.configuration.servers)
            compare(saved.length, 3)
            compare(saved[1].codec, "flac", "shell " + k + " lost the codec")
            compare(saved[1].bitrate, 900, "shell " + k + " lost the bitrate")
            page.destroy()
        }
    }

    // ── Fetch missing logos ──────────────────────────────────────────────
    // What the run does with each picture it finds, without the network:
    // _saveLogo is where a find lands on the page.
    function found(page, row, logo) {
        var it = page.view.model.get(row)
        return page._saveLogo({ index: row, name: it.name, hostname: it.hostname }, logo)
    }

    function test_a_logo_found_here_outlives_what_the_popup_writes_meanwhile() {
        // Seen on the page: a run gave Alpha its logo, the popup wrote the
        // list before the run ended, and Alpha's logo was gone while the
        // run's last line still counted it as updated. The find was on the
        // page but not in what the page calls its own edits, so the popup's
        // list was taken over whole.
        var popupWrites = [
            [withLogo(three, "http://g.example/s", "https://g.example/l.png"), "Alpha+logo,Beta,Gamma+logo",
             "the popup found Gamma's logo"],
            [moved(three, "http://b.example/edge", "http://b.example/new"), "Alpha+logo,Beta,Gamma",
             "a heal moved Beta"],
            [JSON.stringify(JSON.parse(three).concat([{ name: "Delta", hostname: "http://d.example/s",
                                                        favicon: "", active: true }])),
             "Alpha+logo,Beta,Gamma,Delta", "a station was added from a search"]
        ]
        var saves = [saveCfgFirst, savePageFirst]
        for (var w = 0; w < popupWrites.length; w++) {
            var page = open(three)
            verify(found(page, 0, "https://a.example/l.png"), "the page refused a logo for its own row")
            plasmoid.configuration.servers = popupWrites[w][0]
            compare(names(page), popupWrites[w][1], popupWrites[w][2])
            compare(page._logoFound, 1)
            // And Apply saves what the page shows.
            saves[w % 2](page)
            var saved = JSON.parse(plasmoid.configuration.servers)
            compare(saved[0].favicon, "https://a.example/l.png", popupWrites[w][2] + ": the save lost the logo")
            compare(saved.length, JSON.parse(popupWrites[w][0]).length, popupWrites[w][2])
            page.destroy()
        }
    }

    function test_a_move_the_popup_made_during_a_run_is_kept_with_the_logo() {
        var page = open(three)
        verify(found(page, 1, "https://b.example/l.png"))
        plasmoid.configuration.servers = moved(three, "http://b.example/edge", "http://b.example/new")
        var rows = page.getServersArray()
        compare(rows[1].hostname, "http://b.example/new", "the page kept the address the heal left")
        compare(rows[1].favicon, "https://b.example/l.png")
        compare(rows[1].prev, "http://b.example/edge")
        page.destroy()
    }

    function test_a_logo_found_lights_apply_at_once() {
        var page = open(three)
        compare(dirty, 0)
        verify(found(page, 0, "https://a.example/l.png"))
        verify(dirty > 0, "a found logo is an edit, and the page did not say so")
        var after = dirty
        verify(found(page, 2, "https://g.example/l.png"))
        verify(dirty > after, "the second find went unannounced")
        compare(names(page), "Alpha+logo,Beta,Gamma+logo")
        page.destroy()
    }

    function test_a_find_the_page_refuses_is_no_edit() {
        var page = open(three)
        compare(page._saveLogo({ index: 0, name: "Alpha" }, ""), false, "no address")
        compare(page._saveLogo({ index: 3, name: "Alpha" }, "https://a.example/l.png"), false, "a row past the end")
        compare(page._saveLogo({ index: 0, name: "Alpha" }, "http://192.168.1.1/l.png"), false,
                "a logo on the listener's own network")
        // The row the job was made for is somewhere else by now.
        compare(page._saveLogo({ index: 0, name: "Beta" }, "https://b.example/l.png"), false, "another station's row")
        compare(names(page), "Alpha,Beta,Gamma")
        compare(dirty, 0, "a refused find read as an edit")
        compare(page._logoFound, 0)
        // So the page still follows the popup quietly.
        var popup = withLogo(three, "http://g.example/s", "https://g.example/l.png")
        plasmoid.configuration.servers = popup
        compare(names(page), "Alpha,Beta,Gamma+logo")
        compare(dirty, 0)
        page.destroy()
    }
}
