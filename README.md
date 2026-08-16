<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/kalymma-wordmark-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/kalymma-wordmark-on-light.svg">
        <img alt="kalymma" src="assets/kalymma-wordmark-on-light.svg" width="300">
    </picture>
</p>

&nbsp;

<p align="center">
    A screen overlay library for Windows and Linux, giving an application a fixed-size ARGB surface anchored to a screen edge.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/kalymma/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/kalymma/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.16.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

The caller owns the pixels and kalymma owns the window. A surface hands back a `[]u32` of
ARGB, and the library places it, keeps it above everything, and turns the platform's input
into a flat event list.

## Features

- **Three backends**: The Linux path speaks Wayland when `WAYLAND_DISPLAY` is set and X11
  otherwise, the Windows path uses a layered window, and a mock backend stands in under
  `-Dbackend=mock`.
- **No client libraries**: The two Linux protocols are written here, wire format and all,
  so nothing links against libwayland or libX11. The Windows build links only `gdi32`,
  `kernel32`, and `user32`.
- **Fixed bounds**: A surface is at most 512 by 320 at a scale of 2, there are at most 2
  of them, and the event list holds 64 entries with a drop counter behind it.
- **Anchored placement**: A surface sits at the bottom right, the top right, or the
  centre, with a margin the caller sets.
- **Input**: The events are pointer move, down, up, and leave, a key down from a small key
  set, and focus lost. A caller reads them through `poll` or a callback.

## Install

The library ships as a Zig package holding one module, also named `kalymma`. Fetch it into
your own project and import the module in your `build.zig`.

```
zig fetch --save git+https://github.com/braycarlson/kalymma
```

```zig
const kalymma = b.dependency("kalymma", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("kalymma", kalymma.module("kalymma"));
```

kalymma requires Zig 0.16.0.

## Usage

A runtime opens once, a surface is created against it, and the frame is written and
presented. The handle is a value, so nothing has to be freed beyond the destroy and close
the example pairs with each acquisition.

```zig
const std = @import("std");

const kalymma = @import("kalymma");

const frames_max: u32 = 600;

pub fn main() !void {
    try kalymma.runtime.open(.{ .name = "overlay" });
    defer kalymma.runtime.close();

    const handle = try kalymma.surface.create(.{
        .anchor = .top_right,
        .height = 64,
        .margin = 16,
        .name = "status",
        .width = 256,
    });
    defer kalymma.surface.destroy(handle);

    @memset(kalymma.surface.frame(handle), 0xFF102030);

    try kalymma.surface.present(handle);
    try kalymma.surface.show(handle);

    var list = kalymma.EventList.init();
    var frame_index: u32 = 0;

    while (frame_index < frames_max) : (frame_index += 1) {
        const count = kalymma.events.poll(&list);

        for (list.items[0..count]) |event| {
            if (event.input == .key_down) return;
        }
    }
}
```

The `frame` call returns the pixels for the current scale, so a surface on a scaled
display hands back a larger buffer than the logical width and height ask for.

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, and each available suite. |
| `just test` | Each available suite and the formatting check. |
| `just mock` | The full pipeline against the mock backend. |
| `just linux` | The display tests, on a Linux host with a session. |
| `just tidy` | The tidy law on its own. |
| `just check-windows` | The compile of every artifact for Windows from any host. |

## Licence

MIT. See [LICENSE](LICENSE).
