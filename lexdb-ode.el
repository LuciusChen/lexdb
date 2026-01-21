;;; lexdb-ode.el --- ODE adapter for lexdb -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lexdb "0.1.0"))

;;; Commentary:

;; Adapter for Oxford Dictionary of English (ODE) / Oxford English Living Dictionary (OELD).
;; Supports ODE Living Online edition.
;;
;; Usage (recommended - unified config):
;;   (require 'lexdb-ode)
;;   (setq lexdb-dictionaries
;;         '((:id ode
;;            :type ode
;;            :name "Oxford Dictionary of English"
;;            :db-file "~/dicts/ODE_Living_Online.db"
;;            :priority 3)))
;;   (lexdb-init)
;;
;; Usage (legacy - still supported):
;;   (require 'lexdb-ode)
;;   (setq lexdb-ode-db-file "~/path/to/ODE_Living_Online.db")
;;   (lexdb-ode-register)

;;; Code:

(require 'lexdb)
(require 'sqlite)
(require 'json)

;;;; ============================================================
;;;; Configuration
;;;; ============================================================

(defgroup lexdb-ode nil
  "ODE adapter settings."
  :prefix "lexdb-ode-"
  :group 'lexdb)

(defcustom lexdb-ode-db-file nil
  "Path to ODE SQLite database."
  :type '(choice (const nil) file)
  :group 'lexdb-ode)

;;;; ============================================================
;;;; Database Connection
;;;; ============================================================

(defvar lexdb-ode--db nil
  "Database connection for ODE.")

(defvar lexdb-ode--cache (make-hash-table :test 'eql)
  "Cache for prefetched data.")

(defun lexdb-ode--ensure-db ()
  "Ensure database connection is open."
  (unless lexdb-ode-db-file
    (error "Please set `lexdb-ode-db-file'"))
  (unless (file-exists-p lexdb-ode-db-file)
    (error "Database file not found: %s" lexdb-ode-db-file))
  (unless (and lexdb-ode--db (sqlitep lexdb-ode--db))
    (setq lexdb-ode--db (sqlite-open lexdb-ode-db-file)))
  lexdb-ode--db)

(defun lexdb-ode--close ()
  "Close database connection and clear cache."
  (when (and lexdb-ode--db (sqlitep lexdb-ode--db))
    (sqlite-close lexdb-ode--db)
    (setq lexdb-ode--db nil))
  (clrhash lexdb-ode--cache))

;;;; ============================================================
;;;; Schema Queries
;;;; ============================================================

(defun lexdb-ode--decompress-json (compressed-data)
  "Decompress COMPRESSED-DATA and parse as JSON."
  (when (and compressed-data (not (string-empty-p compressed-data)))
    (condition-case nil
        (let ((decompressed-str
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert compressed-data)
                 (zlib-decompress-region (point-min) (point-max))
                 (buffer-string))))
          ;; Decode the unibyte string as UTF-8, then parse JSON
          (json-read-from-string (decode-coding-string decompressed-str 'utf-8)))
      (error nil))))

(defun lexdb-ode--row-to-sense (sense-row db)
  "Convert SENSE-ROW to lexdb-sense using DB connection."
  (pcase-let ((`(,id ,sense-num ,signpost ,definition ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text FROM examples WHERE sense_id = ? ORDER BY sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex)
                               (lexdb-example-create :text (nth 0 ex)))
                             ex-rows))
           (gram-rows (sqlite-select db
                       "SELECT pattern, gloss FROM grammar_patterns WHERE sense_id = ? ORDER BY sort_order"
                       (list id)))
           (gram-patterns (mapcar (lambda (g)
                                    (lexdb-grammar-pattern-create
                                     :pattern (car g)
                                     :gloss (cadr g)))
                                  gram-rows))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (nth 0 l)) :value (nth 1 l)))
                           label-rows))
           ;; Fetch sense-level relations (cross-references)
           (rel-rows (sqlite-select db
                      "SELECT relation_type, prefix, clickable, suffix, target_word, target_sense
                       FROM relations WHERE sense_id = ? ORDER BY sort_order"
                      (list id)))
           (relations (delq nil
                            (mapcar (lambda (row)
                                      (pcase-let ((`(,rel-type ,prefix ,clickable ,suffix ,target-word ,target-sense) row))
                                        (when (or (lexdb--non-empty-string-p clickable)
                                                  (lexdb--non-empty-string-p prefix))
                                          (lexdb-relation-create
                                           :type (intern rel-type)
                                           :prefix prefix
                                           :clickable clickable
                                           :suffix suffix
                                           :target-word target-word
                                           :target-sense target-sense
                                           :target (concat (or prefix "") (or clickable "") (or suffix ""))))))
                                    rel-rows))))
      (lexdb-sense-create
       :id id
       :number (when (lexdb--non-empty-string-p sense-num) sense-num)
       :signpost (when (lexdb--non-empty-string-p signpost) signpost)
       :definition definition
       :examples examples
       :grammar-patterns gram-patterns
       :labels labels
       :relations relations))))

(defun lexdb-ode--build-pronunciations (entry-id db)
  "Build pronunciations for ENTRY-ID from DB."
  (let ((rows (sqlite-select db
               "SELECT variant, ipa, audio_path FROM pronunciations WHERE entry_id = ? ORDER BY sort_order"
               (list entry-id))))
    (delq nil
          (mapcar (lambda (row)
                    (pcase-let ((`(,variant ,ipa ,audio) row))
                      (when (lexdb--non-empty-string-p ipa)
                        (lexdb-pronunciation-create
                         :ipa ipa
                         :variant (when variant (intern variant))
                         :audio (when (lexdb--non-empty-string-p audio) audio)))))
                  rows))))

(defun lexdb-ode--row-to-entry (row)
  "Convert database ROW to lexdb-entry."
  (pcase-let ((`(,id ,_dict-id ,word ,_word-lower ,hyph) row))
    (let* ((db (lexdb-ode--ensure-db))
           (sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, definition, sort_order
                         FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (prons (lexdb-ode--build-pronunciations id db))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (metadata nil))
      ;; Add pos from labels
      (dolist (label label-rows)
        (pcase-let ((`(,ltype ,lvalue) label))
          (when (and (equal ltype "pos") (not (assq 'ode/pos metadata)))
            (push (cons 'ode/pos lvalue) metadata))))
      ;; Fetch entry attributes (phrases, origin, frequency, etc.)
      (let ((attr-rows (sqlite-select db
                        "SELECT attr_key, attr_value, attr_type FROM entry_attributes WHERE entry_id = ?"
                        (list id))))
        (dolist (attr attr-rows)
          (pcase-let ((`(,key ,value ,type) attr))
            (when (lexdb--non-empty-string-p value)
              (let ((parsed-value (cond
                                   ((equal type "json.gz")
                                    (lexdb-ode--decompress-json value))
                                   ((equal type "json")
                                    (condition-case nil
                                        ;; Use json-read-from-string for symbol keys
                                        (json-read-from-string value)
                                      (error value)))
                                   ((equal type "integer")
                                    (string-to-number value))
                                   (t value))))
                (push (cons (intern key) parsed-value) metadata))))))
      ;; Convert sense rows
      (let ((senses (mapcar (lambda (sr)
                              (lexdb-ode--row-to-sense sr db))
                            sense-rows)))
        (lexdb-entry-create
         :id id :headword word
         :headword-display (when (lexdb--non-empty-string-p hyph) hyph)
         :senses senses :pronunciations prons :metadata metadata)))))

;;;; ============================================================
;;;; Adapter Functions
;;;; ============================================================

(defun lexdb-ode--lookup (word)
  "Look up WORD in ODE database.
Also searches for combining forms like -WORD."
  (let* ((db (lexdb-ode--ensure-db))
         (word-lower (downcase word))
         (combining-form (concat "-" word-lower))
         ;; Search for exact match and combining form (e.g., "logic" and "-logic")
         (rows (sqlite-select db
                "SELECT id, dict_id, headword, headword_lower, headword_display
                 FROM entries WHERE (headword_lower = ? OR headword_lower = ?) AND dict_id = 'ode'
                 ORDER BY headword_lower"
                (list word-lower combining-form))))
    (mapcar #'lexdb-ode--row-to-entry rows)))

(defun lexdb-ode--get-phrases (entry-id)
  "Get phrases for ENTRY-ID."
  (or (gethash (cons entry-id 'phrases) lexdb-ode--cache)
      (let* ((db (lexdb-ode--ensure-db))
             (attr-row (sqlite-select db
                        "SELECT attr_value, attr_type FROM entry_attributes
                         WHERE entry_id = ? AND attr_key = 'ode/phrases'"
                        (list entry-id)))
             (phrases (when attr-row
                        (let ((value (caar attr-row))
                              (type (cadar attr-row)))
                          (when (lexdb--non-empty-string-p value)
                            (cond
                             ((equal type "json.gz")
                              (lexdb-ode--decompress-json value))
                             ((equal type "json")
                              (condition-case nil
                                  (json-parse-string value :object-type 'alist)
                                (error nil)))
                             (t nil)))))))
        (puthash (cons entry-id 'phrases) phrases lexdb-ode--cache)
        phrases)))

(defun lexdb-ode--get-origin (entry-id)
  "Get etymology/origin for ENTRY-ID."
  (or (gethash (cons entry-id 'origin) lexdb-ode--cache)
      (let* ((db (lexdb-ode--ensure-db))
             (attr-row (sqlite-select db
                        "SELECT attr_value, attr_type FROM entry_attributes
                         WHERE entry_id = ? AND attr_key = 'ode/origin'"
                        (list entry-id)))
             (origin (when attr-row
                       (let ((value (caar attr-row))
                             (type (cadar attr-row)))
                         (when (lexdb--non-empty-string-p value)
                           (cond
                            ((equal type "json.gz")
                             (lexdb-ode--decompress-json value))
                            ((equal type "json")
                             (condition-case nil
                                 (json-parse-string value :object-type 'alist)
                               (error nil)))
                            (t value)))))))
        (puthash (cons entry-id 'origin) origin lexdb-ode--cache)
        origin)))

;;;; ============================================================
;;;; Lemmatization
;;;; ============================================================

(defun lexdb-ode--try-lemma (word suffix replacement)
  "Try removing SUFFIX from WORD and adding REPLACEMENT."
  (when (and (> (length word) (length suffix)) (string-suffix-p suffix word))
    (let ((candidate (concat (substring word 0 (- (length word) (length suffix))) replacement)))
      (when (and (> (length candidate) 1) (lexdb-ode--lookup candidate)) candidate))))

(defun lexdb-ode--find-lemma (word)
  "Find base form of WORD."
  (let ((w (downcase word)))
    (if (lexdb-ode--lookup w) w
      (or (lexdb-ode--try-lemma w "ing" "") (lexdb-ode--try-lemma w "ing" "e")
          (lexdb-ode--try-lemma w "ning" "n") (lexdb-ode--try-lemma w "ting" "t")
          (lexdb-ode--try-lemma w "ping" "p") (lexdb-ode--try-lemma w "bing" "b")
          (lexdb-ode--try-lemma w "ging" "g") (lexdb-ode--try-lemma w "ming" "m")
          (lexdb-ode--try-lemma w "ding" "d") (lexdb-ode--try-lemma w "ed" "")
          (lexdb-ode--try-lemma w "ed" "e") (lexdb-ode--try-lemma w "ied" "y")
          (lexdb-ode--try-lemma w "ned" "n") (lexdb-ode--try-lemma w "ted" "t")
          (lexdb-ode--try-lemma w "ped" "p") (lexdb-ode--try-lemma w "bed" "b")
          (lexdb-ode--try-lemma w "ged" "g") (lexdb-ode--try-lemma w "med" "m")
          (lexdb-ode--try-lemma w "ded" "d") (lexdb-ode--try-lemma w "s" "")
          (lexdb-ode--try-lemma w "es" "") (lexdb-ode--try-lemma w "ies" "y")
          (lexdb-ode--try-lemma w "er" "") (lexdb-ode--try-lemma w "er" "e")
          (lexdb-ode--try-lemma w "ier" "y") (lexdb-ode--try-lemma w "est" "")
          (lexdb-ode--try-lemma w "est" "e") (lexdb-ode--try-lemma w "iest" "y")
          (lexdb-ode--try-lemma w "ly" "") (lexdb-ode--try-lemma w "ily" "y")
          (lexdb-ode--try-lemma w "'s" "") w))))

;;;; ============================================================
;;;; Registration
;;;; ============================================================

(defun lexdb-ode--register-from-config (config)
  "Register ODE adapter from CONFIG plist.
Called by `lexdb-init' for unified configuration."
  (let ((id (plist-get config :id))
        (name (or (plist-get config :name)
                  "Oxford Dictionary of English"))
        (db-file (plist-get config :db-file)))
    (unless db-file
      (error "ODE config missing :db-file"))
    ;; Set legacy variable for compatibility
    (setq lexdb-ode-db-file (expand-file-name db-file))
    ;; Register adapter
    (lexdb-register-adapter
     (lexdb-adapter-create
      :id id
      :name name
      :version "Living Online"
      :capabilities '(lookup definition pronunciation
                      pos grammar register domain examples
                      phrases origin lemmatization
                      audio-uk audio-us)
      :db-file lexdb-ode-db-file
      :lookup-fn #'lexdb-ode--lookup
      :close-fn #'lexdb-ode--close
      :lemma-fn #'lexdb-ode--find-lemma))))

;;;###autoload
(defun lexdb-ode-register ()
  "Register ODE adapter using legacy configuration variables.
For new setups, prefer using `lexdb-dictionaries' and `lexdb-init'."
  (interactive)
  (lexdb-ode--register-from-config
   (list :id 'ode
         :name "Oxford Dictionary of English"
         :db-file lexdb-ode-db-file)))

;; Register adapter type for unified config system
(lexdb-register-adapter-type 'ode #'lexdb-ode--register-from-config)

(provide 'lexdb-ode)
;;; lexdb-ode.el ends here
