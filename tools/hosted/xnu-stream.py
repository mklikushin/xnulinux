#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Stream the hosted macOS screen from the Linux host over WebRTC, and take the viewer's pointer and keys back.

The screen is read where xnu.ko dumps it (fb_dump; give xnu.ko fb_dump_ms=16 and a file in /dev/shm), encoded on the
host (H.264 or VP8) and pushed to one browser; input comes back on a data channel and goes to XnuInput (input_in), as
tools/hosted/xnu-input.py writes it. macOS takes no part: no Screen Sharing, no capture in the guest.

    xnu-stream.py [--fb /dev/shm/xnu-fb.raw] [--screen 1280x800] [--input /var/tmp/xnu-input] [--fps 60]
                  [--http 127.0.0.1:8555] [--media-port 8556] [--advertise 127.0.0.1] [--codec h264|vp8] [--kbps 8000]

The page is http://<--http>/. With the default --advertise 127.0.0.1 the media goes over TCP to one of the eight ports
from --media-port up, for an ssh tunnel and no firewall change:
    ssh -N -L 8555:127.0.0.1:8555 $(for p in 8556 8557 8558 8559 8560 8561 8562 8563; do echo -L $p:<host address>:$p; done) host
then open http://127.0.0.1:8555/. --advertise <public address> offers UDP (and TCP) on those ports there instead: they
must be open to the viewer, and the page needs its own access control before they are.

Needs GStreamer 1.20 or later with webrtcbin, libnice, x264enc or vp8enc, and the Python bindings (Ubuntu:
gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-nice gir1.2-gst-plugins-bad-1.0 python3-gst-1.0).

A modifier is let go when the browser no longer reports it down or the page loses the keyboard (a system shortcut that
takes the keyboard away never sends the key-up). Shortcuts the browser or the viewer's system keeps for itself (Command-W,
Command-Tab) do not reach the page.

