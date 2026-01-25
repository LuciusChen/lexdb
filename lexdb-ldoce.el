;;; lexdb-ldoce.el --- LDOCE adapter for lexdb -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (lexdb "0.1.0"))

;;; Commentary:

;; Adapter for Longman Dictionary of Contemporary English (LDOCE).
;; Supports both legacy schema (v1) and new LexDB schema (v2).
;;
;; Usage (recommended - unified config):
;;   (require 'lexdb-ldoce)
;;   (setq lexdb-dictionaries
;;         '((:id ldoce
;;            :type ldoce
;;            :name "Longman Dictionary"
;;            :db-file "~/dicts/LDOCE6.db"
;;            :audio-dir "~/dicts/ldoce-audio/"
;;            :priority 1)))
;;   (lexdb-init)
;;
;; Usage (legacy - still supported):
;;   (require 'lexdb-ldoce)
;;   (setq lexdb-ldoce-db-file "~/path/to/ldoce.db")
;;   (setq lexdb-ldoce-audio-directory "~/path/to/audio/")
;;   (lexdb-ldoce-register)

;;; Code:

(require 'lexdb)
(require 'sqlite)

;;;; ============================================================
;;;; Utility Functions
;;;; ============================================================

;; Note: Uses lexdb--non-empty-string-p from lexdb.el

;;;; ============================================================
;;;; Configuration
;;;; ============================================================

(defgroup lexdb-ldoce nil
  "LDOCE adapter settings."
  :prefix "lexdb-ldoce-"
  :group 'lexdb)

(defcustom lexdb-ldoce-db-file nil
  "Path to LDOCE SQLite database."
  :type '(choice (const nil) file)
  :group 'lexdb-ldoce)

(defcustom lexdb-ldoce-audio-directory nil
  "Path to LDOCE audio files directory."
  :type '(choice (const nil) directory)
  :group 'lexdb-ldoce)

;;;; ============================================================
;;;; Database Connection
;;;; ============================================================

(defun lexdb-ldoce--ensure-db ()
  "Ensure database connection is open."
  (lexdb-db-ensure 'ldoce lexdb-ldoce-db-file))

(defun lexdb-ldoce--close ()
  "Close database connection and clear cache."
  (lexdb-db-close 'ldoce))

;;;; ============================================================
;;;; Schema V2 (New LexDB Schema)
;;;; ============================================================

(defun lexdb-ldoce--build-example (ex &optional include-position)
  "Build lexdb-example from row EX.
If INCLUDE-POSITION is non-nil, include position in metadata."
  (let ((text (nth 0 ex))
        (audio (nth 1 ex))
        (position (nth 2 ex)))
    (lexdb-example-create
     :text text
     :audio (when (lexdb--non-empty-string-p audio) audio)
     :metadata (when include-position
                 (list (cons 'position position))))))

(defun lexdb-ldoce--v2-row-to-sense (sense-row db)
  "Convert V2 SENSE-ROW to lexdb-sense."
  (pcase-let ((`(,id ,sense-num ,signpost ,definition ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text, audio_path, position FROM examples WHERE sense_id = ? ORDER BY position, sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex) (lexdb-ldoce--build-example ex t)) ex-rows))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (nth 0 l)) :value (nth 1 l)))
                           label-rows))
           (gram-patterns (lexdb-ldoce--v2-fetch-grammar-patterns id db))
           (sense-relations (lexdb-ldoce--v2-fetch-sense-relations id db)))
      (lexdb-sense-create
       :id id
       :number (when (lexdb--non-empty-string-p sense-num) sense-num)
       :signpost (when (lexdb--non-empty-string-p signpost) signpost)
       :definition definition
       :examples examples
       :grammar-patterns gram-patterns
       :labels labels
       :relations sense-relations))))

(defun lexdb-ldoce--v2-fetch-grammar-patterns (sense-id db)
  "Fetch grammar patterns for SENSE-ID from V2 schema."
  (let ((rows (sqlite-select db
               "SELECT id, pattern, gloss FROM grammar_patterns WHERE sense_id = ? ORDER BY sort_order"
               (list sense-id))))
    (mapcar (lambda (row)
              (pcase-let ((`(,pat-id ,pattern ,gloss) row))
                (let ((ex-rows (sqlite-select db
                                "SELECT text, audio_path FROM grammar_examples WHERE pattern_id = ? ORDER BY sort_order"
                                (list pat-id))))
                  (lexdb-grammar-pattern-create
                   :pattern pattern
                   :gloss (when (lexdb--non-empty-string-p gloss) gloss)
                   :examples (mapcar #'lexdb-ldoce--build-example ex-rows)))))
            rows)))

(defalias 'lexdb-ldoce--v2-build-pronunciations #'lexdb--build-pronunciations-from-db
  "Build pronunciations for ENTRY-ID from V2 schema.")

(defun lexdb-ldoce--v2-fetch-relations (entry-id db)
  "Fetch entry-level relations for ENTRY-ID from V2 schema.
Only returns relations where sense_id IS NULL.
Uses fragment storage format: prefix + clickable + suffix."
  (let ((rows (sqlite-select db
               "SELECT relation_type, prefix, clickable, suffix, target_word, target_sense FROM relations WHERE entry_id = ? AND sense_id IS NULL ORDER BY sort_order"
               (list entry-id))))
    (delq nil
          (mapcar (lambda (row)
                    (pcase-let ((`(,rel-type ,prefix ,clickable ,suffix ,target-word ,target-sense) row))
                      (when (lexdb--non-empty-string-p clickable)
                        (lexdb-relation-create
                         :type (intern rel-type)
                         :prefix prefix
                         :clickable clickable
                         :suffix suffix
                         :target-word target-word
                         :target-sense target-sense
                         ;; Legacy fields for compatibility
                         :target (concat (or prefix "") clickable (or suffix ""))))))
                  rows))))

(defun lexdb-ldoce--v2-fetch-sense-relations (sense-id db)
  "Fetch sense-level relations for SENSE-ID from V2 schema.
Uses fragment storage format: prefix + clickable + suffix."
  (let ((rows (sqlite-select db
               "SELECT relation_type, prefix, clickable, suffix, target_word, target_sense FROM relations WHERE sense_id = ? ORDER BY sort_order"
               (list sense-id))))
    (delq nil
          (mapcar (lambda (row)
                    (pcase-let ((`(,rel-type ,prefix ,clickable ,suffix ,target-word ,target-sense) row))
                      (when (lexdb--non-empty-string-p clickable)
                        (lexdb-relation-create
                         :type (intern rel-type)
                         :prefix prefix
                         :clickable clickable
                         :suffix suffix
                         :target-word target-word
                         :target-sense target-sense
                         ;; Legacy fields for compatibility
                         :target (concat (or prefix "") clickable (or suffix ""))))))
                  rows))))

(defalias 'lexdb-ldoce--decompress-json #'lexdb--decompress-json-value
  "Decompress zlib-compressed JSON data.")

(defun lexdb-ldoce--v2-fetch-attributes (entry-id db)
  "Fetch EAV attributes for ENTRY-ID from V2 schema."
  (let ((rows (sqlite-select db
               "SELECT attr_key, attr_value, attr_type FROM entry_attributes WHERE entry_id = ?"
               (list entry-id))))
    (mapcar (lambda (row)
              (pcase-let ((`(,key ,value ,type) row))
                (cons (intern key)
                      (pcase type
                        ("json" (json-read-from-string value))
                        ("json.gz" (lexdb-ldoce--decompress-json value))
                        ("integer" (string-to-number value))
                        ("boolean" (not (equal value "0")))
                        (_ value)))))
            rows)))

(defun lexdb-ldoce--v2-row-to-entry (row)
  "Convert V2 database ROW to lexdb-entry."
  (pcase-let ((`(,id ,_dict-id ,word ,_word-lower ,hyph) row))
    (let* ((db (lexdb-ldoce--ensure-db))
           (sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, definition, sort_order FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (senses (mapcar (lambda (r) (lexdb-ldoce--v2-row-to-sense r db)) sense-rows))
           (prons (lexdb-ldoce--v2-build-pronunciations id db))
           (relations (lexdb-ldoce--v2-fetch-relations id db))
           (metadata (lexdb-ldoce--v2-fetch-attributes id db))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE entry_id = ? AND sense_id IS NULL"
                        (list id))))
      ;; Add pos from labels
      (dolist (label label-rows)
        (pcase-let ((`(,ltype ,lvalue) label))
          (when (and (equal ltype "pos") (not (assq 'ldoce/pos metadata)))
            (push (cons 'ldoce/pos lvalue) metadata))))
      ;; Add audio paths to metadata
      (dolist (pron prons)
        (when-let* ((audio (lexdb-pronunciation-audio pron)))
          (pcase (lexdb-pronunciation-variant pron)
            ('uk (unless (assq 'ldoce/audio-uk metadata)
                   (push (cons 'ldoce/audio-uk audio) metadata)))
            ('us (unless (assq 'ldoce/audio-us metadata)
                   (push (cons 'ldoce/audio-us audio) metadata))))))
      ;; Distribute subsenses to individual sense metadata
      (let ((subsenses-data (alist-get 'ldoce/subsenses metadata)))
        (when subsenses-data
          (dolist (sense senses)
            (let* ((sense-id (lexdb-sense-id sense))
                   (sense-subsenses (alist-get (intern (number-to-string sense-id)) subsenses-data)))
              (when sense-subsenses
                (setf (lexdb-sense-metadata sense)
                      (cons (cons 'ldoce/subsenses sense-subsenses)
                            (lexdb-sense-metadata sense))))))))
      (lexdb-entry-create
       :id id :headword word
       :headword-display (when (lexdb--non-empty-string-p hyph) hyph)
       :senses senses :pronunciations prons :relations relations :metadata metadata))))

;;;; ============================================================
;;;; Adapter Functions
;;;; ============================================================

(defun lexdb-ldoce--normalize-apostrophe (str)
  "Normalize various apostrophe characters in STR to standard ASCII apostrophe."
  (when str
    ;; Replace curly/smart apostrophes with straight apostrophe
    (replace-regexp-in-string "[''ʼ′`]" "'" str)))

(defun lexdb-ldoce--lookup (word)
  "Look up WORD in LDOCE database.
Uses exact match only, consistent with original dictionary behavior."
  (let* ((db (lexdb-ldoce--ensure-db))
         ;; Normalize apostrophes before searching
         (word-normalized (lexdb-ldoce--normalize-apostrophe word))
         (word-lower (downcase word-normalized))
         (rows (sqlite-select db
                "SELECT id, dict_id, headword, headword_lower, headword_display
                 FROM entries WHERE headword_lower = ? AND dict_id = 'ldoce'"
                (list word-lower))))
    (mapcar #'lexdb-ldoce--v2-row-to-entry rows)))

(defun lexdb-ldoce--get-collocations (entry-id)
  "Get collocations for ENTRY-ID."
  (or (lexdb-db-cache-get 'ldoce (cons entry-id 'collocations))
      (let* ((db (lexdb-ldoce--ensure-db))
             (rows (sqlite-select db
                    "SELECT id, category, text, gloss FROM collocations WHERE entry_id = ? ORDER BY sort_order"
                    (list entry-id)))
             (colls (mapcar (lambda (row)
                              (pcase-let ((`(,coll-id ,cat ,coll ,gloss) row))
                                (let ((ex-rows (sqlite-select db
                                                "SELECT text FROM collocation_examples WHERE collocation_id = ? ORDER BY sort_order"
                                                (list coll-id))))
                                  (lexdb-collocation-create
                                   :category cat :text coll :gloss gloss
                                   :examples (mapcar #'car ex-rows)))))
                            rows)))
        (lexdb-db-cache-put 'ldoce (cons entry-id 'collocations) colls))))

(defun lexdb-ldoce--get-relations (entry-id type)
  "Get relations of TYPE for ENTRY-ID."
  (let* ((db (lexdb-ldoce--ensure-db))
         (rows (sqlite-select db
                "SELECT target_text, target_link FROM relations WHERE entry_id = ? AND relation_type = ? ORDER BY sort_order"
                (list entry-id (symbol-name type)))))
    (mapcar (lambda (row)
              (pcase-let ((`(,target ,link) row))
                (lexdb-relation-create
                 :type type
                 :target target
                 :target-link (when (lexdb--non-empty-string-p link) link))))
            rows)))

(defun lexdb-ldoce--prefetch (entry-ids)
  "Prefetch data for ENTRY-IDS."
  (when entry-ids
    (let* ((db (lexdb-ldoce--ensure-db))
           (ph (mapconcat (lambda (_) "?") entry-ids ","))
           (coll-rows (sqlite-select db
                       (format "SELECT id, entry_id, category, text, gloss FROM collocations WHERE entry_id IN (%s) ORDER BY entry_id, sort_order" ph)
                       entry-ids))
           (entry-colls (make-hash-table :test 'eql)))
      (dolist (row coll-rows) (push row (gethash (nth 1 row) entry-colls)))
      (maphash (lambda (entry-id rows)
                 (lexdb-db-cache-put
                  'ldoce
                  (cons entry-id 'collocations)
                  (mapcar (lambda (row)
                            (pcase-let ((`(,coll-id ,_ ,cat ,coll ,gloss) row))
                              (lexdb-collocation-create
                               :category cat :text coll :gloss gloss
                               :examples (mapcar #'car (sqlite-select db
                                                        "SELECT text FROM collocation_examples WHERE collocation_id = ? ORDER BY sort_order"
                                                        (list coll-id))))))
                          (nreverse rows))))
               entry-colls))))

;;;; ============================================================
;;;; Lemmatization
;;;; ============================================================

(defun lexdb-ldoce--find-lemma (word)
  "Find base form of WORD using common lemmatization rules."
  (lexdb--find-lemma-with-lookup word #'lexdb-ldoce--lookup))

;;;; ============================================================
;;;; Frequency Rendering
;;;; ============================================================

(defun lexdb-ldoce--render-frequency (freq)
  "Render LDOCE frequency with dots.
FREQ is the S1/W1 etc level text."
  (when (lexdb--non-empty-string-p freq)
    (propertize freq 'face 'lexdb-frequency-face)))

;;;; ============================================================
;;;; Registration
;;;; ============================================================

(defun lexdb-ldoce--register-from-config (config)
  "Register LDOCE adapter from CONFIG plist.
Called by `lexdb-init' for unified configuration."
  (let ((id (plist-get config :id))
        (name (or (plist-get config :name)
                  "Longman Dictionary of Contemporary English"))
        (db-file (plist-get config :db-file))
        (audio-dir (plist-get config :audio-dir)))
    (unless db-file
      (error "LDOCE config missing :db-file"))
    ;; Set legacy variables for compatibility
    (setq lexdb-ldoce-db-file (expand-file-name db-file))
    (when audio-dir
      (setq lexdb-ldoce-audio-directory (expand-file-name audio-dir)))
    ;; Register adapter
    (lexdb-register-adapter
     (lexdb-adapter-create
      :id id
      :name name
      :version "6th Edition"
      :capabilities '(lookup definition pronunciation audio-uk audio-us audio-example
                      pos grammar register hyphenation frequency-band
                      examples collocations phrases synonyms cross-refs origin lemmatization)
      :db-file lexdb-ldoce-db-file
      :audio-dir lexdb-ldoce-audio-directory
      :lookup-fn #'lexdb-ldoce--lookup
      :close-fn #'lexdb-ldoce--close
      :collocations-fn #'lexdb-ldoce--get-collocations
      :relations-fn #'lexdb-ldoce--get-relations
      :lemma-fn #'lexdb-ldoce--find-lemma
      :prefetch-fn #'lexdb-ldoce--prefetch
      :render-frequency-fn #'lexdb-ldoce--render-frequency))))

;;;###autoload
(defun lexdb-ldoce-register ()
  "Register LDOCE adapter using legacy configuration variables.
For new setups, prefer using `lexdb-dictionaries' and `lexdb-init'."
  (interactive)
  (lexdb-ldoce--register-from-config
   (list :id 'ldoce
         :name "Longman Dictionary of Contemporary English"
         :db-file lexdb-ldoce-db-file
         :audio-dir lexdb-ldoce-audio-directory)))

;; Register adapter type for unified config system
(lexdb-register-adapter-type 'ldoce #'lexdb-ldoce--register-from-config)

(provide 'lexdb-ldoce)
;;; lexdb-ldoce.el ends here
