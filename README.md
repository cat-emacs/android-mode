# android-mode

Android project helpers for Emacs.

`android-mode` provides commands for common Android development tasks:

- selecting Gradle modules and variants from project flavor data
- building, installing, uninstalling, testing, and running Android apps
- launching an emulator
- creating and managing Android Virtual Devices with a Transient menu
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
- `M-x android-start-emulator`
- `M-x android-avd`
- `M-x android-print-flavor`
- `M-x android-refresh-flavors`

`android-avd` opens a Transient menu with actions for listing, creating,
deleting, starting, stopping, and wiping data for Android Virtual Devices.
Creating an AVD uses installed system images discovered by `sdkmanager` and
device profiles discovered by `avdmanager`. The Android command-line tools
can be installed under either `cmdline-tools/latest/bin` or a versioned
`cmdline-tools/<version>/bin` directory.

AVD support lives in `android-mode-avd.el` and is loaded on demand, while
`android-mode.el` remains focused on project, Gradle, application, and device
workflows.

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
