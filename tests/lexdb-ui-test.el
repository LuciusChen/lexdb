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

(provide 'lexdb-ui-test)
;;; lexdb-ui-test.el ends here
