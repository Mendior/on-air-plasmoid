# SPDX-FileCopyrightText: 2026 Egon Greenberg
# SPDX-License-Identifier: LGPL-2.0-or-later
#
# The loopback tap of the Ogg relay: serves the growing buffer file to the
# player, one client, raw bytes. Raw on purpose — the first tap remuxed
# through ffmpeg, and a station whose upstream drops the connection writes
# a fresh Ogg chain into the file on every reconnect; the remuxer died at
# each boundary and the listener heard "plays, goes quiet, plays" (Lapfox,
# measured live 2026-08-05). Bytes passed through untouched reach the
# player's own demuxer, which eats chained Ogg like any Icecast client:
# the same station then ran eight minutes without a single stall.
import os
import socket
import sys
import time

buf_path, port_file = sys.argv[1], sys.argv[2]

# A head start before the first byte, the same trick Icecast plays on its
# own clients (burst-on-connect) and for the same reason. The first tap
# began sending the moment the buffer file appeared, which handed the
# player the live edge with no cushion at all: every time it caught up it
# waited on the network for the next packet. A listener reported the
# result exactly — a 1.5 Mbps FLAC station stuttering for its first ten
# seconds, then settling. The player's own buffer is counted in BYTES,
# so the same 64 KiB holds 0.35 s of that FLAC and 4 s of a 128 kbps
# stream: the fat ones run dry first, which is why only they stuttered.
# Whichever arrives first — enough bytes for a fat stream, or the clock
# for a thin one, where a byte target would mean a half-minute wait. The
# clock is deliberately short: a 128 kbps stream never starved in the
# first place, so making its listener wait for a cushion it does not need
# would be a fresh bug. A fat stream reaches the byte target well inside
# it anyway (measured on a 1 Mbps FLAC: 0.8 s, thanks to the burst
# Icecast itself sends on connect).
LEAD_BYTES = 512 * 1024
LEAD_SEC = 1.5
# The wait between "the file has nothing new" and the next look. At 200 ms
# this was itself a stall the player could hear once its own buffer ran
# thin; the read costs nothing when the answer is empty.
IDLE_SLEEP = 0.05

# The kernel picks the port. The first tap took a number derived from the
# widget's global exec counter — which every metadata poll advances, so the
# 180-slot range recycled within minutes and a collision meant this bind
# died silently while the shell reported the OTHER listener as ours. An
# ephemeral bind cannot collide, and writing the number down only after
# listen() makes the file's existence the real "you may connect now".
srv = socket.socket()
try:
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
except OSError:
    sys.exit(1)
tmp_file = port_file + ".tmp"
with open(tmp_file, "w") as f:
    f.write(str(srv.getsockname()[1]))
os.replace(tmp_file, port_file)
# The one seat is the player's. If nobody sits down (the arm was torn
# down before its ack landed), leave instead of holding the port forever.
srv.settimeout(60.0)
try:
    conn, _ = srv.accept()
except (TimeoutError, OSError):
    sys.exit(0)
srv.close()
# A frozen client would park sendall for good; the stop road only reaps
# by deleting the buffer, which a blocked writer never notices.
conn.settimeout(600.0)


def serve(sock: socket.socket) -> None:
    """Stream the buffer to the player until one of them goes away."""
    sock.recv(4096)
    sock.sendall(b"HTTP/1.0 200 OK\r\n"
                 b"Content-Type: application/octet-stream\r\n"
                 b"Cache-Control: no-cache\r\n\r\n")
    # The writer creates the file a beat after this tap launches — wait
    # for it, but not forever: a writer that never wrote has failed, and
    # the engine handles a tap that closes. Holding the headers back
    # until the file exists was tried and dropped: the backend sits
    # through an empty body just as patiently (measured against a writer
    # made five seconds late — same time to sound either way), so the
    # change bought nothing and only moved a proven behaviour.
    waited = 0.0
    while not os.path.exists(buf_path):
        time.sleep(0.1)
        waited += 0.1
        if waited > 30.0:
            return
    # Let the writer get ahead before the player hears anything (see the
    # constants). A buffer that vanishes mid-wait is a torn-down arm: the
    # open below fails and the caller's handler ends this tap.
    lead = 0.0
    while lead < LEAD_SEC:
        try:
            if os.path.getsize(buf_path) >= LEAD_BYTES:
                break
        except OSError:
            break
        time.sleep(0.1)
        lead += 0.1
    idle = 0.0
    with open(buf_path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if chunk:
                sock.sendall(chunk)
                idle = 0.0
                continue
            time.sleep(IDLE_SLEEP)
            idle += IDLE_SLEEP
            try:
                os.stat(buf_path)
            except FileNotFoundError:
                return               # the stop road took the buffer
            if idle > 900.0:
                return               # writer long dead, nobody re-armed


try:
    serve(conn)
except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
    pass
