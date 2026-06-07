# assets

Icon sources and their compiled fallbacks.

## `icons/`

Loose [Icon Composer](https://developer.apple.com/icon-composer/) sources, one
`<name>.icon` directory per icon (`icon.json` + the loose image layers). The build
script's `ICON_NAME` (default `dragon-plus`) selects one — `dragon-plus` ↔
`icons/dragon-plus.icon` — and runs `actool` on it to produce `Assets.car` (the macOS 26
"Tahoe" app icon) plus a `dragon-plus.icns` for older macOS, pointing `Info.plist`'s
`CFBundleIconName` / `CFBundleIconFile` at it. The directory basename **is** the icon name.

- **`dragon-plus.icon`** — the **"dragon-plus"** icon.

## `prebuilt/`

Committed copies of the compiled artifacts (`Assets.car` + `dragon-plus.icns`) used as a
**fallback**: `actool` ships only with full Xcode (not the Command Line Tools), so on a
machine without it the build can't compile the loose source — it copies these in instead.
When `actool` *is* present the build prefers a fresh compile and ignores these.

They aren't regenerated on every build (actool's output isn't byte-identical run to run,
which would needlessly churn git). Refresh them deliberately after changing the icon:

```sh
UPDATE_PREBUILT=1 ./emacs-launcher-build.sh
```

## Credits

The `dragon-plus.icon` icon is the **"dragon-plus"** icon from
[d12frosted/homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus)
(`community/icons/dragon-plus`), redistributed here as its loose Icon Composer source.
All rights to the artwork remain with the original authors; see the emacs-plus repository
for licensing and attribution.

The build-time approach of compiling a loose `.icon` into `Assets.car` with `actool`
follows emacs-plus's
[`scripts/generate-tahoe-assets`](https://github.com/d12frosted/homebrew-emacs-plus/blob/master/scripts/generate-tahoe-assets).
