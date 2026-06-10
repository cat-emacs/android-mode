;;; android-mode-tests.el --- Tests for android-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for pure helpers.

;;; Code:

(require 'ert)
(require 'android-mode)
(ert-deftest android-mode-parse-gradle-flavors ()
  "Gradle flavor output is parsed between marker lines."
  (should
   (equal
    (android-parse-gradle-flavors
     "ignored\n===FLAVORS_START===\napp:debug=com.example\nfeature:release=com.example.feature\n===FLAVORS_END===\nignored\n")
    '(("app" "debug" "com.example")
      ("feature" "release" "com.example.feature")))))

(ert-deftest android-mode-flavor-helpers-use-cache ()
  "Flavor helper functions read module, variant and applicationId from cache."
  (cl-letf (((symbol-function 'android-root)
             (lambda () default-directory)))
    (let ((android--flavor-cache '(("app" "debug" "com.example")
                                   ("app" "release" "com.example.release")))
          (android--flavor-cache-root default-directory))
      (should (equal (android--flavor-modules) '("app")))
      (should (equal (android--flavor-variants "app") '("debug" "release")))
      (should (equal (android--flavor-appid "app" "release")
                     "com.example.release")))))

(provide 'android-mode-tests)

;;; android-mode-tests.el ends here
