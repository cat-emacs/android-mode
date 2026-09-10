;;; android-mode-scrcpy-tests.el --- Tests for scrcpy integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for android-mode scrcpy helpers.

;;; Code:

(require 'ert)
(require 'android-mode-scrcpy)

(ert-deftest android-mode-scrcpy-device-candidates ()
  "Device candidates contain readable labels and serial values."
  (cl-letf (((symbol-function 'android--list-devices)
             (lambda ()
               '(("emulator-5554" . "Pixel_9")
                 ("192.0.2.10:5555" . "Tablet")))))
    (should
     (equal
      (android-scrcpy--device-candidates)
      '(("Pixel_9 (emulator-5554)" . "emulator-5554")
        ("Tablet (192.0.2.10:5555)" . "192.0.2.10:5555"))))))

(ert-deftest android-mode-scrcpy-target-name ()
  "Target names are inferred from connection arguments."
  (should
   (equal (android-scrcpy--target-name
           '("--serial=emulator-5554" "--fullscreen"))
          "emulator-5554"))
  (should
   (equal (android-scrcpy--target-name '("--select-usb")) "usb"))
  (should
   (equal (android-scrcpy--target-name '("--select-tcpip")) "tcpip"))
  (should
   (equal (android-scrcpy--target-name '("--tcpip=192.0.2.10:5555"))
          "tcpip-192.0.2.10:5555"))
  (should
   (equal (android-scrcpy--target-name '("--fullscreen")) "default")))

(ert-deftest android-mode-scrcpy-command-appends-configured-arguments ()
  "The command contains configured arguments before transient arguments."
  (let ((android-scrcpy-program "/usr/local/bin/scrcpy")
        (android-scrcpy-extra-arguments '("--verbosity=debug")))
    (cl-letf (((symbol-function 'file-executable-p) (lambda (_file) t)))
      (should
       (equal
        (android-scrcpy--command
         '("--serial=emulator-5554" "--fullscreen"))
        '("/usr/local/bin/scrcpy"
          "--verbosity=debug"
          "--serial=emulator-5554"
          "--fullscreen"))))))

(ert-deftest android-mode-scrcpy-connection-arguments ()
  "Inspect commands keep device selection but ignore launch options."
  (should
   (equal
    (android-scrcpy--connection-arguments
     '("--serial=emulator-5554" "--fullscreen" "--max-fps=60"))
    '("--serial=emulator-5554")))
  (should
   (equal
    (android-scrcpy--connection-arguments
     '("--select-tcpip" "--no-audio"))
    '("--select-tcpip"))))

(ert-deftest android-mode-scrcpy-buffer-name-is-safe ()
  "TCP/IP target names are converted to safe buffer names."
  (should
   (equal
    (android-scrcpy--buffer-name '("--tcpip=192.0.2.10:5555"))
    "*android-scrcpy:tcpip-192.0.2.10-5555*")))

(provide 'android-mode-scrcpy-tests)

;;; android-mode-scrcpy-tests.el ends here
