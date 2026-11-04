# The IR patch (Tama-to-Tama links)

How two emulated Tamagotchi ON toys talk to each other, and why the app drives them the way it does.
Code: `ios/TamaiOS/Core/IRLink.swift` (host side), `patches/ir_partner.patch` and `ffi/src/lib.rs` (emulator side).

## 1. How the communication works

### Physical layer
The toy's IR port is a UART behind an IrDA SIR transceiver. The firmware selects the serial speed by writing
`0x341` to the register at `0xC006000C` (the discovery speed, 9600 baud) and enables the transceiver through GPIO
`0xC0000025` bit 7 (active low). The app treats "baud = 0x341 and transceiver on" as *the toy is on an IR screen*
(`IRLink.waiting`). The baud setting persists after leaving the screen and in saves, so the transceiver bit is
required too. Note that it is also true on the FAIL screen.

### Framing
Frames are standard SIR: `C0 C0 C0 C0` start flags (extra BOFs), body, FCS-16 (CRC-16/X.25, little-endian),
`C1` end flag, with `C0`, `C1` and `7D` byte-stuffed as `7D, byte ^ 0x20`.

### Protocol stack
The firmware implements a subset of IrDA:

- **IrLAP**: device discovery with broadcast XID frames (address `0xFF`, 6 slots), connection setup with SNRM/UA
  carrying the negotiated QoS (9600 baud, 500 ms turnaround, 512-byte frames, window 1), I/RR supervisory frames
  with 3-bit sequence numbers, orderly close with DISC/UA. Link speed is renegotiated during a connection, so the
  baud register cannot be used to tell whether a link is still alive.
- **IrLMP**: LSAP multiplexing. The toy's OBEX server listens on LSAP 3; IAS (the attribute database) is queried to
  find it.
- **IrOBEX**: PUT/GET of named objects. The toy exchanges character/item data as files (e.g. `put2.jpg`,
  `get2.jpg`); this is also how the Tamatown partner in `ir_partner.patch` serves bag items and characters.

### Toy-to-toy bridge
Each emulator instance has an IR context (`IrCtx`). With `tg_ir_link(h, 1)` the toy's transmitted frames are no
longer routed to the built-in Tamatown partner but queued in an outbox as `address, control, data` (no FCS, no
framing). The host loop (`IRLink.run`) then, every few milliseconds:

1. `tg_ir_take` on the partner → frames for the toy you play,
2. `tg_ir_deliver` them into the played toy (the receiver sees them 2 ms of *toy* time later, rebuilt with
   framing and FCS), and `tg_ir_take` whatever the played toy sent,
3. `tg_ir_deliver` those into the partner.

Both machines are ticked by the host, so the two toys stay in lock-step; the partner is a headless copy of its save,
woken from sleep and driven with key presses.

### Which side does what
Roles are decided by the firmware menus, not by the bridge: the toy that starts the connection sends the discovery
XIDs and is the IrLAP primary; the other answers. The host only chooses what each side's menus are set to.

- **PLAYDATE / GIFT / MARRY**: partner is placed on the matching WAITING screen by keys
  (`C×4, A×5, B, B, A×mode`, plus GIVE/RECEIVE for GIFT). Mode is in RAM `0xF80178E4`
  (0 PLAYDATE, 1 GIFT, 2 MARRY, 3 TRAVEL); gift role at `0xF80178BC`. The played toy is nudged with B until traffic
  starts.
- **TRAVEL**: the INVITE side runs the primary; the VISIT side answers. Travel role at `0xF80178C4`
  (0 VISIT, 1 INVITE).

## 2. Why the workarounds exist

### Travel: the invitation is restarted
Observed behavior: an INVITE only connects by itself if the partner is *already* listening on its VISIT screen with
the link active at the moment the played toy's CONNECTING screen begins. Otherwise the INVITER sends its discovery
frames into nothing and stalls, and pressing B does not recover it. The app cannot satisfy this ordering naturally:
you choose the place first, and only then can the partner be prepared. So after the partner is ready the app backs out
and re-enters the same place: `C` (to the place list), wait 1.1 s while ticking the partner, `B` (same place). From
that point the exchange runs with no further input. (The cause is inferred from traces, not from disassembly.)

To hide the restart the screen is held on the CONNECTING picture and audio is muted, and both are released when the
live frame matches the held one (or after 2.5 s), so it looks like a paused video resuming.

### Travel: only the Tama you play INVITEs
If the played Tama chooses VISIT, the firmware ends up in a state where it is "out" with no way to receive the
visitor, and the app cannot complete the exchange. The partner always has the other role instead (it picks VISIT
automatically). Choosing VISIT on the played Tama is therefore a silent back-out: `C` once, muted, no pop-up, so it
looks as if the button did nothing. (A partner-side INVITE, `B, A, B, A×place, B`, still exists in the code but is
unreachable.)

### Connection › DOWNLOAD is blocked on the played Tama
The middle entry of the Connection menu (TAMAGOTCHI / DOWNLOAD / APP) puts the toy on the same IR screen, but only
for receiving something from a Tama-to-Tama link, which the app does not provide. It would sit there until FAIL, so
it is detected (Connection menu cursor at `0xF80178FC` == 1; 0 for all four Tamagotchi modes, same address on all
ROMs) and backed out silently like VISIT. Connection › App › Download is a different flow (Tamatown, TamaDepa) and is
not touched.

### Input is dropped while a link is being set up
Buttons pressed during setup used to queue up and then all fire at once, ruining the key sequence. While the link
is frozen (`linkFreezeUntil`) A and B are dropped; C is kept so you can always back out.

### Why the app keeps action on the Tama you play
The played toy is the one with a real screen, audio and your input; the partner is a headless copy. Roles that need
a human decision (choosing a place, GIVE/RECEIVE) are made by the app on the headless side, and anything that
would leave the visible toy in an unrecoverable menu state is blocked rather than handled. Also, a device that is
away (in Travel) cannot be used as a partner.

### Other timing aids
- The B press that starts PLAYDATE/GIFT/MARRY goes straight into the core (not through the button queue) and is held
  about 0.35 s, repeated every 1.5 s until traffic starts (max 14 tries). A B on the CONNECTING screen itself is
  harmless.
- The link ends after 8 s of silence once data has flowed (the baud register is not reliable then), after 20 s off
  the IR screen before any traffic, and never later than 600 s.
- Frames are bridged with the partner ticked from the start of the link for Travel.

## 3. Related global behavior
- Daytime Mode is one global setting; every device's save (including those in the background) is changed when it
  is toggled, and each device is put on the selected clock when opened.
