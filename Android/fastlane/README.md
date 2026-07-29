# Android Play Store release + screenshots

Google Play automation for the Folino Android app: the `release` lane ships the binary, the rest of
the lanes maintain the store listing. The marketing screenshots are modeled on the VocalTuner
pipeline (scene → marketing frame → fastlane supply); capture runs as an instrumented test on an
emulator because the Reader renders sheet music via native JNI (cannot run on the host JVM).

## Shipping a release

```sh
export PLAY_PACKAGE_NAME=com.harmolo.folino
export PLAY_JSON_KEY_PATH=~/.android-keystores/harmolo-play-publishing-<id>.json

PLAY_VALIDATE_ONLY=1 bundle exec fastlane android release   # dry run — nothing reaches Play
bundle exec fastlane android release                        # build + upload to production
```

Before running it:

1. **Bump `versionName`** in `app/build.gradle.kts`. `versionCode` needs no edit — it is the git
   commit count, so it rises on its own.
2. **Write the release notes** as `metadata/android/<locale>/changelogs/<versionCode>.txt` for all
   five locales. The lane refuses to build if any locale is missing that file. `<versionCode>` is
   the commit count *after* the release commit lands — commit first, then `git rev-list --count HEAD`
   to confirm the filename matches (amend rather than adding a commit if it drifted).
3. **Rebuild the native libraries** — from the repo root, `Scripts/android-build-libs.sh` (Settings)
   plus `android-build-{library,reader,soundfont}-libs.sh` — and re-`publishToMavenLocal`
   swift-sheet-music, so the AAB carries the current engine rather than whatever `.so` was staged last.
4. **Run the crash gate** — `Scripts/android-release-check.sh` plus the instrumented smoke tests.

Knobs: `PLAY_TRACK=internal` to stage elsewhere, `PLAY_ROLLOUT=0.1` for a staged rollout,
`PLAY_SKIP_BUILD=1` to upload the AAB already on disk. The lane never touches listing text, images,
or screenshots — only the binary and the release notes.

## What it produces

6 scenes × 5 locales (`en-US`, `ja-JP`, `ko-KR`, `zh-CN`, `zh-TW`) × 2 devices (phone, 10" tablet)
= **60 PNGs**, each wrapped in a device frame with a localized title/subtitle.

In addition, `collectScreenshots` emits the store icon per run:

- **`images/icon.png`** — one 512×512 full-bleed store icon (same file for every locale).
  `upload_listing` uploads it as part of the store listing.

The **feature graphic** (`images/featureGraphic.png`, one 1024×500 per locale) has its own pipeline —
see **Feature graphic** below — because it is rendered at 2× in a landscape window and downsampled
(supersampling, for fine staff lines), which the portrait screenshot run cannot do.

> **Icon upload note:** the Play Developer API can reject icon updates with a validation error.
> Always run `PLAY_VALIDATE_ONLY=1` first to check for rejections before committing the change.
> If the API rejects the icon, upload `icon.png` manually via the Play Console — that path bypasses
> the API validator.

| order | scene | shows |
| --- | --- | --- |
| 10 | Reader + cursor | score open, playback cursor in measure 1, floating play FAB (seek bar hidden) |
| 20 | Display inspector + hidden staves | inspector open, staves 2/3/4 hidden |
| 30 | Whole-piece repeat | playback inspector General section, repeat set to "Repeat one" |
| 40 | AB-section repeat | horizontal layout, accent band + A/B flags over measures 5–7 |
| 50 | Library | library top with three mock scores |
| 60 | PiP-style | faux home screen + floating PiP card (only staves 2/3/4) |

## Generate

Prerequisites: a booted emulator (a large-display AVD such as `Pixel_6_Pro_API_36` avoids clipping
the tablet canvas) and the staged native libs (already present in a normal checkout).

```sh
# from Android/ — target the emulator explicitly if a physical device is also connected
ANDROID_SERIAL=emulator-5554 ./gradlew :app:collectScreenshots
```

This runs the `connectedDebugAndroidTest` capture and copies the PNGs into
`fastlane/metadata/android/<locale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png`, plus
`icon.png` under `fastlane/metadata/android/<locale>/images/`. (The feature graphic is generated
separately — see **Feature graphic**.)

The generated PNGs are git-ignored (`fastlane/.gitignore`); regenerate them rather than committing.

## Feature graphic

The Play Store feature graphic (1024×500, one per locale) is generated separately from the screenshots,
by **supersampling**: `FeatureGraphicTest` renders it at a true 2× (2048×1000) in a wide (landscape)
emulator window, then the script downsamples to the exact 1024×500 with a high-quality filter so the
in-frame staff lines stay fine (a direct 1024 render in the small frame leaves the lines heavy).

```sh
# from the repo root — needs a booted emulator-5554
Scripts/render-feature-graphic.sh
```

It sets a wide display via `wm size`, runs only `FeatureGraphicTest` with `fgScale=2`, restores the
display, downsamples each locale into `fastlane/metadata/android/<locale>/images/featureGraphic.png`,
and also drops the ja render at full 2× on the Desktop for SNS use. The composition (the folino wordmark
logo + localized tagline on the left, the Reader score with the Top/2nd/3rd staves hidden in a device
card on the right) lives in `FeatureGraphic.kt`; the logo asset is (re)generated from the iOS icon's
title layer by `Scripts/extract-wordmark.swift`.

## Upload (manual)

```sh
export PLAY_PACKAGE_NAME=com.harmolo.folino
export PLAY_JSON_KEY_PATH=/path/to/play-service-account.json

# Screenshots only (no metadata or changelogs)
PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_screenshots   # dry run
bundle exec fastlane android upload_screenshots                        # real upload

# Feature graphic only — no icon/text/screenshots (safest for a listing-image refresh; the icon is left
# untouched because icon updates can be rejected). Defaults to the production track; set PLAY_VERSION_CODE
# when the track has more than one release.
PLAY_VALIDATE_ONLY=1 PLAY_VERSION_CODE=<code> bundle exec fastlane android upload_feature_graphic  # dry run
PLAY_VERSION_CODE=<code> bundle exec fastlane android upload_feature_graphic                       # real upload

# Full listing: title/description + feature graphic + icon + screenshots (no binary)
PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_listing       # dry run first (catches icon rejections)
bundle exec fastlane android upload_listing                            # real upload
```

Images only — no binary, metadata, or changelogs are touched by `upload_screenshots`. `upload_listing`
also pushes text metadata, feature graphics, and the store icon.
