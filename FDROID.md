# The F-Droid build (`fdroid` branch)

`main` is the app as released on GitHub and IzzyOnDroid. This branch is the
same app made to fit F-Droid's rules, and only differs where it must:

| | `main` | `fdroid` |
|---|---|---|
| Location | `geolocator` (Google's fused provider) | `packages/geolocator`: same Dart API on Android's own LocationManager (GPS, network fixes only while GPS is silent), own foreground service |
| Map | `maplibre_gl` from pub.dev | `packages/maplibre_gl`: the same version without its Google location engine (the app draws its own position) |
| Line geometry | bundled in the APK, refreshed daily | not bundled (derived from GTT's non-commercial data): downloaded on first launch, refreshed daily |
| Updates | in-app check of GitHub releases | off: F-Droid delivers them |
| Release signing | the release key | unsigned without a keystore: F-Droid signs |

Everything else (routing, live trip, UI) is the same code.

## Keeping it in step

    git checkout fdroid
    git merge main          # conflicts, if any, are in the files above
    flutter pub get && flutter analyze && flutter test

Tag a release for F-Droid as `fdroid-v<version>` on this branch; the recipe
in `metadata/com.piedemove.piedemove.yml` builds that tag.

## Known differences in use

GPS-only location can take longer for a first fix indoors and is less smooth
in narrow streets than Google's fused provider; the live trip already treats
poor fixes as estimates. Compare with the main build on real rides (Impostazioni
-> Segnala un problema keeps the trip log of both).
