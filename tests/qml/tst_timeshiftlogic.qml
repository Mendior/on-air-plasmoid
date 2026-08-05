// SPDX-FileCopyrightText: 2026 Egon Greenberg
// SPDX-License-Identifier: LGPL-2.0-or-later
// Timeshift's judgment layer, tested before the engine exists. The numbers
// here are the contract the engine will be built against: what "behind
// live" means, where a seek may land, how much disk a buffer may claim.
import QtQuick
import QtTest

import "../../package/contents/ui/TimeshiftLogic.js" as TS

TestCase {
    name: "TimeshiftLogic"

    function test_only_recordable_streams_can_shift() {
        verify(TS.canTimeshift("http://s1.radio.ee/live.mp3"))
        verify(TS.canTimeshift("https://s1.radio.ee/live"))
        verify(!TS.canTimeshift("http://s1.radio.ee/live.m3u8"))
        verify(!TS.canTimeshift("http://s1.radio.ee/list.pls"))
        verify(!TS.canTimeshift("file:///home/egon/song.mp3"))
        verify(!TS.canTimeshift(""))
    }

    function test_the_buffer_container_is_judged_strictly() {
        compare(TS.bufferExtension("http://x/live.mp3"), "mp3")
        compare(TS.bufferExtension("http://x/live.aac"), "aac")
        compare(TS.bufferExtension("http://x/live.ogg"), "ogg")
        // A fuzzy "probably mp3" is NOT trusted into a .mp3 shell.
        compare(TS.bufferExtension("http://x/mp3-96"), "mka")
        compare(TS.bufferExtension("http://x/live"), "mka")
    }

    function test_behind_live_is_wall_time_minus_position() {
        // Capture began at t=0, it is now t=100s, the player sits at 40s
        // into the file: the listener is 60s behind the broadcast.
        compare(TS.behindLiveMs(0, 100000, 40000), 60000)
        compare(TS.behindLiveMs(0, 100000, 100000), 0)
        // Clock skew or a position event outrunning the wall clock must
        // read as live, never as negative time travel.
        compare(TS.behindLiveMs(0, 100000, 105000), 0)
    }

    function test_live_is_a_band_not_a_point() {
        verify(TS.isAtLiveEdge(0, 3000))
        verify(TS.isAtLiveEdge(3000, 3000))
        verify(!TS.isAtLiveEdge(3001, 3000))
    }

    function test_seeks_stay_inside_the_buffer() {
        // 100s captured, 3s tail guard: the reachable window is 0..97s.
        compare(TS.clampSeekMs(50000, 100000, 3000), 50000)
        compare(TS.clampSeekMs(-5000, 100000, 3000), 0)
        compare(TS.clampSeekMs(99000, 100000, 3000), 97000)
        // A buffer younger than the guard has nowhere safe to go yet.
        compare(TS.clampSeekMs(1000, 2000, 3000), 0)
    }

    function test_the_disk_budget_keeps_headroom() {
        // 1 GiB free, 200 MiB headroom: (1024-200) MiB at ~2 MiB/min.
        compare(TS.maxBufferMinutes(1024 * 1024 * 1024, 200 * 1024 * 1024), 412)
        compare(TS.maxBufferMinutes(100 * 1024 * 1024, 200 * 1024 * 1024), 0)
        compare(TS.maxBufferMinutes(0, 0), 0)
    }

    function test_resume_lands_where_the_listener_stopped() {
        compare(TS.resumePositionMs(40000, 100000, 3000), 40000)
        // A pause that outlived the buffer clamps instead of erroring.
        compare(TS.resumePositionMs(150000, 100000, 3000), 97000)
    }

    function opts() {
        return {
            url: "http://s1.radio.ee/live.mp3?token=a&b=c",
            cfgPath: "/home/egon/.cache/onair/ts/url.cfg",
            outPath: "/home/egon/.cache/onair/ts/buffer.mp3",
            pidPath: "/home/egon/.cache/onair/ts/writer.pid",
            dirPath: "/home/egon/.cache/onair/ts",
            windowSec: 3600, needKiB: 122880, seq: 7
        }
    }

    function test_the_url_never_rides_the_writers_argv() {
        var c = TS.buildBufferCommands(opts())
        // The address appears ONLY in the config-file write; the long-lived
        // writer command must carry the file's path instead.
        verify(c.writeUrl.indexOf("live.mp3") !== -1)
        verify(c.run.indexOf("live.mp3?token") === -1)
        verify(c.run.indexOf("-K '/home/egon/.cache/onair/ts/url.cfg'") !== -1)
        verify(c.writeUrl.indexOf("umask 077") !== -1)
        // The config write is the FIRST touch on the directory — without
        // its own mkdir the very first arm on a machine failed before the
        // writer ever existed. The sweep may only take day-old leftovers:
        // a fresh pid file can belong to a still-live writer.
        verify(c.writeUrl.indexOf("mkdir -p '/home/egon/.cache/onair/ts'") !== -1)
        verify(c.writeUrl.indexOf("-mmin +1440 -delete") !== -1)
    }

    function test_the_writer_copies_flushes_and_caps() {
        var c = TS.buildBufferCommands(opts())
        verify(c.run.indexOf("-c copy") !== -1)
        verify(c.run.indexOf("-flush_packets 1") !== -1)
        verify(c.run.indexOf("-t 3600") !== -1)
        // Wall clock caps at window + 10% (>=300 s of grace).
        verify(c.run.indexOf("timeout --signal=INT --kill-after=30 3960") !== -1)
        verify(c.run.indexOf("--http0.9") !== -1)
        verify(c.run.indexOf("__TS_EXIT__") !== -1)
    }

    function test_hostile_paths_stay_quoted() {
        var o = opts()
        o.dirPath = "/tmp/x'; rm -rf $HOME; echo '"
        o.outPath = o.dirPath + "/buffer.mp3"
        var c = TS.buildBufferCommands(o)
        // The quoter turns the embedded quote into the '\'' idiom — the
        // dollar and the rm stay literal text inside single quotes.
        verify(c.run.indexOf("'\\''") !== -1)
        verify(c.run.indexOf("rm -rf $HOME; echo") === -1
               || c.run.indexOf("'/tmp/x'\\''; rm -rf $HOME; echo '\\'''") !== -1)
    }

    function test_the_stop_takes_the_buffer_with_it() {
        var s = TS.buildStopCommand("/d/writer.pid", "/d/buffer.mp3", "/d/url.cfg", 9)
        verify(s.indexOf("kill -INT") !== -1)
        verify(s.indexOf("rm -f '/d/buffer.mp3' '/d/writer.pid' '/d/url.cfg'") !== -1)
    }

    function test_the_tap_serves_raw_bytes_and_acks_by_the_port() {
        var c = TS.buildServeCommands({ bufPath: "/d/buffer-7.ogg",
                                        srvPidPath: "/d/serve-7.pid",
                                        scriptPath: "/opt/onair/relayserve.py",
                                        port: 17807, seq: 7 })
        verify(c.run.indexOf(": TS_SRV;") === 0)
        // Raw bytes on purpose: a remuxer in this seat died at every Ogg
        // chain boundary a reconnecting upstream wrote (measured, Lapfox).
        verify(c.run.indexOf("python3 '/opt/onair/relayserve.py' '/d/buffer-7.ogg' 17807") !== -1)
        verify(c.run.indexOf("echo $! > '/d/serve-7.pid'") !== -1)
        // The ack rides the port answering, not a guessed timer — a player
        // sent to a refused port never retries (measured).
        verify(c.run.indexOf("__TS_SRV_UP__") !== -1)
        verify(c.run.indexOf("__TS_SRV_DOWN__") !== -1)
        verify(/#\s*7\s*$/.test(c.run))
    }

    function test_a_relay_stop_reaps_the_tap_too() {
        var s = TS.buildStopCommand("/d/writer.pid", "/d/buffer-7.ogg", "/d/url.cfg", 9,
                                    "/d/serve-7.pid")
        verify(s.indexOf("kill -INT") !== -1)
        verify(s.indexOf("'/d/serve-7.pid'") !== -1)
        verify(s.indexOf("rm -f '/d/buffer-7.ogg' '/d/writer.pid' '/d/url.cfg'") !== -1)
    }
}
