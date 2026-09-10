;;; android-mode-avd.el --- Manage Android Virtual Devices -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2018 R.W. van 't Veer
;; Copyright (C) 2025 Gemini (Code optimizations and warning fixes)

;; Author: R.W. van 't Veer
;; Keywords: tools processes
;; Package-Requires: ((emacs "28.1") (transient "0.3.0"))
;; URL: https://github.com/cat-emacs/android-mode

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;;; Commentary:

;; Provides a Transient interface for creating and managing Android
;; Virtual Devices.  This library can be used outside an Android project,
;; provided the Android SDK location is configured through `android-mode'.

;;; Code:

(require 'comint)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'android-mode)

(defvar android-avd--exclusive-processes nil
  "Symbols identifying emulator processes started by android-mode.")

(defun android-avd--run-command (program &rest args)
  "Run PROGRAM with ARGS and return its exit status and output."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil (current-buffer) nil args)))
      (cons status (buffer-string)))))

(defun android-avd--run-tool (name &rest args)
  "Run SDK tool NAME with ARGS and return its exit status and output."
  (apply #'android-avd--run-command (android-tool-path name) args))

(defun android-avd--run-tool-with-input (input name &rest args)
  "Run SDK tool NAME with ARGS, sending it INPUT on standard input."
  (let ((input-file (make-temp-file "android-mode-avd-input")))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert input))
          (with-temp-buffer
            (let ((status (apply #'call-process (android-tool-path name)
                                 input-file (current-buffer) nil args)))
              (cons status (buffer-string)))))
      (delete-file input-file))))

(defun android-avd--start-exclusive-command (name command &rest args)
  "Run COMMAND named NAME with ARGS unless it is already running."
  (let ((process-symbol (intern name)))
    (unless (memq process-symbol android-avd--exclusive-processes)
      (let* ((full-command
              (format "%s %s"
                      (shell-quote-argument command)
                      (mapconcat #'shell-quote-argument args " ")))
             (process (start-process-shell-command name name full-command)))
        (set-process-sentinel
         process
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (setq android-avd--exclusive-processes
                   (delq (intern (process-name proc))
                         android-avd--exclusive-processes)))))
        (push process-symbol android-avd--exclusive-processes)
        process))))

(defun android-avd--normalize-system-image-package (package)
  "Return canonical semicolon-separated name for system image PACKAGE."
  (if (string-prefix-p "system-images/" package)
      (string-replace "/" ";" package)
    package))

(defun android-avd--android-cli-system-image-package (package)
  "Return slash-separated Android CLI name for system image PACKAGE."
  (string-replace ";" "/" package))

(defun android-avd--parse-system-image-inventory (output)
  "Return installed and available system images parsed from SDK OUTPUT."
  (let ((case-fold-search t)
        section
        installed
        available)
    (dolist (line (split-string output "\n" t))
      (cond
       ((string-match-p "^[[:space:]]*installed packages:" line)
        (setq section 'installed))
       ((string-match-p "^[[:space:]]*available packages:" line)
        (setq section 'available))
       ((string-match-p "^[[:space:]]*available updates:" line)
        (setq section nil))
       ((and section
             (string-match
              "^[[:space:]]*\\(system-images\\(?:;\\|/\\)[^|[:space:]]+\\)"
              line))
        (let ((package
               (android-avd--normalize-system-image-package
                (match-string 1 line))))
          (if (eq section 'installed)
              (push package installed)
            (push package available))))))
    (setq installed (delete-dups (nreverse installed))
          available (delete-dups (nreverse available)))
    (list :installed installed
          :available (seq-difference available installed #'string=))))

(defun android-avd--parse-device-profiles (output)
  "Return device profile ids parsed from AVDMANAGER OUTPUT."
  (delete-dups
   (delq nil
         (mapcar
          (lambda (line)
            (cond
             ((string-match
               "^[[:space:]]*id:[[:space:]]*[^[:space:]]+[[:space:]]+or[[:space:]]*\"?\\([^\"]+\\)\"?"
               line)
              (match-string 1 line))
             ((string-match
               "^[[:space:]]*id:[[:space:]]*\"?\\([^\"[:space:]]+\\)\"?"
               line)
              (match-string 1 line))))
          (split-string output "\n" t)))))

(defun android-avd--system-image-list-result ()
  "Return the result of listing installed and available system images."
  (let ((android-cli (ignore-errors (android-tool-path "android"))))
    (or (and android-cli
             (let ((result
                    (android-avd--run-command
                     android-cli "sdk" "list" "--all" "system-images*")))
               (and (zerop (car result)) result)))
        (android-avd--run-tool "sdkmanager" "--list"))))

(defun android-avd--system-image-inventory ()
  "Return a plist of installed and available Android system images."
  (let* ((result (android-avd--system-image-list-result))
         (status (car result)))
    (unless (zerop status)
      (error "Unable to list Android system images:\n%s" (cdr result)))
    (android-avd--parse-system-image-inventory (cdr result))))

(defun android-avd--device-profiles ()
  "Return Android device profile ids known to AVDMANAGER."
  (let* ((result (android-avd--run-tool "avdmanager" "list" "device"))
         (status (car result)))
    (when (zerop status)
      (android-avd--parse-device-profiles (cdr result)))))

(defun android-list-avd ()
  "Return names of Android Virtual Devices installed on the local machine."
  (let* ((result (android-avd--run-tool "emulator" "-list-avds"))
         (status (car result))
         (avds (split-string (cdr result) "\n" t)))
    (if (and (zerop status) avds)
        avds
      (error "No Android Virtual Devices found"))))

(defun android-avd--read-name (&optional prompt)
  "Prompt for an installed AVD name with optional PROMPT."
  (completing-read (or prompt "Android Virtual Device: ")
                   (android-list-avd) nil t))

(defun android-avd--running-emulators ()
  "Return serial numbers of running Android emulators."
  (let* ((result (android-avd--run-tool "adb" "devices"))
         (status (car result))
         emulators)
    (when (zerop status)
      (dolist (line (split-string (cdr result) "\n" t))
        (when (string-match "^\\(emulator-[0-9]+\\)[ \t]+device$" line)
          (push (match-string 1 line) emulators))))
    (nreverse emulators)))

(defun android-avd--read-running-emulator ()
  "Prompt for a running emulator serial, or return the only one."
  (let ((emulators (android-avd--running-emulators)))
    (cond
     ((null emulators) (error "No Android emulators are running"))
     ((= (length emulators) 1) (car emulators))
     (t (completing-read "Running emulator: " emulators nil t)))))

(defun android-avd--display-output (title output)
  "Display command OUTPUT in a read-only buffer named TITLE."
  (let ((buffer (get-buffer-create title)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output))
      (special-mode))
    (pop-to-buffer buffer)))

(defun android-avd--system-image-candidates (inventory)
  "Return completion candidates for system image INVENTORY."
  (append
   (mapcar (lambda (package)
             (cons (format "[installed] %s" package)
                   (cons package t)))
           (plist-get inventory :installed))
   (mapcar (lambda (package)
             (cons (format "[download]  %s" package)
                   (cons package nil)))
           (plist-get inventory :available))))

(defun android-avd--read-system-image ()
  "Prompt for a system image and return (PACKAGE . INSTALLED-P)."
  (let* ((inventory (android-avd--system-image-inventory))
         (candidates (android-avd--system-image-candidates inventory)))
    (unless candidates
      (error "No Android system images are available"))
    (cdr (assoc (completing-read "System image: "
                                 (mapcar #'car candidates) nil t)
                candidates))))

(defun android-avd--sdk-install-command (package)
  "Return a command list that installs system image PACKAGE."
  (if-let* ((android-cli (ignore-errors (android-tool-path "android"))))
      (list android-cli "sdk" "install"
            (android-avd--android-cli-system-image-package package))
    (list (android-tool-path "sdkmanager") package)))

(defun android-avd--start-system-image-install (package callback)
  "Install system image PACKAGE asynchronously, then call CALLBACK."
  (let* ((command (android-avd--sdk-install-command package))
         (buffer (get-buffer-create "*android-system-image-install*"))
         (process-name
          (format "android-system-image-%s" (substring (md5 package) 0 8))))
    (when-let* ((existing (get-buffer-process buffer)))
      (user-error "A system image installation is already running"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "$ " (mapconcat #'shell-quote-argument command " ") "\n\n"))
      (comint-mode))
    (apply #'make-comint-in-buffer
           process-name buffer (car command) nil (cdr command))
    (let ((process (get-buffer-process buffer)))
      (set-process-query-on-exit-flag process nil)
      (set-process-sentinel
       process
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (if (zerop (process-exit-status proc))
               (progn
                 (message "Installed Android system image %s" package)
                 (when callback
                   (funcall callback)))
             (pop-to-buffer (process-buffer proc))
             (message "Failed to install Android system image %s"
                      package)))))
      (display-buffer buffer)
      process)))

(defun android-avd--confirm-system-image-install (package callback)
  "Confirm installation of system image PACKAGE, then call CALLBACK."
  (when (yes-or-no-p (format "Download system image %s? " package))
    (android-avd--start-system-image-install package callback)))

(defun android-avd-install-system-image (&optional package callback)
  "Download and install system image PACKAGE, then call CALLBACK.
Interactively, prompt for an image that is not installed."
  (interactive)
  (let* ((inventory (android-avd--system-image-inventory))
         (installed (plist-get inventory :installed))
         (available (plist-get inventory :available))
         (package
          (or package
              (and available
                   (completing-read "Download system image: "
                                    available nil t)))))
    (unless package
      (user-error "No downloadable Android system images found"))
    (if (member package installed)
        (progn
          (message "Android system image is already installed: %s" package)
          (when callback
            (funcall callback)))
      (unless (member package available)
        (user-error "Android system image is not available: %s" package))
      (android-avd--confirm-system-image-install package callback))))

(defun android-avd--create-device (name package device)
  "Create AVD NAME using system image PACKAGE and hardware DEVICE."
  (let* ((args (append '("create" "avd" "--name")
                       (list name "--package" package "--force")
                       (and (not (string-empty-p device))
                            (list "--device" device))))
         (result
          (apply #'android-avd--run-tool-with-input
                 "no\n" "avdmanager" args))
         (status (car result))
         (output (cdr result)))
    (if (zerop status)
        (progn
          (android--log "created Android Virtual Device %s" name)
          (message "%s" (string-trim output)))
      (error "Unable to create AVD %s:\n%s" name output))))

;;;###autoload
(defun android-avd-start ()
  "Launch an Android emulator."
  (interactive)
  (let ((avd (or (and (not (string-blank-p android-mode-avd))
                      android-mode-avd)
                 (android-avd--read-name))))
    (android--log "starting emulator %s" avd)
    (unless (android-avd--start-exclusive-command
             (format "*android-emulator-%s*" avd)
             (android-tool-path "emulator")
             "-avd" avd)
      (android--log "emulator for %s is already running or being started" avd))))

(defun android-avd-list ()
  "List configured Android Virtual Devices in a help buffer."
  (interactive)
  (let* ((result (android-avd--run-tool "avdmanager" "list" "avd"))
         (status (car result)))
    (if (zerop status)
        (android-avd--display-output "*android-avds*" (cdr result))
      (error "Unable to list Android Virtual Devices:\n%s" (cdr result)))))

(defun android-avd-create ()
  "Create an Android Virtual Device, downloading its system image if needed."
  (interactive)
  (let ((name (read-string "New AVD name: ")))
    (when (string-empty-p name)
      (user-error "AVD name cannot be empty"))
    (let* ((image (android-avd--read-system-image))
           (package (car image))
           (installed (cdr image))
           (devices (android-avd--device-profiles))
           (device (and devices
                        (completing-read "Device profile (optional): "
                                         devices nil nil))))
      (if installed
          (android-avd--create-device name package device)
        (android-avd--confirm-system-image-install
         package
         (lambda ()
           (android-avd--create-device name package device)))))))

(defun android-avd-delete ()
  "Delete an Android Virtual Device."
  (interactive)
  (let ((name (android-avd--read-name "Delete Android Virtual Device: ")))
    (when (yes-or-no-p (format "Delete AVD %s? " name))
      (let* ((result (android-avd--run-tool
                      "avdmanager" "delete" "avd" "--name" name))
             (status (car result)))
        (if (zerop status)
            (message "Deleted AVD %s" name)
          (error "Unable to delete AVD %s:\n%s" name (cdr result)))))))

(defun android-avd-stop ()
  "Stop a running Android emulator."
  (interactive)
  (let* ((emulator (android-avd--read-running-emulator))
         (result (android-avd--run-tool "adb" "-s" emulator "emu" "kill"))
         (status (car result)))
    (if (zerop status)
        (message "Stopped Android emulator %s" emulator)
      (error "Unable to stop Android emulator %s:\n%s"
             emulator (cdr result)))))

(defun android-avd-wipe-data ()
  "Start an AVD with its user data wiped."
  (interactive)
  (let ((avd (android-avd--read-name "Wipe data and start AVD: ")))
    (when (yes-or-no-p (format "Wipe all data for AVD %s and start it? " avd))
      (android--log "wiping data for AVD %s" avd)
      (unless (android-avd--start-exclusive-command
               (format "*android-emulator-%s*" avd)
               (android-tool-path "emulator")
               "-avd" avd "-wipe-data")
        (android--log "emulator for %s is already running or being started" avd)))))

;;;###autoload
(transient-define-prefix android-avd ()
  "Create and manage Android Virtual Devices."
  ["AVD"
   ("l" "List AVDs" android-avd-list)
   ("c" "Create AVD" android-avd-create)
   ("i" "Install system image" android-avd-install-system-image)
   ("d" "Delete AVD" android-avd-delete)
   ("w" "Wipe data and start" android-avd-wipe-data)]
  ["Emulator"
   ("s" "Start emulator" android-avd-start)
   ("k" "Stop emulator" android-avd-stop)])

(provide 'android-mode-avd)

;;; android-mode-avd.el ends here