Not done yet: the pointer's image (macOS gives it as a layer of its own, which is not in the dump: the page shows the
browser's pointer, so it moves at once), and frames are read while the display may be writing them (a torn frame now
and then). The page connects again by itself when the streamer or the hosted system restarts.
"""
import argparse, json, mmap, os, select, signal, socket, struct, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import gi
gi.require_version('Gst', '1.0'); gi.require_version('GstWebRTC', '1.0'); gi.require_version('GstSdp', '1.0')
from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # noqa: E402

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES, BTN_TOUCH = 0x0b, 0x0c, 0x14a
BUTTONS = {0: 0x110, 1: 0x112, 2: 0x111}   # the browser's button numbers: left, middle, right
CODES = {  # KeyboardEvent.code -> Linux key code (input-event-codes.h)
    'Escape': 1, 'Minus': 12, 'Equal': 13, 'Backspace': 14, 'Tab': 15, 'BracketLeft': 26, 'BracketRight': 27, 'Enter': 28,
    'ControlLeft': 29, 'Semicolon': 39, 'Quote': 40, 'Backquote': 41, 'ShiftLeft': 42, 'Backslash': 43, 'Comma': 51,
    'Period': 52, 'Slash': 53, 'ShiftRight': 54, 'AltLeft': 56, 'Space': 57, 'CapsLock': 58, 'F11': 87, 'F12': 88,
    'ControlRight': 97, 'AltRight': 100, 'Home': 102, 'ArrowUp': 103, 'PageUp': 104, 'ArrowLeft': 105, 'ArrowRight': 106,
    'End': 107, 'ArrowDown': 108, 'PageDown': 109, 'Delete': 111, 'MetaLeft': 125, 'MetaRight': 126,
    **{'Digit' + d: 2 + i for i, d in enumerate('1234567890')},
    **{'F%d' % (i + 1): 59 + i for i in range(10)},
}
MODIFIERS = ((1, (125, 126)), (2, (29, 97)), (4, (56, 100)), (8, (42, 54)))   # the page's bits: meta, control, alt, shift
for row, start in (('QWERTYUIOP', 16), ('ASDFGHJKL', 30), ('ZXCVBNM', 44)):
    for i, ch in enumerate(row):
        CODES['Key' + ch] = start + i


class Input:
    """Pointer and keys to XnuInput: Linux evdev records appended to xnu.ko's input_in."""
    def __init__(self, path):
        self.out = open(path, 'ab', buffering=0)
        self.held = set()
        self.touch, self.sx, self.sy = False, 0.0, 0.0

    def send(self, *events):
        self.out.write(b''.join(struct.pack('<HHi', *e) for e in events) + struct.pack('<HHi', EV_SYN, 0, 0))

    def message(self, m):
        t = m.get('t')
        if t == 'release':   # the page lost the keyboard (another window, another tab): nothing stays down
            self.release_all()
            return
        if 'mods' in m:      # the modifiers the browser says are down: one whose key-up never came is let go
            for bit, codes in MODIFIERS:
                if not int(m['mods']) & bit:
                    for code in codes:
                        if code in self.held:
                            self.key(code, False)
        if t == 'm':     # pointer at x, y, each 0..1 of the screen
            x, y = (min(max(float(m[k]), 0.0), 1.0) for k in ('x', 'y'))
            self.send((EV_ABS, 0, int(x * 32767)), (EV_ABS, 1, int(y * 32767)))
        elif t == 'b' and m.get('b') in BUTTONS:
            self.key(BUTTONS[m['b']], bool(m.get('d')))
        elif t == 'k' and m.get('c') in CODES:
            self.key(CODES[m['c']], bool(m.get('d')))
        elif t == 's':   # scrolling by pixels (y down, x right): XnuInput's scroll service, 120 units a line of 40 pixels
            if m.get('g') and not self.touch:
                self.touch = True
                self.send((EV_KEY, BTN_TOUCH, 1))          # a gesture begins (only for a page opened with ?gestures=1)
            self.sx += float(m.get('x', 0)) * 3
            self.sy += float(m.get('y', 0)) * 3
            x, y = int(self.sx), int(self.sy)
            self.sx -= x; self.sy -= y
            events = [(EV_REL, c, v) for c, v in ((REL_HWHEEL_HI_RES, x), (REL_WHEEL_HI_RES, y)) if v]
            if events:
                self.send(*events)
        elif t == 'se':  # the fingers left: the gesture ends
            self.end_scroll()
        elif t == 'w':   # wheel notches: y up positive, x right positive
            events = [(EV_REL, c, int(v)) for c, v in ((8, m.get('y', 0)), (6, m.get('x', 0))) if int(v)]
            if events:
                self.send(*events)

    def end_scroll(self):
        if self.touch:
            self.touch = False
            self.sx = self.sy = 0.0
            self.send((EV_KEY, BTN_TOUCH, 0))

    def key(self, code, down):
        (self.held.add if down else self.held.discard)(code)
        self.send((EV_KEY, code, 1 if down else 0))

    def release_all(self):   # the viewer went away with keys or buttons down
        self.end_scroll()
        for code in sorted(self.held):
            self.send((EV_KEY, code, 0))
        self.held.clear()


KEEP = []
MEDIA_PORTS = 8


