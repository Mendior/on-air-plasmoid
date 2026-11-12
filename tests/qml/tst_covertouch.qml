// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// What lies over the cover on the Playing page: the menu with the artist's
// links and the click that shows the picture larger. That both are reached
// with the keyboard, that a link leads to the artist the menu was opened
// for, and that nothing is opened or fetched unasked.
import QtQuick
import QtTest
import org.kde.kirigami as Kirigami

import "../../package/contents/ui"

FocusScope {
    id: root
    width: 420
    height: 420
    focus: true

    // What CircleButton reads off the widget's root.
    property color accent: "#3BEE96"
    property color accentTextOn: "#000000"

    function i18n(s) { return s; }
    function i18nc(context, s) { return s; }

    // Every address the cover asked to have opened. Nothing here opens one.
    property var opened: []
    // Escapes that got past the cover to the page behind it.
    property int escapes: 0
    Keys.onEscapePressed: escapes++
    // The page's own Space, its play and pause: every one that reached it.
    property int spaces: 0
    Keys.onSpacePressed: spaces++

    // Where the focus rests between two tests, one Tab before the cover.
    Item {
        id: rest
        activeFocusOnTab: true
    }

    Item {
        id: cover
        x: 110
        y: 110
        width: 200
        height: 200

        CoverTouch {
            id: touch
            anchors.fill: parent
            face: root
            open: function(address) { root.opened = root.opened.concat([address]); }
        }
    }

    // A second cover on a face that is a plain item and no focus scope.
    Item {
        id: plainFace
        width: 300
        height: 300
        property int spaces: 0
        Keys.onSpacePressed: spaces++

        CoverTouch {
            id: plain
            width: 100
            height: 100
            face: plainFace
            visible: false
            open: function(address) {}
        }
    }

    // A cover nobody tells anything.
    CoverTouch {
        id: touchOfItsOwn
        visible: false
    }

    // A picture read the way the page reads its cover, for its own size.
    Image {
        id: read
        visible: false
        sourceSize.width: 600
        sourceSize.height: 600
    }

    // And one stop after it.
    Item {
        id: after
        activeFocusOnTab: true
    }

    TestCase {
        name: "CoverTouch"
        when: windowShown

        readonly property string lastfm: "https://www.last.fm/search/artists?q="
        readonly property string discogs: "https://www.discogs.com/search/?type=artist&q="
        readonly property string picture: Qt.resolvedUrl("../../package/contents/icons/on-air.svg").toString()

        function init() {
            rest.forceActiveFocus();
            touch.heldArtist = "";
            touch.larger = false;
            touch.trackArtist = "";
            touch.station = "";
            touch.art = "";
            touch.natural = Qt.size(600, 600);
            touch.ratio = 1;
            touch.kind = "";
            touch.corner = 0;
            root.opened = [];
            root.escapes = 0;
            root.spaces = 0;
            rest.visible = true;
            rest.enabled = true;
            plain.visible = false;
            plain.art = "";
            plainFace.spaces = 0;
        }

        function press(item) { mouseClick(item, item.width / 2, item.height / 2); }

        function test_no_artist_no_menu() {
            verify(!touch._linksButton.visible);
            touch.openLinks();
            verify(!touch.linksOpen);
            // Nor is the focus sent after a menu that did not open.
            verify(rest.activeFocus);
            mouseClick(touch, 100, 100, Qt.RightButton);
            verify(!touch.linksOpen);
            keyClick(Qt.Key_Tab);
            // No picture and no artist: nothing over the cover takes the focus.
            verify(after.activeFocus);
            compare(root.opened, []);
        }

        function test_a_station_saying_its_own_name_gets_no_menu() {
            touch.station = "Kiss FM";
            touch.trackArtist = "Kiss FM";
            verify(!touch._linksButton.visible);
            touch.openLinks();
            verify(!touch.linksOpen);
            touch.trackArtist = "Björk";
            verify(touch._linksButton.visible);
            touch.station = "";
        }

        function test_the_menu_opens_on_its_button_and_names_the_artist() {
            touch.trackArtist = "Björk";
            verify(touch._linksButton.visible);
            verify(!touch._linksPanel.visible);
            press(touch._linksButton);
            verify(touch.linksOpen);
            verify(touch._linksPanel.visible);
            compare(touch._heldLabel.text, "Björk");
            // Opening it has asked for nothing.
            compare(root.opened, []);
            press(touch._linksButton);
            verify(!touch.linksOpen);
            compare(root.opened, []);
        }

        function test_an_entry_opens_one_address_and_shuts_the_menu() {
            touch.trackArtist = "Earth, Wind & Fire";
            press(touch._linksButton);
            press(touch._lastfmEntry);
            compare(root.opened, [lastfm + "Earth%2C%20Wind%20%26%20Fire"]);
            verify(!touch.linksOpen);
            press(touch._linksButton);
            press(touch._discogsEntry);
            compare(root.opened, [lastfm + "Earth%2C%20Wind%20%26%20Fire", discogs + "Earth%2C%20Wind%20%26%20Fire"]);
            verify(!touch.linksOpen);
        }

        function test_the_keyboard_reaches_the_menu_and_both_entries() {
            touch.trackArtist = "AC/DC";
            keyClick(Qt.Key_Tab);
            verify(touch._linksButton.activeFocus);
            keyClick(Qt.Key_Return);
            verify(touch.linksOpen);
            verify(touch._lastfmEntry.activeFocus);
            keyClick(Qt.Key_Down);
            verify(touch._discogsEntry.activeFocus);
            keyClick(Qt.Key_Down);
            verify(touch._lastfmEntry.activeFocus);
            keyClick(Qt.Key_Up);
            verify(touch._discogsEntry.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.opened, [discogs + "AC%2FDC"]);
            verify(!touch.linksOpen);
            // The focus is back where the menu was opened from.
            verify(touch._linksButton.activeFocus);
        }

        function test_tab_walks_through_the_entries_and_on() {
            touch.trackArtist = "AC/DC";
            keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_Space);
            verify(touch._lastfmEntry.activeFocus);
            keyClick(Qt.Key_Tab);
            verify(touch._discogsEntry.activeFocus);
            keyClick(Qt.Key_Tab);
            // Past the last entry the menu shuts and the focus goes on.
            verify(after.activeFocus);
            verify(!touch.linksOpen);
            compare(root.opened, []);
        }

        function test_the_next_song_does_not_move_an_open_menu() {
            touch.trackArtist = "Björk";
            press(touch._linksButton);
            touch.trackArtist = "Sigur Rós";
            compare(touch._heldLabel.text, "Björk");
            press(touch._lastfmEntry);
            compare(root.opened, [lastfm + "Bj%C3%B6rk"]);
            // Opened again, it is about who plays now.
            press(touch._linksButton);
            compare(touch._heldLabel.text, "Sigur Rós");
            press(touch._discogsEntry);
            compare(root.opened[1], discogs + "Sigur%20R%C3%B3s");
        }

        function test_an_open_menu_outlives_its_artist() {
            touch.trackArtist = "Björk";
            press(touch._linksButton);
            // An advert follows the song: no artist any more.
            touch.trackArtist = "";
            verify(touch.linksOpen);
            verify(touch._linksButton.visible);
            press(touch._discogsEntry);
            compare(root.opened, [discogs + "Bj%C3%B6rk"]);
            verify(!touch._linksButton.visible);
        }

        function test_escape_shuts_the_menu_and_goes_no_further() {
            touch.trackArtist = "Björk";
            keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Escape);
            verify(!touch.linksOpen);
            verify(touch._linksButton.activeFocus);
            compare(root.escapes, 0);
            compare(root.opened, []);
        }

        function test_a_click_beside_the_open_menu_only_shuts_it() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            press(touch._linksButton);
            mouseClick(touch, 20, 180);
            verify(!touch.linksOpen);
            verify(!touch.larger);
            compare(root.opened, []);
        }

        function test_the_right_button_and_the_menu_key_open_the_menu_too() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            mouseClick(touch, 100, 150, Qt.RightButton);
            verify(touch.linksOpen);
            verify(!touch.larger);
            touch.closeLinks();
            rest.forceActiveFocus();
            keyClick(Qt.Key_Tab);
            verify(touch._coverButton.activeFocus);
            keyClick(Qt.Key_Menu);
            verify(touch.linksOpen);
            compare(touch._heldLabel.text, "Björk");
        }

        function test_a_click_on_the_cover_shows_it_larger_and_a_click_puts_it_back() {
            touch.art = picture;
            verify(!touch._largerView.visible);
            mouseClick(touch, 100, 100);
            verify(touch.larger);
            verify(touch._largerView.visible);
            // The whole face, not the cover's corner of it.
            compare(touch._largerView.width, root.width);
            compare(touch._largerView.height, root.height);
            compare(touch._largerImage.source.toString(), picture);
            mouseClick(root, 5, 5);
            verify(!touch.larger);
            verify(!touch._largerView.visible);
            compare(touch._largerImage.source.toString(), "");
            compare(root.opened, []);
        }

        function test_without_a_picture_there_is_nothing_to_show_larger() {
            mouseClick(touch, 100, 100);
            verify(!touch.larger);
            touch.showLarger();
            verify(!touch.larger);
            keyClick(Qt.Key_Tab);
            verify(after.activeFocus);
        }

        function test_the_keyboard_shows_the_cover_larger_and_escape_puts_it_back() {
            touch.art = picture;
            keyClick(Qt.Key_Tab);
            verify(touch._coverButton.activeFocus);
            keyClick(Qt.Key_Return);
            verify(touch.larger);
            verify(touch._largerView.activeFocus);
            // Tab does not walk off to the page behind the picture.
            keyClick(Qt.Key_Tab);
            verify(touch._largerView.activeFocus);
            keyClick(Qt.Key_Backtab);
            verify(touch._largerView.activeFocus);
            keyClick(Qt.Key_Escape);
            verify(!touch.larger);
            verify(touch._coverButton.activeFocus);
            // The page behind did not hear the Escape: it would have left for the station list.
            compare(root.escapes, 0);
            keyClick(Qt.Key_Space);
            verify(touch.larger);
            keyClick(Qt.Key_Space);
            verify(!touch.larger);
            keyClick(Qt.Key_Enter);
            verify(touch.larger);
            keyClick(Qt.Key_Enter);
            verify(!touch.larger);
        }

        function test_the_larger_picture_follows_the_cover_and_goes_with_it() {
            touch.art = picture;
            touch.showLarger();
            var next = picture + "-2";
            touch.art = next;
            verify(touch.larger);
            compare(touch._largerImage.source.toString(), next);
            touch.art = "";
            verify(!touch.larger);
            compare(touch._largerImage.source.toString(), "");
        }

        // A wide picture: the frame takes its shape, fills the face's width
        // and shows all of it.
        function test_the_larger_picture_is_whole_and_fills_what_the_face_has() {
            read.source = Qt.resolvedUrl("../../screenshots/playing.png");
            tryCompare(read, "status", Image.Ready, 10000);
            touch.natural = Qt.size(read.implicitWidth, read.implicitHeight);
            touch.art = read.source.toString();
            touch.showLarger();
            var img = touch._largerImage;
            tryCompare(img, "status", Image.Ready, 10000);
            verify(img.natural.width !== img.natural.height, "the test wants a picture that is not square");
            // The very picture the page read: the same pixels, not enlarged on the way in.
            compare(img.natural.width, read.implicitWidth);
            compare(img.natural.height, read.implicitHeight);
            fuzzyCompare(img.width / img.height, img.natural.width / img.natural.height, 0.01);
            verify(img.width <= root.width && img.height <= root.height);
            // A margin of one large spacing all round, and the picture up to it.
            fuzzyCompare(Math.max(img.width, img.height), root.width - Kirigami.Units.largeSpacing * 2, 0.5);
            fuzzyCompare(img.x + img.width / 2, root.width / 2, 0.5);
            fuzzyCompare(img.y + img.height / 2, root.height / 2, 0.5);
            // What is painted is what the frame holds: nothing hangs over.
            fuzzyCompare(img._image.paintedWidth, img.width, 1);
            fuzzyCompare(img._image.paintedHeight, img.height, 1);
        }

        // A picture that is not the cover of the song on air says what it
        // is, on the cover and in the larger view, and to a screen reader.
        function test_a_stand_in_says_what_it_is_data() {
            return [
                { tag: "artist", kind: "artist", says: "Artist picture" },
                { tag: "release", kind: "release", says: "From another release" }
            ];
        }
        function test_a_stand_in_says_what_it_is(data) {
            touch.art = picture;
            touch.kind = data.kind;
            verify(touch._coverNote.visible);
            compare(touch._coverNote.text, data.says);
            compare(touch._coverButton.Accessible.description, data.says);
            // It lies on the cover's lower edge, inside the cover.
            var at = touch._coverNote.mapToItem(touch, 0, 0);
            verify(at.x >= 0 && at.x + touch._coverNote.width <= touch.width);
            verify(at.y + touch._coverNote.height <= touch.height && at.y > touch.height / 2);
            touch.showLarger();
            verify(touch._largerNote.visible);
            compare(touch._largerNote.text, data.says);
            compare(touch._largerView.Accessible.description, data.says);
            tryCompare(touch._largerImage, "status", Image.Ready, 10000);
            // On the larger picture itself, not on the dimmed page around it.
            var img = touch._largerImage, on = touch._largerNote.mapToItem(img, 0, 0);
            verify(on.x >= 0 && on.x + touch._largerNote.width <= img.width);
            verify(on.y >= 0 && on.y + touch._largerNote.height <= img.height + 0.5);
        }

        function test_the_songs_own_cover_and_a_logo_say_nothing_data() {
            return [
                { tag: "the song's cover", kind: "track" },
                { tag: "a logo or an episode's cover", kind: "" },
                { tag: "a word that is no kind", kind: "cover" },
                { tag: "the right word in capitals", kind: "ARTIST" }
            ];
        }
        function test_the_songs_own_cover_and_a_logo_say_nothing(data) {
            touch.art = picture;
            touch.kind = data.kind;
            compare(touch.note, "");
            verify(!touch._coverNote.visible);
            compare(touch._coverButton.Accessible.description, "");
            touch.showLarger();
            verify(!touch._largerNote.visible);
            compare(touch._largerView.Accessible.description, "");
        }

        // The line belongs to a picture. While the page shows none, the
        // record turns there and nothing claims to be a picture of anyone.
        function test_no_picture_no_line() {
            touch.kind = "artist";
            compare(touch.note, "");
            verify(!touch._coverNote.visible);
            touch.art = picture;
            verify(touch._coverNote.visible);
            touch.art = "";
            verify(!touch._coverNote.visible);
        }

        // The next song's picture brings its own line, also into a larger
        // view that is open, and the song's own cover takes the line away.
        function test_the_line_follows_the_picture() {
            touch.art = picture;
            touch.kind = "release";
            touch.showLarger();
            compare(touch._largerNote.text, "From another release");
            touch.art = picture + "-2";
            touch.kind = "artist";
            compare(touch._largerNote.text, "Artist picture");
            compare(touch._coverNote.text, "Artist picture");
            touch.kind = "track";
            verify(!touch._largerNote.visible);
            verify(!touch._coverNote.visible);
        }

        // The page keeps the cover's lower right corner for its level bars.
        function test_the_line_stays_clear_of_the_pages_corner() {
            touch.art = picture;
            touch.kind = "release";
            var free = touch._coverNote.width;
            touch.corner = 120;
            var at = touch._coverNote.mapToItem(touch, 0, 0);
            verify(at.x + touch._coverNote.width <= touch.width - 120, "the line reaches into the corner");
            verify(touch._coverNote.width < free, "the corner took nothing from the line");
            verify(touch._coverNote.visible);
        }

        // The line is no button: a click on it is a click on the cover.
        function test_a_click_on_the_line_is_a_click_on_the_cover() {
            touch.art = picture;
            touch.kind = "artist";
            touch.trackArtist = "Star Sisters";
            var at = touch._coverNote.mapToItem(touch, touch._coverNote.width / 2, touch._coverNote.height / 2);
            mouseClick(touch, at.x, at.y);
            verify(touch.larger);
            touch.closeLarger();
            mouseClick(touch, at.x, at.y, Qt.RightButton);
            verify(touch.linksOpen);
        }

        // 2026-11-12: a station's logo of 32 pixels, shown larger, was drawn
        // 600 wide. Twice its own pixels is the most a picture is enlarged
        // to, and on a cover of 200 a view of 64 has nothing to add.
        function test_a_small_logo_is_not_offered_larger() {
            touch.art = picture;
            touch.natural = Qt.size(32, 32);
            verify(!touch.largerOffered);
            // No button for the keyboard or a screen reader, no hand, no click.
            verify(!touch._coverButton.visible);
            compare(touch._coverArea.cursorShape, Qt.ArrowCursor);
            mouseClick(touch, 100, 100);
            verify(!touch.larger);
            touch.showLarger();
            verify(!touch.larger);
            verify(!touch._largerView.visible);
            keyClick(Qt.Key_Tab);
            verify(after.activeFocus);
            // The artist's links are still there, by the button and the right click.
            touch.trackArtist = "Björk";
            mouseClick(touch, 100, 150, Qt.RightButton);
            verify(touch.linksOpen);
        }

        function test_a_picture_is_enlarged_to_twice_its_pixels_at_most_data() {
            return [
                // The cover is 200 a side and the face leaves about 400.
                { tag: "32, a favicon", side: 32, offered: false, shown: 0 },
                { tag: "100, twice is the cover's own size", side: 100, offered: false, shown: 0 },
                { tag: "101, hardly larger than the cover", side: 101, offered: false, shown: 0 },
                { tag: "125, a quarter larger", side: 125, offered: true, shown: 250 },
                { tag: "150", side: 150, offered: true, shown: 300 },
                { tag: "300, the room is the limit", side: 300, offered: true, shown: -1 },
                { tag: "600", side: 600, offered: true, shown: -1 }
            ];
        }
        function test_a_picture_is_enlarged_to_twice_its_pixels_at_most(data) {
            touch.art = picture;
            touch.natural = Qt.size(data.side, data.side);
            compare(touch.largerOffered, data.offered);
            compare(touch._coverButton.visible, data.offered);
            compare(touch._coverArea.cursorShape, data.offered ? Qt.PointingHandCursor : Qt.ArrowCursor);
            mouseClick(touch, 100, 100);
            compare(touch.larger, data.offered);
            if (!data.offered) return;
            var img = touch._largerImage;
            var room = root.width - Kirigami.Units.largeSpacing * 2;
            compare(img.width, data.shown < 0 ? room : data.shown);
            compare(img.height, img.width);
            verify(img.width <= data.side * 2);
            verify(img.width > touch.width, "no larger than the cover it was opened from");
        }

        // The cover is 200 a side and the face leaves 404. On a screen scaled
        // to 175% a picture of 150 may be shown 171 wide, which is twice its
        // pixels there and less than the cover.
        function test_the_limit_counts_the_screens_pixels_data() {
            return [
                { tag: "150 at 1", ratio: 1, side: 150, offered: true, shown: 300 },
                { tag: "150 at 1.75", ratio: 1.75, side: 150, offered: false, shown: 0 },
                { tag: "300 at 1.75", ratio: 1.75, side: 300, offered: true, shown: 342.857 },
                { tag: "300 at 2", ratio: 2, side: 300, offered: true, shown: 300 },
                { tag: "600 at 1.75, the room is the limit", ratio: 1.75, side: 600, offered: true, shown: 404 },
                { tag: "64 at 1.75, a logo", ratio: 1.75, side: 64, offered: false, shown: 0 }
            ];
        }
        function test_the_limit_counts_the_screens_pixels(data) {
            touch.art = picture;
            touch.ratio = data.ratio;
            touch.natural = Qt.size(data.side, data.side);
            compare(touch.largerOffered, data.offered);
            compare(touch._coverButton.visible, data.offered);
            mouseClick(touch, 100, 100);
            compare(touch.larger, data.offered);
            if (data.offered) fuzzyCompare(touch._largerImage.width, data.shown, 0.01);
        }

        // Nobody set the ratio: it is the screen's, and this screen is not scaled.
        function test_the_ratio_is_the_screens_unless_given() {
            compare(touchOfItsOwn.ratio, Screen.devicePixelRatio);
            compare(touchOfItsOwn.ratio, 1);
        }

        // The face keeps a margin on every side, whichever side the picture reaches first.
        function test_the_larger_picture_keeps_a_margin_all_round() {
            var room = root.width - Kirigami.Units.largeSpacing * 2;
            touch.art = picture;
            touch.natural = Qt.size(600, 300);
            touch.showLarger();
            compare(touch._largerImage.width, room);
            compare(touch._largerImage.height, room / 2);
            touch.natural = Qt.size(300, 600);
            compare(touch._largerImage.height, room);
            compare(touch._largerImage.width, room / 2);
        }

        // Before the picture is read nobody knows its size, and nothing is offered.
        function test_a_picture_of_no_known_size_is_not_offered_larger_data() {
            return [
                { tag: "0 by 0", size: Qt.size(0, 0) },
                { tag: "no height", size: Qt.size(300, 0) },
                { tag: "negative", size: Qt.size(-1, -1) }
            ];
        }
        function test_a_picture_of_no_known_size_is_not_offered_larger(data) {
            touch.art = picture;
            touch.natural = data.size;
            verify(!touch.largerOffered);
            mouseClick(touch, 100, 100);
            verify(!touch.larger);
        }

        // The next station's logo is small: the larger view that was open
        // for the song's cover goes instead of blowing the logo up.
        function test_the_larger_view_goes_when_the_next_picture_is_too_small() {
            touch.art = picture;
            touch.showLarger();
            verify(touch.larger);
            touch.art = picture + "-logo";
            touch.natural = Qt.size(32, 32);
            verify(!touch.larger);
            verify(!touch._largerView.visible);
            compare(touch._largerImage.source.toString(), "");
        }

        // ── Where the keyboard is after the mouse was used ──────────────────
        // Measured on the panel, 2026-11-12: after a click on the menu's
        // button and one more to shut it, Space opened the menu again, and
        // the Space after that opened Last.fm in the browser. The listener
        // had pressed it to pause. A click with the mouse puts the keyboard
        // nowhere new: when what it opened shuts, the focus is where it was.
        function test_space_after_the_menu_was_clicked_open_and_shut_is_the_pages() {
            touch.trackArtist = "Björk";
            press(touch._linksButton);
            verify(touch.linksOpen);
            press(touch._linksButton);
            verify(!touch.linksOpen);
            verify(rest.activeFocus, "the focus did not go back to where it was");
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            verify(!touch.linksOpen);
            compare(root.opened, []);
        }

        function test_space_after_a_link_was_clicked_is_the_pages() {
            touch.trackArtist = "Björk";
            press(touch._linksButton);
            press(touch._lastfmEntry);
            compare(root.opened.length, 1);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            compare(root.opened.length, 1);
            verify(!touch.linksOpen);
        }

        function test_space_after_the_menu_was_shut_by_a_click_beside_it_is_the_pages() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            mouseClick(touch, 100, 150, Qt.RightButton);
            verify(touch.linksOpen);
            mouseClick(touch, 20, 180);
            verify(!touch.linksOpen);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            verify(!touch.linksOpen && !touch.larger);
            // Opened with the mouse and shut with Escape: the same.
            press(touch._linksButton);
            keyClick(Qt.Key_Escape);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            compare(root.escapes, 0);
        }

        function test_space_after_the_cover_was_clicked_larger_and_back_is_the_pages() {
            touch.art = picture;
            mouseClick(touch, 100, 100);
            verify(touch.larger);
            mouseClick(root, 5, 5);
            verify(!touch.larger);
            verify(rest.activeFocus, "the focus did not go back to where it was");
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            verify(!touch.larger);
            // Opened with the mouse, shut with a key: the same.
            mouseClick(touch, 100, 100);
            keyClick(Qt.Key_Escape);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            verify(!touch.larger);
        }

        // Whoever walked there with Tab is still on the button afterwards,
        // and Space does there what it did before.
        function test_the_keyboards_own_way_ends_on_the_button_it_started_from() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            keyClick(Qt.Key_Tab);
            verify(touch._coverButton.activeFocus);
            keyClick(Qt.Key_Tab);
            verify(touch._linksButton.activeFocus);
            keyClick(Qt.Key_Space);
            verify(touch.linksOpen);
            keyClick(Qt.Key_Escape);
            verify(touch._linksButton.activeFocus);
            keyClick(Qt.Key_Space);
            verify(touch.linksOpen);
            keyClick(Qt.Key_Escape);
            // With the focus on the button, a click on it changes nothing about that.
            press(touch._linksButton);
            press(touch._linksButton);
            verify(touch._linksButton.activeFocus);
            keyClick(Qt.Key_Backtab);
            verify(touch._coverButton.activeFocus);
            keyClick(Qt.Key_Return);
            verify(touch.larger);
            mouseClick(root, 5, 5);
            verify(touch._coverButton.activeFocus);
            compare(root.spaces, 0);
        }

        // The menu key on the cover opens the menu, and one of the two taking
        // over from the other still ends where the first was opened from.
        function test_one_taking_over_from_the_other_ends_where_the_first_began() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            // What had the focus loses it once and gets it back once: it is
            // not handed the focus for a moment while one takes over from
            // the other, which a text field would answer by selecting itself.
            var hops = 0;
            var count = function() { hops++; };
            rest.activeFocusChanged.connect(count);
            touch.openLinks();
            touch.showLarger();
            verify(touch.larger && !touch.linksOpen);
            touch.closeLarger();
            verify(rest.activeFocus);
            compare(hops, 2);
            touch.showLarger();
            touch.openLinks();
            verify(touch.linksOpen && !touch.larger);
            verify(touch._lastfmEntry.activeFocus);
            touch.closeLinks();
            verify(rest.activeFocus);
            compare(hops, 4);
            rest.activeFocusChanged.disconnect(count);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
        }

        // The song ends while its cover is shown larger and the next has no
        // picture: the view shuts by itself. An item nobody sees must not
        // keep the keyboard, or the next Space is spent on closing nothing.
        function test_a_view_that_shuts_by_itself_gives_the_keyboard_back() {
            touch.art = picture;
            mouseClick(touch, 100, 100);
            verify(touch._largerView.activeFocus);
            touch.art = "";
            verify(!touch.larger);
            verify(!touch._largerView.activeFocus);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            // The same when the next picture is a small logo.
            touch.art = picture;
            mouseClick(touch, 100, 100);
            touch.natural = Qt.size(32, 32);
            verify(!touch.larger);
            verify(rest.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
        }

        // The button the focus came from is gone by the time the view shuts:
        // the keyboard goes to the face, where the page's keys are heard.
        function test_the_keyboard_goes_to_the_face_when_its_button_is_gone() {
            touch.art = picture;
            keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_Return);
            verify(touch.larger);
            touch.art = "";
            verify(!touch.larger);
            verify(!touch._coverButton.visible);
            verify(!touch._largerView.activeFocus && !touch._coverButton.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            // The menu's button goes with its artist.
            touch.trackArtist = "Björk";
            rest.forceActiveFocus();
            keyClick(Qt.Key_Tab);
            verify(touch._linksButton.activeFocus);
            keyClick(Qt.Key_Return);
            touch.trackArtist = "";
            keyClick(Qt.Key_Escape);
            verify(!touch.linksOpen);
            verify(!touch._linksButton.visible);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            compare(root.opened, []);
        }

        // The keyboard rests on one of the cover's buttons and the button
        // goes: the next picture is a small logo, an advert takes the artist
        // away. What it held does not stay on something nobody sees.
        function test_a_button_that_goes_while_it_holds_the_keyboard_lets_it_go() {
            touch.art = picture;
            keyClick(Qt.Key_Tab);
            verify(touch._coverButton.activeFocus);
            touch.natural = Qt.size(32, 32);
            verify(!touch._coverButton.visible);
            verify(!touch._coverButton.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            verify(!touch.larger);
            touch.trackArtist = "Björk";
            rest.forceActiveFocus();
            keyClick(Qt.Key_Tab);
            verify(touch._linksButton.activeFocus);
            touch.trackArtist = "";
            verify(!touch._linksButton.visible);
            verify(!touch._linksButton.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            verify(!touch.linksOpen);
        }

        // What had the focus before is hidden or switched off by the time
        // the menu shuts. The keyboard is not put on something that cannot
        // be seen or used: it goes to the face.
        function test_the_keyboard_is_not_given_back_to_something_hidden_or_switched_off_data() {
            return [{ tag: "hidden", prop: "visible" }, { tag: "switched off", prop: "enabled" }];
        }
        function test_the_keyboard_is_not_given_back_to_something_hidden_or_switched_off(data) {
            touch.trackArtist = "Björk";
            press(touch._linksButton);
            rest[data.prop] = false;
            press(touch._linksButton);
            verify(!touch.linksOpen);
            verify(!rest.activeFocus && !rest.focus);
            verify(!touch._lastfmEntry.activeFocus);
            verify(root.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            compare(root.opened, []);
        }

        // On a face that is a plain item the keyboard still ends on the face
        // itself, where its keys are heard, not on whatever scope is above it.
        function test_a_face_that_is_no_focus_scope_gets_the_keyboard_itself() {
            plain.visible = true;
            plain.natural = Qt.size(600, 600);
            plain.art = picture;
            plain._coverButton.forceActiveFocus();
            verify(plain._coverButton.activeFocus);
            plain.art = "";
            verify(!plain._coverButton.visible);
            verify(plainFace.activeFocus);
            keyClick(Qt.Key_Space);
            compare(plainFace.spaces, 1);
        }

        // The page is left with the menu open and visited again.
        function test_a_page_left_with_something_open_does_not_keep_the_keyboard_there() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            press(touch._linksButton);
            cover.visible = false;
            cover.visible = true;
            verify(!touch.linksOpen);
            verify(!touch._lastfmEntry.activeFocus);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 1);
            compare(root.opened, []);
            mouseClick(touch, 100, 100);
            cover.visible = false;
            cover.visible = true;
            verify(!touch.larger);
            keyClick(Qt.Key_Space);
            compare(root.spaces, 2);
            verify(!touch.larger);
        }

        function test_leaving_the_page_shuts_what_was_open() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            touch.openLinks();
            cover.visible = false;
            verify(!touch.linksOpen);
            cover.visible = true;
            touch.showLarger();
            cover.visible = false;
            verify(!touch.larger);
            cover.visible = true;
        }

        function test_one_of_the_two_is_open_at_a_time() {
            touch.trackArtist = "Björk";
            touch.art = picture;
            touch.openLinks();
            touch.showLarger();
            verify(touch.larger);
            verify(!touch.linksOpen);
            touch.openLinks();
            verify(touch.linksOpen);
            verify(!touch.larger);
        }

        function test_two_hundred_songs_in_a_row_open_nothing() {
            for (var n = 0; n < 200; n++) {
                touch.trackArtist = n % 7 === 0 ? "" : "Artist " + n;
                touch.art = n % 5 === 0 ? "" : picture + "-" + n;
                touch.kind = ["track", "artist", "release", ""][n % 4];
                compare(touch._coverNote.visible, touch.art !== "" && (n % 4 === 1 || n % 4 === 2));
            }
            compare(root.opened, []);
            verify(!touch.linksOpen);
            verify(!touch.larger);
        }
    }
}
