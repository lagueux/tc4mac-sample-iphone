# tc4mac iPhone plugin (file system sample)

A [tc4mac](https://tc4mac.com) file system plugin: a connected iPhone or iPad
appears as a browsable location — photos, videos, Downloads, Books,
recordings — and its files copy out with F5 like any other files.

## Build and install

On the build Mac (only there):

```
brew install libimobiledevice
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-plugin.sh
```

`make-plugin.sh` copies the three libimobiledevice tools the plugin runs
(`afcclient`, `idevice_id`, `ideviceinfo`) and every library they load into the
bundle, rewires them to find each other there, and signs every piece — so the
finished `iPhone.tcplugin` runs on a Mac **without Homebrew**. Their licences
travel in `Contents/Resources/ThirdPartyLicenses` (LGPL-2.1 for
libimobiledevice and its companions, Apache-2.0 for OpenSSL; unmodified
upstream builds, source at libimobiledevice.org and openssl.org).

Then **tc4mac ▸ Plugins… ▸ Install…**, and switch it on. Plug in the device;
it browses while locked once it has trusted this Mac in Finder.

## How it reaches the device

Through **AFC**, the file protocol the device speaks on the cable, by driving
the libimobiledevice tools as subprocesses — the same pattern tc4mac's SFTP
backend uses with the system's OpenSSH. A directory lists in ~0.2 s, on
demand, and the whole media tree browses.

(An earlier version used ImageCaptureCore. That is a camera-IMPORT API: it had
to enumerate the entire camera roll before anything browsed, which took minutes
and read as broken.)

The plugin declares no write capability, and tc4mac disables the commands it
cannot honour rather than offering them and failing. That is the lesson worth
taking: **declare what you can actually do.**

## What to look at

- `DeviceTree.swift` — the namespace and the path rules. Pure, so the layout is
  tested without hardware plugged in.
- `AFCSource.swift` — the transport: tools found beside the plugin first, then
  Homebrew during development.
- `main.swift` — the plugin process. File reads follow plugin SDK 2: tc4mac
  pulls each chunk only when it has room (`fs.openRead` / `fs.readChunk` /
  `fs.closeRead`), and the file is served from a temporary download on disk,
  so neither process ever holds a large video in memory.

## Licence

MIT. See `LICENSE`. The bundled third-party tools keep their own licences —
see `Contents/Resources/ThirdPartyLicenses` in a built bundle.
