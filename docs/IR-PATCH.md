# The IR patch (Tama-to-Tama links)

Two protocols together make the IR patch. Both run in `ios/TamaiOS/Core/IRLink.swift`. The other device is a
headless copy of its save, woken and driven with key presses; infrared frames are bridged between the two.

## PLAYDATE / GIFT / MARRY
- The Tama you play reaches the WAITING screen; the app prepares the partner on the matching screen
  (`C×4, A×5, B, B, A×mode`, then the mode's tail: GIFT needs GIVE/RECEIVE on the other side).
- The app presses B on the toy you play until traffic starts. Nothing else is needed.

## TRAVEL (INVITE / VISIT)
- Only the Tama you play INVITEs. The partner always picks VISIT (`... A×3, B, B`).
  (If you VISIT from the played Tama, the app presses C once and backs out; VISIT there leaves it "out".)
- An INVITE starts by itself ONLY if the partner is already waiting on VISIT with the link active when CONNECTING
  begins. The app cannot have that (you choose the place first), so once the partner is ready it restarts the
  invitation: C (back to the place list), wait 1.1 s, B (same place). Then the exchange runs with no further B.
- Without the restart the toy sends its first frames to nobody, then stalls; B does not recover it.
- During the restart the screen is held on the CONNECTING picture and the toy's audio is muted; both are released
  when the exchange is under way (or after 5 s).
- A/B presses are dropped while the link is being set up (queued ones used to fire all at once).
- Partner INVITE (if ever needed again): `B, A, B, A×place, B`, trying places in random order (locked ones refuse).

## Disabled entries (silent back-out)
- Travel › VISIT on the played Tama: C once, muted, no pop-up.
- Connection › DOWNLOAD (middle entry of TAMAGOTCHI / DOWNLOAD / APP): it is only for receiving gifts, so the app
  detects it (Connection menu cursor byte 0xF80178FC == 1, same address on all ROMs; 0 for every Tamagotchi mode),
  presses C once, muted, no pop-up, no link. Connection › App › Download is a different flow and is untouched.

## Shared
- Daytime Mode is one global setting; every device's save is changed when it is toggled, and each device is put on
  the selected clock when opened.
- Frame bridge: `tg_ir_link`, `tg_ir_take`, `tg_ir_deliver`. Partner is ticked from the start.
