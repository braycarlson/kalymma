# kalymma

A screen overlay library for Windows and Linux. The library gives an application a fixed-size ARGB pixel surface anchored to a corner or the center of the screen, along with pointer and keyboard input, and leaves the caller to own the pixels while the library owns the window. A shade is a second kind of overlay: a rectangle of one ARGB color at any position on the desktop that the pointer passes through, or that takes the pointer and keyboard while the caller draws a selection. An interactive shade shows the pointer cursor the caller picks, from the arrow and the crosshair to the move and resize cursors, and the caller can change it at any time; on X11 the cursor comes from the desktop's cursor theme. A tint blends every monitor toward one ARGB color through the Windows magnifier, so it also covers the Start menu and the taskbar, which the shell raises above every overlay while Start is open. The monitor list carries each display's name, its rectangle, and whether it is the primary display, and a change in the layout arrives as an event. The primary flag comes from RandR on X11 and from `GetMonitorInfo` on Windows, and it stays false on the Wayland layer shell because no public protocol names a primary output. The Linux backend speaks the Wayland layer shell and X11 directly with no system libraries, and a fake backend runs an overlay under test with no display.

## Usage

A `kalymma.Runtime` owns the overlays of one program, and the `-Dtarget` of the build alone picks its backend. The caller places it, `init` opens it in place, and `deinit` closes it and releases each surface and shade still open:

```zig
var runtime: kalymma.Runtime = undefined;

try runtime.init(.{});
defer runtime.deinit();

const status = try runtime.surface_create(.{ .height = 64, .name = "status", .width = 256 });
defer runtime.surface_destroy(status);

@memset(runtime.surface_frame(status), 0xFF102030);

try runtime.surface_show(status);
try runtime.surface_present(status);
```

The runtime holds about 1.4 MB of frame and display state, so it lives where the caller puts it, on the stack of `main` or behind an allocation. The backend's thread keeps the address `init` saw, so the runtime never moves or gets copied between `init` and `deinit`. The callback passed to `events_subscribe` runs on that thread, so it only wakes the caller, which drains the events with `events_poll` on its own thread. A surface or shade handle is valid only against the runtime that issued it, and only until `deinit`.

A runtime built as `kalymma.RuntimeType(kalymma.Fake)` runs the same calls against an in-memory fake on any host. The fake counts each call, fails the call named by `runtime.platform.fault.arm(.surface_show)` or by the `.fault` init option, and takes injected input through `runtime.platform.inject`. The programs in `examples/` draw an overlay and a shade the pointer drags out.
