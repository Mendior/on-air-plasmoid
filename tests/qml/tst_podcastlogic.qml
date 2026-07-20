// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// The podcast feed parser against the wild: CDATA soup, entity salad,
// hostile enclosure URLs, three duration spellings and filenames that
// try to be shell commands. A feed is untrusted input end to end.
import QtQuick
import QtTest

import "../../package/contents/ui/PodcastLogic.js" as PL

TestCase {
    name: "PodcastLogic"

    readonly property string realisticFeed: '<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel>
  <title><![CDATA[Ajalugu &amp; T&#228;na]]></title>
  <item>
    <title><![CDATA[Episode 12 — R&amp;D lugu]]></title>
    <guid isPermaLink="false">ep-12-guid</guid>
    <pubDate>Mon, 13 Jul 2026 06:00:00 GMT</pubDate>
    <itunes:duration>1:02:03</itunes:duration>
    <enclosure type="audio/mpeg" length="55123456" url="https://cdn.example.com/ep12.mp3?tk=1"/>
  </item>
  <item>
    <title>Plain title</title>
    <enclosure url=\'https://cdn.example.com/ep11.m4a\' type=\'audio/x-m4a\' length=\'1\'/>
    <itunes:duration>62:03</itunes:duration>
  </item>
  <item>
    <title>Video bonus — must be skipped</title>
    <enclosure url="https://cdn.example.com/bonus.mp4" type="video/mp4"/>
  </item>
  <item>
    <title>LAN honeypot — must be skipped</title>
    <enclosure url="http://192.168.1.10/steal.mp3" type="audio/mpeg"/>
  </item>
  <item>
    <title>No enclosure — not an episode</title>
  </item>
  <item>
    <duration>45</duration>
    <enclosure url="https://cdn.example.com/untitled.ogg" type="audio/ogg"/>
  </item>
</channel>
</rss>'

    function test_realistic_feed_parses_the_survivors() {
        var f = PL.parseFeed(realisticFeed, 50)
        verify(f.ok)
        compare(f.title, "Ajalugu & Täna")
        compare(f.episodes.length, 3)

        compare(f.episodes[0].title, "Episode 12 — R&D lugu")
        compare(f.episodes[0].guid, "ep-12-guid")
        compare(f.episodes[0].url, "https://cdn.example.com/ep12.mp3?tk=1")
        compare(f.episodes[0].durationSec, 3723)
        compare(f.episodes[0].sizeBytes, 55123456)
        verify(f.episodes[0].pubMs > 0)

        // Single-quoted attributes in any order parse the same.
        compare(f.episodes[1].url, "https://cdn.example.com/ep11.m4a")
        compare(f.episodes[1].durationSec, 3723)

        // Untitled episode: title stays "" (the delegate names it), guid
        // falls back to the enclosure URL, namespaceless duration matches.
        compare(f.episodes[2].title, "")
        compare(f.episodes[2].guid, "https://cdn.example.com/untitled.ogg")
        compare(f.episodes[2].durationSec, 45)
    }

    function test_the_channel_title_cannot_be_shadowed_by_an_episode() {
        var f = PL.parseFeed('<rss><channel><item><title>EP</title>'
            + '<enclosure url="https://x.example/a.mp3"/></item>'
            + '<title>Late Channel</title></channel></rss>', 10)
        // Title taken from before the first item only — here there is none.
        compare(f.title, "")
        compare(f.episodes[0].title, "EP")
    }

    function test_not_a_feed_says_so() {
        verify(!PL.parseFeed("<html><body><h1>404</h1></body></html>", 10).ok)
        verify(!PL.parseFeed('{"error": "nope"}', 10).ok)
        verify(!PL.parseFeed("", 10).ok)
        // A real but empty feed IS a feed — the UI says "no episodes",
        // not "this is not a podcast".
        verify(PL.parseFeed("<rss><channel><title>T</title></channel></rss>", 10).ok)
    }

    function test_the_item_cap_holds() {
        var xml = "<rss><channel>"
        for (var i = 0; i < 80; i++)
            xml += '<item><title>E' + i + '</title>'
                 + '<enclosure url="https://x.example/' + i + '.mp3"/></item>'
        xml += "</channel></rss>"
        compare(PL.parseFeed(xml, 50).episodes.length, 50)
    }

    function test_duration_wears_three_coats() {
        compare(PL.parseDuration("45"), 45)
        compare(PL.parseDuration("62:03"), 3723)
        compare(PL.parseDuration("1:02:03"), 3723)
        compare(PL.parseDuration("00:00"), 0)
        compare(PL.parseDuration(""), -1)
        compare(PL.parseDuration("about an hour"), -1)
        compare(PL.parseDuration("1:2:3:4"), -1)
    }

    function test_entities_decode_once_and_only_once() {
        compare(PL.decodeEntities("R&amp;B &lt;live&gt; &#x2013; &#228;"), "R&B <live> – ä")
        // Double-encoded text must NOT over-decode: &amp;lt; is the TEXT
        // "&lt;", not a "<".
        compare(PL.decodeEntities("&amp;lt;script&amp;gt;"), "&lt;script&gt;")
        compare(PL.decodeEntities("&#0;&#xFFFFFFFF;x"), "x")
    }

    function test_filenames_cannot_leave_the_folder_or_talk_to_the_shell() {
        compare(PL.safeFileName("../../etc/passwd", "ep"), "etc passwd")
        compare(PL.safeFileName("rm -rf `$(x)` '\"| ;", "ep"), "rm -rf (x) ;")
        compare(PL.safeFileName(".hidden", "ep"), "hidden")
        compare(PL.safeFileName("   ", "ep"), "ep")
        compare(PL.safeFileName("", ""), "episode")
        verify(PL.safeFileName(new Array(40).join("pikk pealkiri "), "ep").length <= 120)
    }

    function test_extension_is_whitelisted() {
        compare(PL.fileExt("https://x/e.MP3?a=1"), "mp3")
        compare(PL.fileExt("https://x/e.opus"), "opus")
        compare(PL.fileExt("https://x/e.php?f=x.exe"), "mp3")
        compare(PL.fileExt("https://x/audio"), "mp3")
    }

    function test_url_gate_refuses_every_wrong_road() {
        verify(PL.urlAllowed("https://feeds.example.com/show.rss"))
        verify(PL.urlAllowed("http://cdn.example.com/e.mp3"))
        verify(!PL.urlAllowed("ftp://example.com/e.mp3"))
        verify(!PL.urlAllowed("file:///etc/passwd"))
        verify(!PL.urlAllowed("http://127.0.0.1/e.mp3"))
        verify(!PL.urlAllowed("http://[::ffff:10.0.0.5]/e.mp3"))
        verify(!PL.urlAllowed("http://2130706433/e.mp3"))
        verify(!PL.urlAllowed(""))
    }

    function test_positions_prune_keeps_the_newest() {
        var map = {}
        for (var i = 0; i < 10; i++)
            map["k" + i] = { sec: i, dur: 100, at: i }
        var out = PL.prunePositions(map, 3)
        compare(Object.keys(out).length, 3)
        verify(out.k9 !== undefined)
        verify(out.k7 !== undefined)
        verify(out.k0 === undefined)
        // Under the cap nothing is touched.
        compare(Object.keys(PL.prunePositions(map, 50)).length, 10)
    }

    function test_episode_key_prefers_the_guid() {
        compare(PL.episodeKey("g1", "u1"), "g1")
        compare(PL.episodeKey("", "u1"), "u1")
    }

    function test_the_clock_reads_like_a_clock() {
        compare(PL.fmtTime(5), "0:05")
        compare(PL.fmtTime(65), "1:05")
        compare(PL.fmtTime(3723), "1:02:03")
        compare(PL.fmtTime(-3), "0:00")
    }
}