class Session:
    """One viewer: the screen into an encoder into webrtcbin, the input channel back."""
    def __init__(self, a, inp):
        self.a, self.input, self.closed = a, inp, False
        self.pushed = self.reads = 0
        self.started = time.time()
        w, h = a.width, a.height
        if a.codec == 'vp8':
            enc = ('vp8enc deadline=1 cpu-used=10 threads=3 error-resilient=default keyframe-max-dist=600 end-usage=cbr '
                   'target-bitrate=%d lag-in-frames=0 ! rtpvp8pay ! application/x-rtp,media=video,encoding-name=VP8,clock-rate=90000,payload=96'
                   % (a.kbps * 1000))
        else:
            enc = ('x264enc tune=zerolatency speed-preset=ultrafast bitrate=%d key-int-max=600 bframes=0 threads=3 ! '
                   'video/x-h264,profile=constrained-baseline ! rtph264pay config-interval=-1 aggregate-mode=zero-latency ! '
                   'application/x-rtp,media=video,encoding-name=H264,clock-rate=90000,payload=96' % a.kbps)
        self.pipe = Gst.parse_launch(
            'appsrc name=src is-live=true format=time do-timestamp=true block=false max-buffers=2 leaky-type=downstream '
            'caps=video/x-raw,format=BGRx,width=%d,height=%d,framerate=0/1 ! videoconvert n-threads=2 ! video/x-raw,format=I420 ! '
            '%s ! webrtcbin name=wb bundle-policy=max-bundle' % (w, h, enc))
        self.src, self.wb = self.pipe.get_by_name('src'), self.pipe.get_by_name('wb')
        ice = self.wb.get_property('ice-agent')
        KEEP.append(ice)   # webrtcbin holds it by a floating reference, which the binding takes: never let go of it here
        # A few ports, not one: the connections of a viewer that just left keep its port for a minute (TIME_WAIT), and
        # the next viewer's listener could not bind it (no candidate was ever gathered: "no offer" for a minute).
        ice.set_property('min-rtp-port', a.media_port); ice.set_property('max-rtp-port', a.media_port + MEDIA_PORTS - 1)
        ice.set_property('ice-tcp', True); ice.set_property('ice-udp', a.advertise != '127.0.0.1')
        self.offer, self.offered, self.gathered = None, threading.Event(), threading.Event()
        self.wb.connect('on-negotiation-needed', self.negotiate)
        self.wb.connect('notify::ice-gathering-state', self.gathering)
        self.wb.connect('notify::connection-state', self.state)
        self.pipe.set_state(Gst.State.READY)
        self.channel = self.wb.emit('create-data-channel', 'input', None)
        if self.channel:
            self.channel.connect('on-message-string', self.on_message)
        self.pipe.set_state(Gst.State.PLAYING)
        threading.Thread(target=self.frames, daemon=True).start()

    def negotiate(self, wb):
        def created(promise):
            reply = promise.get_reply()
            offer = reply.get_value('offer') if reply and reply.has_field('offer') else None
            if offer is None:
                print('no offer:', reply.to_string() if reply else promise.wait(), file=sys.stderr, flush=True)
                return
            wb.emit('set-local-description', offer, Gst.Promise.new())
            self.offered.set()
        wb.emit('create-offer', None, Gst.Promise.new_with_change_func(lambda p: created(p)))

    def gathering(self, wb, _):
        if wb.get_property('ice-gathering-state') == GstWebRTC.WebRTCICEGatheringState.COMPLETE:
            self.gathered.set()

    def state(self, wb, _):
        s = wb.get_property('connection-state')
        print('viewer:', s.value_nick, file=sys.stderr, flush=True)
        if s in (GstWebRTC.WebRTCPeerConnectionState.FAILED, GstWebRTC.WebRTCPeerConnectionState.CLOSED,
                 GstWebRTC.WebRTCPeerConnectionState.DISCONNECTED):
            GLib.idle_add(self.close)

    def local_offer(self):
        """The offer once every candidate is in it, with the addresses the viewer can reach."""
        if not self.offered.wait(10) or not self.gathered.wait(10):
            print('no offer after 10 s: offered %s, candidates gathered %s' % (self.offered.is_set(), self.gathered.is_set()), file=sys.stderr, flush=True)
            return None
        sdp, a, out = self.wb.get_property('local-description').sdp.as_text(), self.a, []
        for line in sdp.split('\r\n'):
            if line.startswith('a=candidate:'):
                f = line.split(' ')
                if f[4] != a.host_ip:
                    continue                      # one interface: the one the tunnel or the public address leads to
                tcp = f[2].lower() == 'tcp'
                if a.advertise == '127.0.0.1' and not (tcp and 'passive' in f):
                    continue                      # through an ssh tunnel: the viewer connects to our TCP port
                if tcp and 'passive' not in f:
                    continue
                f[4] = a.advertise
                line = ' '.join(f)
            out.append(line)
        return '\r\n'.join(out)

    def answer(self, sdp):
        res, msg = GstSdp.SDPMessage.new_from_text(sdp)
        if res != GstSdp.SDPResult.OK:
            return False
        desc = GstWebRTC.WebRTCSessionDescription.new(GstWebRTC.WebRTCSDPType.ANSWER, msg)
        self.wb.emit('set-remote-description', desc, Gst.Promise.new())
        return True

    def on_message(self, _channel, text):
        try:
            self.input.message(json.loads(text))
        except (ValueError, KeyError, TypeError):
            pass

    def frames(self):
        """A frame to the encoder whenever the dump has changed (asked twice as often as it is written), one every half
        second while it has not, so a viewer who joins a still screen gets a picture."""
        a, size = self.a, self.a.width * self.a.height * 4
        f = open(a.fb, 'rb')
        mm = mmap.mmap(f.fileno(), size, access=mmap.ACCESS_READ)
        last, last_push, period = None, 0.0, 0.5 / a.fps
        while not self.closed:
            t = time.monotonic()
            cur = mm[:size]
            self.reads += 1
            if cur != last or t - last_push > 0.5:
                last, last_push = cur, t
                if self.src.emit('push-buffer', Gst.Buffer.new_wrapped(cur)) != Gst.FlowReturn.OK and not self.closed:
                    break
                self.pushed += 1
            time.sleep(max(0.0, period - (time.monotonic() - t)))
        mm.close(); f.close()

    def close(self, replaced=False):
        if not self.closed:
            self.closed = True
            if replaced and self.channel:
                try:
                    self.channel.emit('send-string', json.dumps({'t': 'replaced'}))
                    time.sleep(0.05)
                except Exception:
                    pass
            self.input.release_all()
            self.pipe.set_state(Gst.State.NULL)
            os._exit(0)   # a viewer is a process: its ports and its encoder go with it
        return False


