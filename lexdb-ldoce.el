;;; lexdb-ldoce.el --- LDOCE adapter for lexdb -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (lexdb "0.1.0"))

;;; Commentary:

;; Adapter for Longman Dictionary of Contemporary English (LDOCE).
;; Reuses generic adapter functions where possible, adds LDOCE-specific features:
;; - Apostrophe normalization for lookup
;; - Custom frequency rendering
;; - Fragment-based relations (prefix + clickable + suffix)
;; - Subsenses support
;;
;; Usage:
;;   (require 'lexdb-ldoce)
;;   (setq lexdb-dictionaries
;;         '((:id ldoce
;;            :type ldoce
;;            :name "Longman Dictionary"
;;            :db-file "~/dicts/LDOCE6.db"
;;            :audio-dir "~/dicts/ldoce-audio/"
;;            :priority 1)))
;;   (lexdb-init)

;;; Code:

(require 'lexdb)

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
;;;; LDOCE-specific: Apostrophe Normalization
;;;; ============================================================

(defun lexdb-ldoce--normalize-apostrophe (str)
  "Normalize various apostrophe characters in STR to standard ASCII apostrophe."
  (when str
    (replace-regexp-in-string "[''ʼ′`]" "'" str)))

;;;; ============================================================
;;;; LDOCE-specific: Sense Conversion (with subsenses, fragments)
;;;; ============================================================

(defun lexdb-ldoce--row-to-sense (sense-row db)
  "Convert SENSE-ROW to lexdb-sense using DB.
Handles LDOCE-specific features: grammar patterns, fragment relations."
  (pcase-let ((`(,id ,sense-num ,signpost ,definition ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text, audio_path, position FROM examples WHERE sense_id = ? ORDER BY position, sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex)
                               (lexdb-example-create
                                :text (nth 0 ex)
                                :audio (let ((p (nth 1 ex)))
                                         (when (lexdb--non-empty-string-p p) p))
                                :metadata (list (cons 'position (nth 2 ex)))))
                             ex-rows))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (nth 0 l)) :value (nth 1 l)))
                           label-rows))
           (gram-patterns (lexdb-ldoce--fetch-grammar-patterns id db))
           (sense-relations (lexdb-ldoce--fetch-sense-relations id db)))
      (lexdb-sense-create
       :id id
       :number (when (lexdb--non-empty-string-p sense-num) sense-num)
       :signpost (when (lexdb--non-empty-string-p signpost) signpost)
       :definition definition
       :examples examples
       :grammar-patterns gram-patterns
       :labels labels
       :relations sense-relations))))

(defun lexdb-ldoce--fetch-grammar-patterns (sense-id db)
  "Fetch grammar patterns for SENSE-ID from DB."
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
                   :gloss (when (and gloss (not (string-empty-p gloss))) gloss)
                   :examples (mapcar (lambda (ex)
                                       (lexdb-example-create
                                        :text (nth 0 ex)
                                        :audio (let ((p (nth 1 ex)))
                                                 (when (lexdb--non-empty-string-p p) p))))
                                     ex-rows)))))
            rows)))

(defun lexdb-ldoce--fetch-sense-relations (sense-id db)
  "Fetch sense-level relations for SENSE-ID using fragment format."
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
                         :target (concat (or prefix "") clickable (or suffix ""))))))
                  rows))))

;;;; ============================================================
;;;; LDOCE-specific: Entry Conversion (with metadata, subsenses)
;;;; ============================================================

(defun lexdb-ldoce--decompress-json (compressed-data)
  "Decompress zlib-compressed JSON data."
  (let ((decompressed
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert compressed-data)
           (zlib-decompress-region (point-min) (point-max))
           (buffer-string))))
    (json-read-from-string (decode-coding-string decompressed 'utf-8))))

(defun lexdb-ldoce--fetch-entry-relations (entry-id db)
  "Fetch entry-level relations for ENTRY-ID using fragment format."
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
                         :target (concat (or prefix "") clickable (or suffix ""))))))
                  rows))))

(defun lexdb-ldoce--fetch-attributes (entry-id db)
  "Fetch EAV attributes for ENTRY-ID."
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

(defun lexdb-ldoce--row-to-entry (row db)
  "Convert database ROW to lexdb-entry using DB."
  (pcase-let ((`(,id ,_dict-id ,word ,_word-lower ,hyph) row))
    (let* ((sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, definition, sort_order FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (senses (mapcar (lambda (r) (lexdb-ldoce--row-to-sense r db)) sense-rows))
           ;; Pronunciations - reuse generic pattern
           (pron-rows (sqlite-select db
                       "SELECT variant, ipa, audio_path FROM pronunciations WHERE entry_id = ? ORDER BY sort_order"
                       (list id)))
           (prons (delq nil
                        (mapcar (lambda (row)
                                  (pcase-let ((`(,variant ,ipa ,audio) row))
                                    (when (or (lexdb--non-empty-string-p ipa)
                                              (lexdb--non-empty-string-p audio))
                                      (lexdb-pronunciation-create
                                       :ipa ipa
                                       :variant (when variant (intern variant))
                                       :audio (when (lexdb--non-empty-string-p audio) audio)))))
                                pron-rows)))
           (relations (lexdb-ldoce--fetch-entry-relations id db))
           (metadata (lexdb-ldoce--fetch-attributes id db))
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
        (when-let ((audio (lexdb-pronunciation-audio pron)))
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
;;;; Lookup (with apostrophe normalization)
;;;; ============================================================

(defun lexdb-ldoce--lookup (word)
  "Look up WORD in LDOCE database with apostrophe normalization."
  (let* ((db (lexdb-generic--ensure-db lexdb-ldoce-db-file))
         (word-normalized (lexdb-ldoce--normalize-apostrophe word))
         (word-lower (downcase word-normalized))
         (rows (sqlite-select db
                "SELECT id, dict_id, headword, headword_lower, headword_display
                 FROM entries WHERE headword_lower = ? AND dict_id = 'ldoce'"
                (list word-lower))))
    ;; Fuzzy match fallbacks
    (unless rows
      (setq rows (sqlite-select db
                  "SELECT id, dict_id, headword, headword_lower, headword_display
                   FROM entries WHERE headword_lower LIKE ? AND dict_id = 'ldoce'"
                  (list (concat word-lower "%")))))
    (unless rows
      (setq rows (sqlite-select db
                  "SELECT id, dict_id, headword, headword_lower, headword_display
                   FROM entries WHERE headword_lower LIKE ? AND dict_id = 'ldoce'"
                  (list (concat "%" word-lower "%")))))
    (mapcar (lambda (r) (lexdb-ldoce--row-to-entry r db)) rows)))

;;;; ============================================================
;;;; Lemmatization (LDOCE-specific rules)
;;;; ============================================================

(defun lexdb-ldoce--try-lemma (word suffix replacement)
  "Try removing SUFFIX from WORD and adding REPLACEMENT."
  (when (and (> (length word) (length suffix)) (string-suffix-p suffix word))
    (let ((candidate (concat (substring word 0 (- (length word) (length suffix))) replacement)))
      (when (and (> (length candidate) 1) (lexdb-ldoce--lookup candidate)) candidate))))

(defun lexdb-ldoce--find-lemma (word)
  "Find base form of WORD using LDOCE-specific rules."
  (let ((w (downcase word)))
    (if (lexdb-ldoce--lookup w) w
      (or (lexdb-ldoce--try-lemma w "ing" "") (lexdb-ldoce--try-lemma w "ing" "e")
          (lexdb-ldoce--try-lemma w "ning" "n") (lexdb-ldoce--try-lemma w "ting" "t")
          (lexdb-ldoce--try-lemma w "ping" "p") (lexdb-ldoce--try-lemma w "bing" "b")
          (lexdb-ldoce--try-lemma w "ging" "g") (lexdb-ldoce--try-lemma w "ming" "m")
          (lexdb-ldoce--try-lemma w "ding" "d") (lexdb-ldoce--try-lemma w "ed" "")
          (lexdb-ldoce--try-lemma w "ed" "e") (lexdb-ldoce--try-lemma w "ied" "y")
          (lexdb-ldoce--try-lemma w "ned" "n") (lexdb-ldoce--try-lemma w "ted" "t")
          (lexdb-ldoce--try-lemma w "ped" "p") (lexdb-ldoce--try-lemma w "bed" "b")
          (lexdb-ldoce--try-lemma w "ged" "g") (lexdb-ldoce--try-lemma w "med" "m")
          (lexdb-ldoce--try-lemma w "ded" "d") (lexdb-ldoce--try-lemma w "s" "")
          (lexdb-ldoce--try-lemma w "es" "") (lexdb-ldoce--try-lemma w "ies" "y")
          (lexdb-ldoce--try-lemma w "er" "") (lexdb-ldoce--try-lemma w "er" "e")
          (lexdb-ldoce--try-lemma w "ier" "y") (lexdb-ldoce--try-lemma w "est" "")
          (lexdb-ldoce--try-lemma w "est" "e") (lexdb-ldoce--try-lemma w "iest" "y")
          (lexdb-ldoce--try-lemma w "ly" "") (lexdb-ldoce--try-lemma w "ily" "y")
          (lexdb-ldoce--try-lemma w "'s" "") w))))

;;;; ============================================================
;;;; Frequency Rendering (LDOCE-specific)
;;;; ============================================================

(defun lexdb-ldoce--render-frequency (freq)
  "Render LDOCE frequency indicator."
  (when (lexdb--non-empty-string-p freq)
    (propertize freq 'face 'lexdb-frequency-face)))

;;;; ============================================================
;;;; Registration
;;;; ============================================================

(defun lexdb-ldoce--close ()
  "Close LDOCE database connection."
  (lexdb-generic--close-db lexdb-ldoce-db-file 'ldoce))

(defun lexdb-ldoce--register-from-config (config)
  "Register LDOCE adapter from CONFIG plist."
  (let ((id (plist-get config :id))
        (name (or (plist-get config :name)
                  "Longman Dictionary of Contemporary English"))
        (db-file (plist-get config :db-file))
        (audio-dir (plist-get config :audio-dir)))
    (unless db-file
      (error "LDOCE config missing :db-file"))
    (setq lexdb-ldoce-db-file (expand-file-name db-file))
    (when audio-dir
      (setq lexdb-ldoce-audio-directory (expand-file-name audio-dir)))
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
      ;; Reuse generic collocations
      :collocations-fn (lambda (entry-id)
                         (lexdb-generic--get-collocations entry-id lexdb-ldoce-db-file 'ldoce))
      :lemma-fn #'lexdb-ldoce--find-lemma
      :render-frequency-fn #'lexdb-ldoce--render-frequency))))

;;;###autoload
(defun lexdb-ldoce-register ()
  "Register LDOCE adapter using legacy configuration variables."
  (interactive)
  (lexdb-ldoce--register-from-config
   (list :id 'ldoce
         :name "Longman Dictionary of Contemporary English"
         :db-file lexdb-ldoce-db-file
         :audio-dir lexdb-ldoce-audio-directory)))

(lexdb-register-adapter-type 'ldoce #'lexdb-ldoce--register-from-config)

(provide 'lexdb-ldoce)
;;; lexdb-ldoce.el ends here
