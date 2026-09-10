;;; android-mode-avd-tests.el --- Tests for android-mode AVD -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for AVD helpers and command argument construction.

;;; Code:

(require 'ert)
(require 'android-mode-avd)

(ert-deftest android-mode-avd-parse-command-output ()
  "AVD parsers extract image inventory and device profile ids."
  (should
   (equal
    (android-avd--parse-system-image-inventory
     "Installed packages:\n\
system-images;android-35;google_apis;x86_64 | 2 | Google APIs Intel x86_64 Atom System Image\n\
system-images;android-35;google_apis;x86_64 | 2 | duplicate\n\
Available Packages:\n\
system-images/android-36/google_apis/x86_64  1.0.0  not installed\n")
    '(:installed ("system-images;android-35;google_apis;x86_64")
      :available ("system-images;android-36;google_apis;x86_64"))))
  (should
   (equal
    (android-avd--parse-device-profiles
     "id: 52 or \"pixel_9\"\n\
    Name: Pixel 9\n\
id: \"pixel_9_pro\"\n")
    '("pixel_9" "pixel_9_pro"))))

(ert-deftest android-mode-avd-create-device-builds-command ()
  "AVD creation builds an avdmanager command from its inputs."
  (let (input tool args)
    (cl-letf (((symbol-function 'android-avd--run-tool-with-input)
               (lambda (received-input received-tool &rest received-args)
                 (setq input received-input
                       tool received-tool
                       args received-args)
                 (cons 0 "Created AVD")))
              ((symbol-function 'android--log) #'ignore)
              ((symbol-function 'message) #'ignore))
      (android-avd--create-device
       "Pixel 9" "system-images;android-35;google_apis;x86_64" "pixel_9")
      (should (equal input "no\n"))
      (should (equal tool "avdmanager"))
      (should
       (equal args
              '("create" "avd" "--name" "Pixel 9"
                "--package" "system-images;android-35;google_apis;x86_64"
                "--force" "--device" "pixel_9"))))))

(ert-deftest android-mode-avd-create-downloads-missing-image ()
  "Creating an AVD installs a missing system image before creation."
  (let (installed-package created)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt) "Pixel 9"))
              ((symbol-function 'android-avd--read-system-image)
               (lambda ()
                 (cons "system-images;android-36;google_apis;x86_64" nil)))
              ((symbol-function 'android-avd--device-profiles)
               (lambda () '("pixel_9")))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args) "pixel_9"))
              ((symbol-function 'android-avd--confirm-system-image-install)
               (lambda (package callback)
                 (setq installed-package package)
                 (funcall callback)))
              ((symbol-function 'android-avd--create-device)
               (lambda (name package device)
                 (setq created (list name package device)))))
      (android-avd-create)
      (should
       (equal installed-package
              "system-images;android-36;google_apis;x86_64"))
      (should
       (equal created
              '("Pixel 9"
                "system-images;android-36;google_apis;x86_64"
                "pixel_9"))))))

(ert-deftest android-mode-avd-prefers-android-cli-for-install ()
  "System image installation uses the current Android CLI when available."
  (cl-letf (((symbol-function 'android-tool-path)
             (lambda (name)
               (pcase name
                 ("android" "/sdk/android")
                 (_ (error "Unexpected tool"))))))
    (should
     (equal
      (android-avd--sdk-install-command
       "system-images;android-36;google_apis;arm64-v8a")
      '("/sdk/android" "sdk" "install"
        "system-images/android-36/google_apis/arm64-v8a")))))

(ert-deftest android-mode-avd-stop-selects-only-emulators ()
  "Stopping an AVD ignores physical devices in adb output."
  (cl-letf (((symbol-function 'android-avd--run-tool)
             (lambda (tool &rest args)
               (if (equal (cons tool args) '("adb" "devices"))
                   (cons 0
                         "List of devices attached\n\
emulator-5554\tdevice\n\
RF8M123456\tdevice\n\
emulator-5556\toffline\n")
                 (error "Unexpected command")))))
    (should (equal (android-avd--running-emulators) '("emulator-5554")))))

(provide 'android-mode-avd-tests)

;;; android-mode-avd-tests.el ends here
