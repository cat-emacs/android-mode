;;; android-mode-tests.el --- Android workflow tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'android-mode)

(defun android-mode-tests--target (module variant &rest properties)
  "Return target metadata for MODULE, VARIANT, and PROPERTIES."
  (let* ((root (format "/tmp/project/%s" module))
         (target
          (list :module-id (cons "/tmp/project" (concat ":" module))
                :build-root "/tmp/project"
                :module-path (concat ":" module)
                :module-name module
                :module-root root
                :plugin-id "com.android.application"
                :project-type "application"
                :variant variant
                :namespace (format "com.example.%s" module)
                :debuggable-p (equal variant "debug")
                :components nil
                :application-id (format "com.example.%s" module)
                :test-application-id ""
                :source-roots '("src/main/kotlin")
                :preview-task (format "assemble%s" (capitalize variant))
                :build-type variant
                :product-flavors nil
                :preferred-build-type-p nil
                :preferred-product-flavors nil)))
    (while properties
      (setq target (plist-put target (pop properties) (pop properties))))
    target))

(ert-deftest android-mode-gradle-install-reuses-current-project-selection ()
  "Install reuses a previous module and variant selection for the project."
  (let ((android-project--selected-modules nil)
        (android-project--selected-variants nil)
        (answers '("app" "debug"))
        (variants (list (android-mode-tests--target "app" "debug")
                        (android-mode-tests--target "app" "release")
                        (android-mode-tests--target "demo" "staging")))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android-project--get-flavors)
               (lambda (&optional _refresh) variants))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 (pop answers)))
              ((symbol-function 'android-gradle)
               (lambda (task)
                 (push task gradle-tasks))))
      (android-gradle-install)
      (android-gradle-install)
      (should (equal (nreverse gradle-tasks)
                     '(":app:installDebug" ":app:installDebug")))
      (should-not answers))))

(ert-deftest android-mode-gradle-install-prefix-prompts-again ()
  "A prefix argument forces module and variant prompting again."
  (let ((android-project--selected-modules nil)
        (android-project--selected-variants nil)
        (answers '("app" "debug" "demo" "staging"))
        (variants (list (android-mode-tests--target "app" "debug")
                        (android-mode-tests--target "app" "release")
                        (android-mode-tests--target "demo" "staging")
                        (android-mode-tests--target "demo" "qa")))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android-project--get-flavors)
               (lambda (&optional _refresh) variants))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 (pop answers)))
              ((symbol-function 'android-gradle)
               (lambda (task)
                 (push task gradle-tasks))))
      (android-gradle-install)
      (android-gradle-install t)
      (android-gradle-install)
      (should (equal (nreverse gradle-tasks)
                     '(":app:installDebug"
                       ":demo:installStaging"
                       ":demo:installStaging")))
      (should-not answers))))


(provide 'android-mode-tests)
;;; android-mode-tests.el ends here
