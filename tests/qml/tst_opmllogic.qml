// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// OPML round-trip and hostile-import parsing.
import QtQuick
import QtTest

import "../../package/contents/ui/OpmlLogic.js" as OPML

TestCase {
    name: "OpmlLogic"

    function test_build_escapes_xml_and_skips_folders() {
        var xml = OPML.buildOpml([
            { title: "R&B <Live> \"Show\"", feedUrl: "https://a.com/feed?x=1&y=2" },
            { title: "No URL folder", feedUrl: "" },
            { title: "Plain", feedUrl: "https://b.org/f" }
        ])
        // Special chars escaped in attributes — never raw & < > " in output.
        verify(xml.indexOf("R&amp;B &lt;Live&gt; &quot;Show&quot;") !== -1)
        verify(xml.indexOf("x=1&amp;y=2") !== -1)
        // The folder (no feedUrl) is skipped; two real subs remain.
        compare((xml.match(/<outline\b/g) || []).length, 2)
        verify(xml.indexOf('version="2.0"') !== -1)
    }

    function test_round_trips() {
        var subs = [
            { title: "One", feedUrl: "https://a.com/1" },
            { title: "Two & Co", feedUrl: "https://b.com/2" }
        ]
        var parsed = OPML.parseOpml(OPML.buildOpml(subs))
        compare(parsed.length, 2)
        compare(parsed[0].title, "One")
        compare(parsed[0].feedUrl, "https://a.com/1")
        compare(parsed[1].title, "Two & Co")     // entity decoded back
        compare(parsed[1].feedUrl, "https://b.com/2")
    }

    function test_parse_flattens_folders_and_dedupes() {
        var xml = '<opml><body>'
            + '<outline text="Folder">'
            + '  <outline text="A" xmlUrl="https://a/1"/>'
            + '  <outline text="A dup" xmlUrl="https://a/1"/>'   // dup URL
            + '  <outline text="B" type="rss" xmlUrl="https://b/2"/>'
            + '</outline>'
            + '<outline text="NoUrlFolder"/>'                    // no xmlUrl -> skip
            + '</body></opml>'
        var p = OPML.parseOpml(xml)
        compare(p.length, 2)
        compare(p[0].feedUrl, "https://a/1")
        compare(p[1].feedUrl, "https://b/2")
    }

    function test_title_falls_back_to_text_then_url() {
        var p = OPML.parseOpml('<outline xmlUrl="https://a/1"/>'
            + '<outline text="T" xmlUrl="https://a/2"/>')
        compare(p[0].title, "https://a/1")   // no title/text -> url
        compare(p[1].title, "T")             // text used as title
    }

    function test_not_opml_returns_empty_never_throws() {
        compare(OPML.parseOpml("<html><body>404</body></html>").length, 0)
        compare(OPML.parseOpml("").length, 0)
        compare(OPML.parseOpml("not xml at all").length, 0)
        compare(OPML.parseOpml(null).length, 0)
    }

    function test_single_quoted_attributes_parse() {
        var p = OPML.parseOpml("<outline text='Q' xmlUrl='https://a/q'/>")
        compare(p.length, 1)
        compare(p[0].title, "Q")
        compare(p[0].feedUrl, "https://a/q")
    }
}