PAGE = r'''<!doctype html><meta charset=utf-8><title>xnulinux</title>
<style>html,body{margin:0;height:100%;background:#111;color:#bbb;font:13px system-ui;overflow:hidden}
video{position:absolute;inset:0;margin:auto;max-width:100%;max-height:100%;outline:none}
#s{position:fixed;left:8px;bottom:6px;background:#000a;padding:2px 6px;border-radius:4px;pointer-events:none}</style>
<video id=v autoplay muted playsinline tabindex=0></video><div id=s>connecting</div>
<script>
const v = document.getElementById('v'), s = document.getElementById('s');
let pc, ch, last = null, replaced = false;
const send = m => { if (ch && ch.readyState === 'open') ch.send(JSON.stringify(m)); };
let again = 0;
function retry(why) {   // the streamer or the hosted system restarted, or the first try came too early: connect again
  if (replaced) return;
  s.textContent = why + ', connecting again';
  clearTimeout(again); again = setTimeout(() => start().catch(e => retry('failed: ' + e.message)), 2000);
}
async function start() {
  replaced = false;
  clearTimeout(again);
  if (pc) { pc.onconnectionstatechange = null; pc.close(); }
  ch = null; last = null;
  pc = new RTCPeerConnection();
  pc.ontrack = e => {
    v.srcObject = e.streams[0] || new MediaStream([e.track]);
    for (const r of pc.getReceivers()) { if ('jitterBufferTarget' in r) r.jitterBufferTarget = 0; if ('playoutDelayHint' in r) r.playoutDelayHint = 0; }
  };
  pc.ondatachannel = e => {
    ch = e.channel;
    ch.onmessage = ev => {
      try {
        if (JSON.parse(ev.data).t === 'replaced') {
          replaced = true;
          clearTimeout(again);
          s.textContent = 'taken over by another tab — click to reconnect';
        }
      } catch {}
    };
  };
  pc.onconnectionstatechange = () => { if (replaced) return; s.textContent = pc.connectionState; if (['failed', 'disconnected', 'closed'].includes(pc.connectionState)) retry(pc.connectionState); };
  const offer = await (await fetch('session', { method: 'POST' })).json();
  if (!offer.sdp) throw new Error(offer.error || 'no offer');
  await pc.setRemoteDescription({ type: 'offer', sdp: offer.sdp });
  await pc.setLocalDescription(await pc.createAnswer());
  await new Promise(done => { if (pc.iceGatheringState === 'complete') done(); else { pc.onicegatheringstatechange = () => pc.iceGatheringState === 'complete' && done(); setTimeout(done, 1500); } });
  await fetch('answer', { method: 'POST', body: pc.localDescription.sdp });
}
function at(e) {   // the pointer's place on the screen, 0..1 each way, inside the picture as the page scales it
  const r = v.getBoundingClientRect(), a = (v.videoWidth || 16) / (v.videoHeight || 10);
  let w = r.width, h = r.height;
  if (w / h > a) w = h * a; else h = w / a;
  return { x: (e.clientX - r.left - (r.width - w) / 2) / w, y: (e.clientY - r.top - (r.height - h) / 2) / h };
}
v.addEventListener('pointermove', e => { for (const c of (e.getCoalescedEvents ? e.getCoalescedEvents().slice(-1) : [e])) send({ t: 'm', ...at(c) }); });
// The modifiers as the browser has them now, sent with every button, key and wheel message: a key-up that never reached
// this page (a system shortcut took the keyboard away with Command down) must not leave the key down on the other side.
const mods = e => (e.metaKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.shiftKey ? 8 : 0);
v.addEventListener('pointerdown', e => { if (replaced) { start().catch(err => retry('failed: ' + err.message)); e.preventDefault(); return; } v.focus(); v.setPointerCapture(e.pointerId); send({ t: 'm', ...at(e) }); send({ t: 'b', b: e.button, d: 1, mods: mods(e) }); e.preventDefault(); });
v.addEventListener('pointerup', e => { send({ t: 'm', ...at(e) }); send({ t: 'b', b: e.button, d: 0, mods: mods(e) }); e.preventDefault(); });
v.addEventListener('contextmenu', e => e.preventDefault());
// Scrolling goes over by the pixel, as the browser reports it (two fingers on a trackpad, either way). With ?gestures=1
// in the address it also goes over as a gesture that begins and, a moment after its last event, ends: what a swipe on
// the other side waits for. That is off by default: a swipe on a notification was not dismissed with it, and before the
// end of a gesture was sure to arrive, one such swipe stopped all scrolling there until the hosted system restarted.
const gestures = new URLSearchParams(location.search).get('gestures') === '1';
let scrollEnd = 0;
v.addEventListener('wheel', e => {
  const unit = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 400 : 1;
  send({ t: 's', x: e.deltaX * unit, y: e.deltaY * unit, g: gestures ? 1 : 0, mods: mods(e) });
  if (gestures) { clearTimeout(scrollEnd); scrollEnd = setTimeout(() => send({ t: 'se' }), 150); }
  e.preventDefault();
}, { passive: false });
v.addEventListener('keydown', e => { send({ t: 'k', c: e.code, d: 1, mods: mods(e) }); e.preventDefault(); });
v.addEventListener('keyup', e => { send({ t: 'k', c: e.code, d: 0, mods: mods(e) }); e.preventDefault(); });
const release = () => send({ t: 'release' });
window.addEventListener('blur', release); v.addEventListener('blur', release); window.addEventListener('pagehide', release);
document.addEventListener('visibilitychange', () => { if (document.hidden) release(); });
window.xnuStats = async () => {   // for a check without a person: what arrives and how long it waits before it is shown
  const o = { state: pc && pc.connectionState, width: v.videoWidth, height: v.videoHeight, channel: ch && ch.readyState };
  for (const r of (await pc.getStats()).values()) {
    if (r.type === 'inbound-rtp' && r.kind === 'video') Object.assign(o, { frames: r.framesDecoded, fps: r.framesPerSecond, dropped: r.framesDropped, bytes: r.bytesReceived, jitterBufferMs: r.jitterBufferEmittedCount ? 1000 * r.jitterBufferDelay / r.jitterBufferEmittedCount : null, decoder: r.decoderImplementation });
    if (r.type === 'candidate-pair' && r.nominated) Object.assign(o, { rttMs: 1000 * r.currentRoundTripTime });
    if (r.type === 'remote-candidate') o.remote = r.protocol + ' ' + r.address + ':' + r.port;
  }
  return o;
};
setInterval(async () => { if (!pc || pc.connectionState !== 'connected') return; const o = await xnuStats(); if (last) s.textContent = (o.frames - last.frames) + ' frames a second, ' + Math.round((o.bytes - last.bytes) * 8 / 1000) + ' kbit/s, wait ' + Math.round(o.jitterBufferMs || 0) + ' ms'; last = o; }, 1000);
window.xnuSend = send;
start().catch(e => retry('failed: ' + e.message));
</script>'''


