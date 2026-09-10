# android-mode

Android project helpers for Emacs.

`android-mode` provides commands for common Android development tasks:

- selecting Gradle modules and variants from project flavor data
- building, installing, uninstalling, testing, and running Android apps
- launching an emulator
- creating and managing Android Virtual Devices with a Transient menu
- mirroring and controlling Android devices with a scrcpy Transient menu
- starting the currently built application on a connected device

## Installation

With `use-package` and `package-vc`:

```elisp
(use-package android-mode
  :vc (:url "https://github.com/cat-emacs/android-mode")
  :commands #'android-root)
```

From a local checkout:

```elisp
(add-to-list 'load-path "/path/to/android-mode")
(require 'android-mode)
```

## Commands

- `M-x android-gradle-build`
- `M-x android-gradle-clean`
- `M-x android-gradle-install`
- `M-x android-gradle-uninstall`
- `M-x android-gradle-test`
- `M-x android-run`
- `M-x android-start-app`
- `M-x android-avd-start`
- `M-x android-avd-install-system-image`
- `M-x android-avd`
- `M-x android-scrcpy`
- `M-x android-scrcpy-start`
- `M-x android-print-flavor`
- `M-x android-refresh-flavors`

`android-avd` opens a Transient menu with actions for listing, creating,
deleting, starting, stopping, and wiping data for Android Virtual Devices. It
can also download system images that are not installed. The create command
lists both installed and downloadable images; selecting a downloadable image
installs it asynchronously before creating the AVD. Installation output is
shown in `*android-system-image-install*`.

System image management prefers the current `android sdk` command and falls
back to `sdkmanager`. Device profiles are discovered with `avdmanager`. The
Android command-line tools can be installed under either
`cmdline-tools/latest/bin` or a versioned `cmdline-tools/<version>/bin`
directory.

AVD support lives in `android-mode-avd.el` and is loaded on demand, while
`android-mode.el` remains focused on project, Gradle, application, and device
workflows.

`android-scrcpy` opens a Transient menu for selecting a device and configuring
video, window, control, input, audio, and recording options. Press `RET` to
start scrcpy. The same menu can stop or restart sessions, show their process
output, copy the generated shell command, and inspect displays, encoders, and
cameras.

scrcpy is resolved from `exec-path` by default. To use a specific executable or
pass options that are not exposed in the menu:

```elisp
(setq android-scrcpy-program "/path/to/scrcpy"
      android-scrcpy-extra-arguments '("--verbosity=debug"))
```

Multiple sessions may run concurrently when they target different devices.

## Configuration

```elisp
(setq android-mode-cache-dir (expand-file-name "android/" user-emacs-directory)
      android-mode-sdk-dir "/path/to/android-sdk")
```

`ANDROID_HOME` and a project `local.properties` `sdk.dir` value take precedence
over `android-mode-sdk-dir`.

Gradle command output is retained in buffers. Flavor discovery writes its
synchronous Gradle output to `*android-gradle-log*`; build, install, uninstall,
test, clean, and run tasks use Emacs compilation buffers.

## Development

Run package checks from this directory:

```sh
make install-deps
make lint
make build
make test
```

Licensed under GPL-3.0-or-later.
