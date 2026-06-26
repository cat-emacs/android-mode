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
     "ignored\n===FLAVORS_START===\n:app|/tmp/project/app|debug|com.example|src/main/kotlin;src/debug/kotlin|testDebugUnitTest\n:feature|/tmp/project/feature|release|com.example.feature|src/main/kotlin|assembleRelease\n===FLAVORS_END===\nignored\n")
    '((:module-path ":app"
       :module-name "app"
       :module-root "/tmp/project/app"
       :variant "debug"
       :application-id "com.example"
       :source-roots ("src/main/kotlin" "src/debug/kotlin")
       :preview-task "testDebugUnitTest")
      (:module-path ":feature"
       :module-name "feature"
       :module-root "/tmp/project/feature"
       :variant "release"
       :application-id "com.example.feature"
       :source-roots ("src/main/kotlin")
       :preview-task "assembleRelease")))))

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

(ert-deftest android-mode-flavor-cache-rejects-old-schema ()
  "Flavor cache entries without the current schema are ignored."
  (let* ((root "/tmp/project/")
         (android-mode-cache-dir (make-temp-file "android-mode-cache" t))
         (file (android--flavor-cache-file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 (list :root root :time (current-time) :data '(("app" "debug" "com.example")))
             (current-buffer)))
    (should-not (android--flavor-cache-load root))))

(ert-deftest android-mode-target-for-source-file-prefers-kmp-source-set ()
  "Target lookup maps KMP source-set files to their owning Gradle module."
  (let* ((project-root "/tmp/project/")
         (entry (list :module-path ":composeApp"
                      :module-name "composeApp"
                      :module-root "/tmp/project/composeApp"
                      :variant "debug"
                      :application-id "com.example"
                      :source-roots '("src/commonMain/kotlin"
                                      "src/androidMain/kotlin"))))
    (should
     (equal
      (android--target-for-source-file
       "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"
       project-root
       (list entry))
      entry))))

(ert-deftest android-mode-flavor-script-uses-plugin-models-for-kmp ()
  "Flavor script should use AGP/KGP models instead of hard-coded KMP paths."
  (with-temp-buffer
    (insert-file-contents android-mode-flavor-script)
    (let ((script (buffer-string)))
      (should (string-match-p "androidComponents" script))
      (should (string-match-p "extensions.findByName(\"kotlin\")" script))
      (should (string-match-p "compilations" script))
      (should (string-match-p "desktopTest" script))
      (should-not (string-match-p "src/commonMain/kotlin" script))
      (should-not (string-match-p "src/androidMain/kotlin" script)))))

(provide 'android-mode-tests)

;;; android-mode-tests.el ends here
