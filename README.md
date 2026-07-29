# tc4mac iPhone plugin (file system sample)

A [tc4mac](https://tc4mac.com) file system plugin: a connected iPhone or iPad
appears as a browsable location, and its photos and videos copy out with F5
like any other files.

## Build and install

```
./make-plugin.sh
```

Then **Configuration ▸ Plugins ▸ Install…** in tc4mac, and switch it on.
Plug in a device, unlock it, and trust this Mac if asked.

## Scope, stated plainly

This reaches the device through **ImageCaptureCore** — the framework Image
Capture and Photos use — which means the camera roll: photos and videos.

There is no general file system access to an iPhone on macOS. Doing more
means talking to `usbmuxd` through libimobiledevice, which is a substantial
dependency and a maintenance burden a sample should not carry. So the plugin
declares no write capability at all, and tc4mac disables the commands it
cannot honour rather than offering them and failing.

That is the lesson worth taking: **declare what you can actually do.**

## What to look at

- `DeviceTree.swift` — the namespace, and the path rules. Pure, so the layout
  is tested without hardware plugged in.
- `ImageCaptureSource.swift` — the real transport.
- `main.swift` — the plugin process, the same shape as every other sample.

The namespace is one level per device: `/<device>/<folder>/<file>`. A camera
reports a flat list of files, so the folders the panel walks are derived from
each file's parent — the same job the MHT sample does for archive entries.

Reads are chunked, because a video is not something to put in one message.

## Licence

MIT. See `LICENSE`.