def worker(a):
    """One viewer, in a process of its own (started by the server): the offer out on stdout, the answer in on stdin."""
    Gst.init(None)
    session = Session(a, Input(a.input))
    signal.signal(signal.SIGTERM, lambda *_: session.close())
    signal.signal(signal.SIGUSR1, lambda *_: session.close(replaced=True))
    sdp = session.local_offer()
    print(json.dumps({'sdp': sdp}), flush=True)
    if sdp is None:
        os._exit(1)

    def answers():
        for line in sys.stdin:
            try:
                session.answer(json.loads(line)['sdp'])
            except (ValueError, KeyError):
                pass
        session.close()   # the server went away

    def report():
        while True:
            time.sleep(5)
            print(json.dumps({'frames': session.pushed, 'reads': session.reads, 'seconds': round(time.time() - session.started, 1)}), flush=True)
    threading.Thread(target=answers, daemon=True).start()
    threading.Thread(target=report, daemon=True).start()
    GLib.MainLoop().run()


def serve(a, argv):
    state = {'worker': None, 'stats': {}, 'lock': threading.Lock()}

    def stop(replaced=False):
        w = state['worker']
        if w and w.poll() is None:
            if replaced:
                w.send_signal(signal.SIGUSR1)
            else:
                w.terminate()
            try:
                w.wait(3)
            except subprocess.TimeoutExpired:
                w.kill(); w.wait()
        state['worker'] = None

    def follow(w):   # the worker's reports, until it ends
        for line in w.stdout:
            try:
                state['stats'] = json.loads(line)
            except ValueError:
                pass

    class Handler(BaseHTTPRequestHandler):
        def reply(self, code, kind, body):
            self.send_response(code); self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store')
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            if self.path.split('?')[0] == '/':
                self.reply(200, 'text/html; charset=utf-8', PAGE.encode())
            elif self.path == '/stats':
                w = state['worker']
                self.reply(200, 'application/json', json.dumps({'viewer': bool(w and w.poll() is None), **state['stats']}).encode())
            else:
                self.reply(404, 'text/plain', b'not found')

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            if self.path == '/session':       # one viewer: a new one replaces the old
                with state['lock']:
                    stop(replaced=True)
                    w = subprocess.Popen([sys.executable, os.path.abspath(__file__), '--worker'] + argv, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, text=True, bufsize=1)
                    state['worker'], state['stats'] = w, {}
                    line = w.stdout.readline() if select.select([w.stdout], [], [], 25)[0] else ''
                    try:
                        sdp = json.loads(line)['sdp']
                    except (ValueError, KeyError):
                        sdp = None
                    if not sdp:
                        stop(); self.reply(500, 'application/json', b'{"error": "no offer"}'); return
                    threading.Thread(target=follow, args=(w,), daemon=True).start()
                self.reply(200, 'application/json', json.dumps({'sdp': sdp}).encode())
            elif self.path == '/answer' and state['worker'] and state['worker'].poll() is None:
                try:
                    state['worker'].stdin.write(json.dumps({'sdp': body.decode('utf8', 'replace')}) + '\n')
                    state['worker'].stdin.flush()
                    self.reply(200, 'text/plain', b'ok')
                except OSError:
                    self.reply(500, 'text/plain', b'the viewer process ended')
            else:
                self.reply(404, 'text/plain', b'not found')

        def log_message(self, *args):
            pass

    host, port = a.http.rsplit(':', 1)
    server = ThreadingHTTPServer((host, int(port)), Handler)
    signal.signal(signal.SIGTERM, lambda *_: (stop(), os._exit(0)))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    stop()


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--fb', default='/dev/shm/xnu-fb.raw'); p.add_argument('--screen', default='1280x800')
    p.add_argument('--input', default='/var/tmp/xnu-input'); p.add_argument('--fps', type=int, default=60)
    p.add_argument('--http', default='127.0.0.1:8555'); p.add_argument('--media-port', type=int, default=8556)
    p.add_argument('--advertise', default='127.0.0.1'); p.add_argument('--host-ip', default='')
    p.add_argument('--codec', choices=('h264', 'vp8'), default='h264'); p.add_argument('--kbps', type=int, default=8000)
    p.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    a = p.parse_args()
    a.width, a.height = (int(v) for v in a.screen.split('x'))
    if os.path.getsize(a.fb) < a.width * a.height * 4:
        sys.exit('%s is smaller than a %s screen: is the hosted system up, with xnu.ko fb_dump=%s?' % (a.fb, a.screen, a.fb))
    if not a.host_ip:   # the address of the interface the default route leaves by
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('192.0.2.1', 9)); a.host_ip = s.getsockname()[0]; s.close()
    if a.worker:
        worker(a)
        return
    print('page http://%s/  media %s:%d-%d (offered as %s)  %s %d kbit/s' % (a.http, a.host_ip, a.media_port, a.media_port + MEDIA_PORTS - 1, a.advertise, a.codec, a.kbps), flush=True)
    serve(a, [x for x in sys.argv[1:] if x != '--worker'])


if __name__ == '__main__':
    main()
