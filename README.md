# TamaiOS

TamaiOS is an unofficial iPhone app that runs a **Tamagotchi ON / Tamagotchi Meets** (the "tg18" hardware) as a software emulator. You get a virtual copy of the toy on your phone: the same screen, the same three buttons, the same menus, the same pet. It is a hobby project made by one person for personal use and for learning.

It is not affiliated with, endorsed by, or connected to Bandai or the Tamagotchi brand. "Tamagotchi" is a trademark of Bandai.

## What it does

- **Runs the real toy firmware.** The app does not reimplement the game. It emulates the toy's ARM processor, memory and screen, and runs the firmware dumped from a real device, so the pet behaves like the real thing.
- **Several devices at once.** You can keep up to 6 saved devices (for example Fairy, Magic and Wonder Garden) and switch between them. Only the device you are looking at runs and notifies you; the others are paused and their clocks are kept correct for you.
- **Real names and sprites.** Each saved device shows its Tama's actual name and picture, read from the device itself, so you see "Billytchi" rather than a device label.
- **Playdates, gifts and marriage.** These use the toy's own menus. The app plays the part of the other toy over the emulated infrared link, waking another saved device in the background when it is needed.
- **Tamatown / TamaDepa.** Browse and send items and characters from the MyMeets and WebMeets collections to your Tama using the same download protocol the real toy uses.
- **Saves you can trust.** Flash and state are saved and validated against the firmware they came from, so a bad save never gets loaded into the wrong ROM.

## How it works (the honest version)

| Part | What it is |
|---|---|
| `ios/` | The app itself: SwiftUI screens, the device view, settings, Tamatown, and the glue that talks to the emulator. Built with XcodeGen. |
| `ffi/` | A small Rust layer that wraps the emulator core and exposes a C interface to Swift. It also holds the MyMeets (`mm.rs`) packet code. |
| `patches/` | Changes applied on top of the open-source emulator [oreo-fox/tg18-emu](https://github.com/oreo-fox/tg18-emu) (pinned to one exact commit) at build time: `radio.patch` adds Bluetooth/radio support, `ir_partner.patch` adds the infrared "other toy" behaviour. |
| `tools/` | Scripts that draw the app icon and the Tamatown background during the build. |
| `.github/workflows/build.yml` | The only build system. It builds the Rust library, bundles the firmware, and produces an **unsigned IPA**. |

Names, sprites and the clock are obtained by looking at the running toy: reading identity values from its memory, and reading the profile screen with on-device text recognition (Apple Vision). There is no cloud service and no account; nothing leaves your phone.

## What is not included

- **No firmware or game data is in this repository.** The firmware is Bandai's copyrighted software. The author builds the app with firmware dumped from toys they own, kept privately. If you build it yourself you need your own dump (an 8 MB flash read from your own Tamagotchi ON or Meets).
- **The MyMeets / WebMeets item pack** is third-party data and is also not distributed here.

If a build has no firmware bundled, the app opens a welcome screen that asks you to choose your own ROM file (`.bin`, or a `.zip` containing one). Builds that include firmware skip that and show a device picker, with a small "Use my own ROM file…" link.

## Building it

There is no Mac required. Everything is built by GitHub Actions on a macOS runner.

1. Provide your firmware and assets:
   - either put `fw_tg18_en_v057_2019-05-13_fairy.bin`, `fw_tg18_en_v058_2019-05-13_magic.bin`, `fw_tg18_en_v063_2020-02-13_wondergarden.bin` in `firmware/` (and optionally `MyMeets2_3_7.zip` in `assets/`) in your own **private** fork,
   - or keep them in a separate private repository and give the workflow read access through a `PRIVATE_REPO_TOKEN` secret (the workflow expects `firmware/` and `assets/` folders there).
   - or build without any, and import a ROM inside the app.
2. Open the **Actions** tab, run **Build TamaiOS IPA**, wait roughly 10–20 minutes.
3. Download the `TamaiOS-ipa` artifact and sideload it with a tool such as FlareStore, AltStore or SideStore. The IPA is intentionally unsigned; your sideloading tool signs it.

## Known limits

- Only 2 "Places" can be viewed on a toy at a time. That limit is in the firmware itself, and the app keeps the stock behaviour.
- At most 6 saved devices, to keep playback smooth.
- Name and sprite reading depends on text recognition, so unusual names can occasionally be misread; it re-checks after growth and other changes.
- Some link features (gifts and marriage on non-Wonder-Garden ROMs, for instance) have had less testing than others.

## Credits

- [oreo-fox/tg18-emu](https://github.com/oreo-fox/tg18-emu) for the emulator core this is built on.
- The Tamagotchi community's MyMeets / WebMeets / TamaDepa work for the item and download formats.

## Status

A personal project, shared openly so others can see how it works. It comes with no warranty and no support promise.
