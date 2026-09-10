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

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'android-mode)

(defvar android-avd--exclusive-processes nil
  "Symbols identifying emulator processes started by android-mode.")

(defun android-avd--run-tool (name &rest args)
  "Run SDK tool NAME with ARGS and return its exit status and output."
  (with-temp-buffer
    (let ((status (apply #'call-process (android-tool-path name)
                         nil (current-buffer) nil args)))
      (cons status (buffer-string)))))

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

(defun android-avd--parse-system-images (output)
  "Return installed system image package names parsed from SDK OUTPUT."
  (let ((case-fold-search t)
        (in-installed nil)
        result)
    (dolist (line (split-string output "\n" t))
      (cond
       ((string-match-p "^[[:space:]]*installed packages:" line)
        (setq in-installed t))
       ((and in-installed
             (string-match-p "^[[:space:]]*available packages:" line))
        (setq in-installed nil))
       ((and in-installed
             (string-match
              "^[[:space:]]*\\(system-images;[^|[:space:]]+\\)[[:space:]]*|"
              line))
        (push (match-string 1 line) result))))
    (delete-dups (nreverse result))))

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

(defun android-avd--installed-system-images ()
  "Return installed Android system image package names."
  (let* ((result (android-avd--run-tool "sdkmanager" "--list"))
         (status (car result)))
    (when (zerop status)
      (android-avd--parse-system-images (cdr result)))))

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
  "Create an Android Virtual Device using an installed system image."
  (interactive)
  (let ((name (read-string "New AVD name: ")))
    (when (string-empty-p name)
      (user-error "AVD name cannot be empty"))
    (let* ((images (android-avd--installed-system-images))
           (package (if images
                        (completing-read "System image: " images nil t)
                      (read-string "System image package: ")))
           (devices (android-avd--device-profiles))
           (device (and devices
                        (completing-read "Device profile (optional): "
                                         devices nil nil)))
           (args (append '("create" "avd" "--name")
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
        (error "Unable to create AVD %s:\n%s" name output)))))

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
   ("d" "Delete AVD" android-avd-delete)
   ("w" "Wipe data and start" android-avd-wipe-data)]
  ["Emulator"
   ("s" "Start emulator" android-avd-start)
   ("k" "Stop emulator" android-avd-stop)])

(provide 'android-mode-avd)

;;; android-mode-avd.el ends here
