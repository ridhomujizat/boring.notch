# Install & Run boringNotch Locally

Cara build DMG lokal (tanpa Developer ID / notarization) dan bikin app jalan terus.
Untuk dipakai di Mac sendiri — bukan untuk distribusi.

## Prasyarat

- Xcode terpasang di `/Applications/Xcode.app` (bukan cuma Command Line Tools).
- Python 3 (buat `dmgbuild`).

## 1. Build & archive (ad-hoc signed)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild clean archive \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -archivePath /tmp/boringNotch \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

`ONLY_ACTIVE_ARCH=NO` = universal (arm64 + x86_64). Pakai `YES` kalau cuma buat arch Mac ini (lebih cepat).

## 2. Ambil .app dari archive

```bash
cp -R /tmp/boringNotch.xcarchive/Products/Applications/boringNotch.app Release/boringNotch.app
```

## 3. Re-sign seluruh bundle ad-hoc (WAJIB)

Framework bawaan (MediaRemoteAdapter, dll) punya Team ID beda dari main app yang
di-sign `-`. dyld nolak framework beda Team ID → app crash saat launch
("Library not loaded ... different Team IDs"). Re-sign semua ad-hoc biar konsisten:

```bash
APP=Release/boringNotch.app
find "$APP/Contents/Frameworks" "$APP/Contents/XPCServices" \
  \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \) -prune -print |
  while read -r item; do codesign --force --sign - --timestamp=none "$item"; done
codesign --force --deep --sign - --timestamp=none "$APP"
codesign -v "$APP"   # harus: valid on disk
```

## 4. Bikin DMG

```bash
python3 -m venv /tmp/dmgvenv && source /tmp/dmgvenv/bin/activate
python3 -m pip install --require-hashes -r Configuration/dmg/requirements.txt
./Configuration/dmg/create_dmg.sh Release/boringNotch.app Release/boringNotch.dmg boringNotch
```

Hasil: `Release/boringNotch.dmg`.

## 5. Install

Buka DMG, drag **boringNotch** ke Applications.

## 6. Lolos Gatekeeper (ad-hoc, belum notarized)

```bash
xattr -dr com.apple.quarantine /Applications/boringNotch.app
open /Applications/boringNotch.app
```

App ini menu-bar / notch — ga punya window utama.

## 7. Jalan terus + auto-start tiap login

Toggle bawaan app:

> **boringNotch → Settings → General → "Launch at login"**

Atau daftar login item manual:

```bash
osascript -e 'tell application "System Events" to make login item at end \
  with properties {path:"/Applications/boringNotch.app", hidden:false}'
```

## Bersihkan build files

```bash
rm -rf build-release /tmp/boringNotch.xcarchive Release/boringNotch.app /tmp/dmgvenv
rm -rf ~/Library/Developer/Xcode/DerivedData/boringNotch-*
```

DMG (`Release/boringNotch.dmg`) tetap disimpan.

---

**Catatan:** DMG ini ad-hoc signed, cuma jalan di Mac yang jalanin re-sign di step 3.
Buat distribusi ke Mac lain butuh Developer ID signing + notarization (lihat `.github/workflows/build_reusable.yml`).
