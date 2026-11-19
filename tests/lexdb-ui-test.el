;;; lexdb-ui-test.el --- Tests for LexDB UI -*- lexical-binding: t -*-

;;; Commentary:

;; Focused UI regression tests.

;;; Code:

(require 'ert)
(require 'lexdb-ui)

(defun lexdb-ui-test--entry (headword pos senses)
  "Build a test entry with HEADWORD, POS, and SENSES."
  (lexdb-entry-create
   :id 1
   :headword headword
   :headword-display headword
   :metadata `((ldoce/pos . ,pos))
   :senses (mapcar (lambda (sense)
                     (pcase-let ((`(,num ,signpost ,definition) sense))
                       (lexdb-sense-create
                        :number num
                        :signpost signpost
                        :definition definition)))
                   senses)))

(ert-deftest lexdb-ui-imenu-uses-entry-pos-properties ()
  "Imenu uses rendered entry properties for homographs without IPA."
  (let ((adapter (lexdb-adapter-create
                  :id 'ldoce
                  :name "Test LDOCE"
                  :capabilities '(pos)))
        (entries (list
                  (lexdb-ui-test--entry
                   "good1" "adjective"
                   '(("1" "of a high standard" "of a high standard or quality")))
                  (lexdb-ui-test--entry
                   "good2" "noun"
                   '(("1" nil "no good/not much good/not any good")
                     ("2" nil "used to say that an action will not work"))))))
    (with-temp-buffer
      (lexdb-ui-render-entries entries adapter)
      (should (equal (mapcar #'substring-no-properties
                             (mapcar #'car (lexdb-imenu-create-index)))
                     '("adj. 1 OF A HIGH STANDARD of a high standard or quality (good¹)"
                       "n. 1 no good/not much good/not any good (good²)"
                       "n. 2 used to say that an action will not work (good²)"))))))

(ert-deftest lexdb-ui-custom-id-jumps-to-rendered-sense ()
  "Render namespaced metadata and follow a sense link in both display modes."
  (let* ((lexdb-adapters (make-hash-table :test 'eq))
         (lexdb-enabled-adapters '(longman))
         (lexdb--history nil)
         (lexdb--history-position -1)
         (entry (lexdb-ui-test--entry "aid" "noun"
                                      '(("1" nil "help") ("3" nil "in aid of"))))
         (adapter (lexdb-adapter-create
                   :id 'longman :type 'ldoce :name "Longman"
                   :capabilities '(pos) :lookup-fn (lambda (_) (list entry)))))
    (lexdb-register-adapter adapter)
    (save-window-excursion
      (dolist (multi '(nil t))
        (let ((lexdb-multi-dict-mode multi))
          (when multi (lexdb-ui-display-multi "aid"))
          (lexdb-search-and-goto-sense "aid" "3" 'longman)
          (should (looking-at "3 in aid of"))
          (goto-char (point-min))
          (should (search-forward "noun" nil t)))))))

(ert-deftest lexdb-resolve-word-reuses-matching-entries ()
  (let* ((lexdb-adapters (make-hash-table :test 'eq))
         calls
         (adapter (lexdb-adapter-create
                   :id 'test :name "Test" :capabilities '(lemmatization)
                   :lookup-fn (lambda (word)
                                (push word calls)
                                (when (equal word "run") '(found))))))
    (lexdb-register-adapter adapter)
    (should (equal (lexdb--resolve-word "runs" adapter) '("run" found)))
    (should (equal (nreverse calls) '("runs" "run")))))

(provide 'lexdb-ui-test)
;;; lexdb-ui-test.el ends here
