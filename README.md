# TamaiOS

iOS app that emulates Tamagotchi ON / Meets (tg18).

The source is now normal files instead of being generated inside a GitHub Action.

## Project layout

```
.
├── .github/workflows/build.yml   # Clean CI that builds an unsigned IPA
├── ffi/                          # Rust FFI layer (static library)
├── ios/                          # SwiftUI app + project.yml (XcodeGen)
├── patches/radio.patch           # Bluetooth patch applied to upstream core
├── tools/                        # Helper scripts
├── firmware/                     # Put the three .bin firmware dumps here
└── assets/                       # Put MyMeets2_3_7.zip here
```

## Fool-proof setup to get an IPA from GitHub Actions

### 1. Put the required files in the repo

Create these two folders and add the files (use Git LFS for the big binaries):

```bash
mkdir -p firmware assets

# Copy your three firmware dumps into firmware/
# (the names the original workflow expected)
# fw_tg18_en_v057_2019-05-13_fairy.bin
# fw_tg18_en_v058_2019-05-13_magic.bin
# fw_tg18_en_v063_2020-02-13_wondergarden.bin

# Copy the MyMeets ZIP into assets/
# assets/MyMeets2_3_7.zip
```

If the files are large, track them with Git LFS:

```bash
git lfs install
git lfs track "firmware/*.bin" "assets/*.zip"
git add .gitattributes
```

### 2. Commit the extracted source

```bash
# From the root of your repo
cp -R TamaiOS-extracted/* .
# or just move the contents of TamaiOS-extracted into the repo root
git add .
git commit -m "Extract real source and add clean build workflow"
git push
```

### 3. Run the Action

1. Go to the **Actions** tab on GitHub.
2. Select **Build TamaiOS IPA**.
3. Click **Run workflow**.
4. Wait for it to finish (usually 10–20 minutes).
5. Download the **TamaiOS-ipa** artifact. That is your unsigned IPA.

### 4. Install the IPA

You can sideload it with AltStore, SideStore, or any other unsigned IPA installer.

## Local build (optional)

```bash
# 1. Get the upstream core and patch it
git clone https://github.com/oreo-fox/tg18-emu upstream
git -C upstream checkout 41204c92e98a8882d5c90a9876d8990f3b63e285
git -C upstream apply patches/radio.patch

# 2. Build the Rust library
rustup target add aarch64-apple-ios
cd ffi
IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build --release --target aarch64-apple-ios
mkdir -p ../ios/lib
cp target/aarch64-apple-ios/release/libtamaios.a ../ios/lib/

# 3. Generate and build
cd ../ios
brew install xcodegen   # if needed
xcodegen generate
xcodebuild -project TamaiOS.xcodeproj -scheme TamaiOS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

## Notes

- Code signing is intentionally disabled. The IPA is unsigned.
- The workflow pins the exact upstream commit that was used originally.
- Firmware and MyMeets assets are copied into the app bundle at build time if present.
