;;; ytm-radio.el --- YouTube Music audio launcher -*- lexical-binding: t; -*-

;; Author: Lucius Chen
;; URL: https://github.com/luciuschen/ytm-radio
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Assisted-by: OpenAI Codex

;;; Commentary:

;; ytm-radio is a small Emacs audio player for YouTube and YouTube Music
;; URLs.  It relies on yt-dlp for source discovery and mpv for playback.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'imenu)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'svg nil t)
(require 'url)
(require 'url-parse)

(defconst ytm-radio--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded ytm-radio package.")

;;; Customization

(defgroup ytm-radio nil
  "Play YouTube and YouTube Music audio from Emacs."
  :group 'multimedia)

(defface ytm-radio-button
  '((t (:inherit link :underline nil)))
  "Face for clickable ytm-radio text without link underlines."
  :group 'ytm-radio)

(defface ytm-radio-item-title
  '((t (:inherit default :underline nil)))
  "Face for clickable ytm-radio item titles."
  :group 'ytm-radio)

(defface ytm-radio-active-tab
  '((t (:inherit bold :underline nil)))
  "Face for the selected ytm-radio browser tab."
  :group 'ytm-radio)

(defface ytm-radio-section-title
  '((t (:inherit bold :underline nil)))
  "Face for ytm-radio source section headings."
  :group 'ytm-radio)

(defface ytm-radio-child-frame-border
  '((((class color) (background light)) (:background "#8a8a8a"))
    (((class color) (background dark)) (:background "#6f6f6f"))
    (t (:background "gray50")))
  "Face for the now-playing child-frame border."
  :group 'ytm-radio)

(defface ytm-radio-progress-filled
  '((((class color) (background light)) (:foreground "#2f6f9f" :weight bold))
    (((class color) (background dark)) (:foreground "#f0c674" :weight bold))
    (t (:inherit bold)))
  "Face for the filled now-playing progress bar cells."
  :group 'ytm-radio)

(defcustom ytm-radio-yt-dlp-program "yt-dlp"
  "Program name or path used to run yt-dlp."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-mpv-program "mpv"
  "Program name or path used to run mpv."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-yt-dlp-extra-args nil
  "Extra arguments passed to yt-dlp when fetching source metadata."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-mpv-extra-args nil
  "Extra arguments passed to mpv before the media URL."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-ytdl-raw-options nil
  "Raw ytdl options passed to mpv's ytdl hook.
Each string should be in mpv's `--ytdl-raw-options' item form, for
example \"cookies-from-browser=chrome\"."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-helper-command
  (expand-file-name "helper/target/debug/ytm-radio-helper" ytm-radio--directory)
  "External helper executable used to fetch account data."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-data-directory
  (expand-file-name "~/.ytm-radio/")
  "Directory used for ytm-radio runtime data."
  :type 'directory
  :group 'ytm-radio)

(defcustom ytm-radio-helper-auth-file
  (expand-file-name "auth.json" ytm-radio-data-directory)
  "Authentication file passed to `ytm-radio-helper-command'.
The file contents are never persisted in ytm-radio state."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-helper-browser "chrome"
  "Browser specification passed to the helper for cookie import.
The syntax is the same as yt-dlp's BROWSER argument, for example
\"chrome\", \"chrome:Default\", or \"firefox\"."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-helper-browser-candidates
  '("chrome" "chrome:Default" "firefox" "safari" "brave" "edge"
    "chromium" "opera" "vivaldi" "whale")
  "Browser specifications offered by `ytm-radio-auth-import'."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-helper-dia-app
  "/Applications/Dia.app/Contents/MacOS/Dia"
  "Dia executable used by the helper for automatic login import."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-helper-dia-cdp-port 29317
  "Local DevTools port used for one-shot Dia login import."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (<= 1 value 65535)))))
  :group 'ytm-radio)

(defcustom ytm-radio-helper-use-mock-data nil
  "Whether account import commands should request mock helper data."
  :type 'boolean
  :group 'ytm-radio)

(defcustom ytm-radio-helper-library-limit 100
  "Maximum number of library items requested from the helper."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-helper-home-limit 12
  "Maximum number of items requested for each home recommendation section."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-state-file
  (expand-file-name "state.eld" ytm-radio-data-directory)
  "File used to persist ytm-radio sources and last track."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-display-style 'child-frame
  "Preferred display style for the now-playing view."
  :type '(choice (const :tag "Child frame" child-frame)
                 (const :tag "Regular buffer" buffer))
  :group 'ytm-radio)

(defcustom ytm-radio-child-frame-width 34
  "Fallback width of the now-playing child frame in character columns.
The frame normally fits itself to the displayed cover image."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-child-frame-height 16
  "Fallback height of the now-playing child frame in character rows.
The frame normally fits itself to the displayed cover image."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-cover-cache-directory
  (expand-file-name "covers/" ytm-radio-data-directory)
  "Directory used to cache YouTube Music cover images."
  :type 'directory
  :group 'ytm-radio)

(defcustom ytm-radio-cover-max-width 200
  "Displayed now-playing cover image width in pixels."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-cover-max-height 180
  "Maximum displayed cover image height in pixels."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-browser-thumbnail-size 48
  "Maximum thumbnail size in pixels for items in the browser buffer."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-browser-thumbnail-workaround-gaps t
  "Non-nil to render browser thumbnails through a fixed SVG canvas.
This mirrors telega's avatar gap workaround: the image is first placed
inside a fixed two-line canvas, then the canvas is sliced per text row.
It avoids row gaps and keeps non-square YouTube thumbnails from being
cropped or shifting the following text."
  :type 'boolean
  :group 'ytm-radio)

(defcustom ytm-radio-browser-header-height 176
  "Displayed height in pixels for detail header background images."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defconst ytm-radio--cover-left-padding-columns 1
  "Left padding columns used to visually balance cover edge space.")

(defconst ytm-radio--now-playing-thin-padding
  (propertize "\n" 'display '((height 0.25)))
  "Thin vertical padding used inside the now-playing child frame.")

(defconst ytm-radio--browser-heading-padding
  (propertize "\n" 'display '((height 0.25)))
  "Thin vertical padding used below browser headings.")

;;; State

(cl-defun ytm-radio--make-track
    (&key id title url duration artist album thumbnail-url source-id source-kind)
  "Return a track alist.
ID, TITLE, URL, DURATION, ARTIST, ALBUM, THUMBNAIL-URL, SOURCE-ID,
and SOURCE-KIND are stored as stable track fields."
  (list (cons :id id)
        (cons :title title)
        (cons :url url)
        (cons :duration duration)
        (cons :artist artist)
        (cons :album album)
        (cons :thumbnail-url thumbnail-url)
        (cons :source-id source-id)
        (cons :source-kind source-kind)))

(cl-defun ytm-radio--make-source
    (&key id kind title url tracks items continuation subtitle thumbnail-url)
  "Return a source alist.
ID, KIND, TITLE, URL, TRACKS, ITEMS, CONTINUATION, SUBTITLE, and
THUMBNAIL-URL are stable source fields."
  (list (cons :id id)
        (cons :kind kind)
        (cons :title title)
        (cons :url url)
        (cons :tracks tracks)
        (cons :items items)
        (cons :continuation continuation)
        (cons :subtitle subtitle)
        (cons :thumbnail-url thumbnail-url)))

(cl-defun ytm-radio--make-player
    (&key (status 'idle) current-track process ipc-process socket position
          duration repeat shuffle)
  "Return a player alist.
STATUS, CURRENT-TRACK, PROCESS, IPC-PROCESS, SOCKET, POSITION,
DURATION, REPEAT, and SHUFFLE are ephemeral runtime fields."
  (list (cons :status status)
        (cons :current-track current-track)
        (cons :process process)
        (cons :ipc-process ipc-process)
        (cons :socket socket)
        (cons :position position)
        (cons :duration duration)
        (cons :repeat repeat)
        (cons :shuffle shuffle)))

(cl-defun ytm-radio--make-state (&key sources last-track-id)
  "Return the durable package state from SOURCES and LAST-TRACK-ID."
  (list (cons :sources sources)
        (cons :last-track-id last-track-id)))

(defvar ytm-radio--state (ytm-radio--make-state)
  "Durable state for sources and the last played track.")

(defvar ytm-radio--player (ytm-radio--make-player)
  "Ephemeral player state for mpv processes and sockets.")

(defvar ytm-radio--loaded nil
  "Non-nil once durable state has been loaded.")

(defconst ytm-radio--library-buffer-name "*ytm-radio*"
  "Buffer name for the ytm-radio browser.")

(defconst ytm-radio--now-playing-buffer-name "*ytm-radio-now-playing*"
  "Buffer name for the ytm-radio now-playing child frame.")

(defvar ytm-radio--frame nil
  "Child frame currently showing the now-playing buffer.")

(defconst ytm-radio--frame-border-width 1
  "Width in pixels of the now-playing child-frame border.")

(defvar ytm-radio--cover-render-width nil
  "Temporary cover image width used while rendering now-playing.")

(defvar ytm-radio--inhibit-frame-fit nil
  "Non-nil means rendering should not resize the now-playing frame.")

(defvar ytm-radio--progress-render-timer nil
  "Timer used to throttle now-playing progress refreshes.")

(defvar ytm-radio--cover-downloads (make-hash-table :test #'equal)
  "Cover image URLs currently being fetched into the local cache.")

(defvar ytm-radio--browser-view 'home
  "Current ytm-radio browser view.")

(defvar ytm-radio--browser-history nil
  "Stack of previous ytm-radio browser views.")

(defvar ytm-radio--browser-loading-message nil
  "Transient loading message shown while replacing browser view content.")

(defvar ytm-radio--initial-home-refreshed nil
  "Non-nil once Home has been refreshed on first browser open.")

(defconst ytm-radio--browser-section-limit 8
  "Maximum items shown per source in overview browser views.")

(defun ytm-radio--sources ()
  "Return the current source alist."
  (or (map-elt ytm-radio--state :sources) nil))

(defun ytm-radio--source (id)
  "Return the source with ID, or nil."
  (cdr (assoc id (ytm-radio--sources))))

(defun ytm-radio--put-source (source)
  "Insert or replace SOURCE in `ytm-radio--state'."
  (let* ((id (map-elt source :id))
         (sources (ytm-radio--sources))
         (cell (assoc id sources)))
    (if cell
        (setcdr cell source)
      (setq sources (append sources (list (cons id source))))
      (setf (map-elt ytm-radio--state :sources) sources))))

(defun ytm-radio--all-tracks ()
  "Return all known tracks in source order."
  (seq-mapcat (lambda (source)
                (or (map-elt source :tracks) nil))
              (map-values (ytm-radio--sources))
              'list))

(defun ytm-radio--empty-catalog-p ()
  "Return non-nil when no source has been added."
  (null (ytm-radio--sources)))

(defun ytm-radio--track (id)
  "Return the known track with ID, or nil."
  (seq-find (lambda (track)
              (equal (map-elt track :id) id))
            (ytm-radio--all-tracks)))

(defun ytm-radio--current-track ()
  "Return the current player track, falling back to the last track."
  (or (map-elt ytm-radio--player :current-track)
      (ytm-radio--track (map-elt ytm-radio--state :last-track-id))))

(defun ytm-radio--save ()
  "Persist durable state to `ytm-radio-state-file'."
  (make-directory (file-name-directory ytm-radio-state-file) t)
  (with-temp-file ytm-radio-state-file
    (prin1 (list (cons :version 1)
                 (cons :sources (map-elt ytm-radio--state :sources))
                 (cons :last-track-id
	                       (map-elt ytm-radio--state :last-track-id)))
	           (current-buffer))))

(defun ytm-radio--default-runtime-file-p (file name)
  "Return non-nil when FILE is the default runtime file NAME."
  (equal (expand-file-name file)
         (expand-file-name name ytm-radio-data-directory)))

(defun ytm-radio--copy-legacy-runtime-file (legacy current &optional private)
  "Copy LEGACY runtime file to CURRENT when CURRENT does not exist.
When PRIVATE is non-nil, set CURRENT's permissions to user-only."
  (when (and (file-readable-p legacy)
             (not (file-exists-p current)))
    (make-directory (file-name-directory current) t)
    (copy-file legacy current)
    (when private
      (set-file-modes current #o600))
    t))

(defun ytm-radio--migrate-legacy-runtime-files ()
  "Copy default runtime files from the legacy Emacs data directory."
  (let ((legacy-state (locate-user-emacs-file "ytm-radio/state.eld"))
        (legacy-auth (locate-user-emacs-file "ytm-radio/auth.json")))
    (when (and (ytm-radio--default-runtime-file-p ytm-radio-state-file
                                                  "state.eld")
               (ytm-radio--copy-legacy-runtime-file legacy-state
                                                    ytm-radio-state-file))
      (message "Migrated ytm-radio state to %s" ytm-radio-state-file))
    (when (and (ytm-radio--default-runtime-file-p ytm-radio-helper-auth-file
                                                  "auth.json")
               (ytm-radio--copy-legacy-runtime-file legacy-auth
                                                    ytm-radio-helper-auth-file
                                                    t))
      (message "Migrated ytm-radio auth to %s" ytm-radio-helper-auth-file))))

(defun ytm-radio--load ()
  "Load durable state from `ytm-radio-state-file'."
  (when (file-exists-p ytm-radio-state-file)
    (let ((data (with-temp-buffer
                  (insert-file-contents ytm-radio-state-file)
                  (read (current-buffer)))))
      (setq ytm-radio--state
            (ytm-radio--make-state
             :sources (map-elt data :sources)
             :last-track-id (map-elt data :last-track-id))))))

(defun ytm-radio--ensure-loaded ()
  "Load durable state once for the current Emacs session."
  (unless ytm-radio--loaded
    (ytm-radio--migrate-legacy-runtime-files)
    (ytm-radio--load)
    (setq ytm-radio--loaded t)))

;;; Source fetching

(defun ytm-radio--ensure-program (program label)
  "Signal a user error unless PROGRAM named LABEL is executable."
  (unless (or (and (file-name-absolute-p program)
                   (file-executable-p program))
              (executable-find program))
    (user-error "Cannot find %s in `exec-path'" label)))

(defun ytm-radio--trim-buffer (buffer)
  "Return BUFFER contents without surrounding whitespace."
  (with-current-buffer buffer
    (string-trim (buffer-string))))

(defun ytm-radio--trim-file (file)
  "Return FILE contents without surrounding whitespace."
  (if (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (string-trim (buffer-string)))
    ""))

(defun ytm-radio--process-diagnostic (stdout stderr-file)
  "Return diagnostic text from STDERR-FILE, falling back to STDOUT."
  (let ((diagnostic (ytm-radio--trim-file stderr-file)))
    (if (string-empty-p diagnostic)
        (let ((fallback (ytm-radio--trim-buffer stdout)))
          (if (string-empty-p fallback)
              "no diagnostic output"
            fallback))
      diagnostic)))

(defun ytm-radio--call-json-process (program arguments failure-message)
  "Run PROGRAM with ARGUMENTS and return parsed JSON stdout.
FAILURE-MESSAGE is a function called with diagnostic text when PROGRAM
exits with a non-zero status."
  (let ((stdout (generate-new-buffer " *ytm-radio-stdout*"))
        (stderr-file (make-temp-file "ytm-radio-stderr-")))
    (unwind-protect
        (let ((exit-code
               (apply #'call-process
                      program nil (list stdout stderr-file) nil arguments)))
          (if (zerop exit-code)
              (with-current-buffer stdout
                (goto-char (point-min))
                (condition-case error
                    (json-parse-buffer :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object nil)
                  (error
                   (user-error "Process returned invalid JSON: %s"
                               (error-message-string error)))))
            (funcall failure-message
                     (ytm-radio--process-diagnostic stdout stderr-file))))
      (kill-buffer stdout)
      (delete-file stderr-file))))

(defun ytm-radio--call-yt-dlp (url)
  "Fetch URL metadata from yt-dlp and return parsed JSON."
  (ytm-radio--ensure-program ytm-radio-yt-dlp-program "yt-dlp")
  (ytm-radio--call-json-process
   ytm-radio-yt-dlp-program
   (append ytm-radio-yt-dlp-extra-args
           (list "--flat-playlist"
                 "--dump-single-json"
                 url))
   (lambda (diagnostic)
     (user-error "Yt-dlp failed for %s: %s" url diagnostic))))

(defun ytm-radio--url-host (url)
  "Return the host component of URL, or an empty string."
  (or (url-host (url-generic-parse-url url)) ""))

(defun ytm-radio--music-url-p (url)
  "Return non-nil when URL points at YouTube Music."
  (string-match-p "\\(?:\\`\\|\\.\\)music\\.youtube\\.com\\'"
                  (ytm-radio--url-host url)))

(defun ytm-radio--url-has-query-key-p (url key)
  "Return non-nil when URL has query parameter KEY."
  (let ((query (url-filename (url-generic-parse-url url))))
    (and query
         (string-match-p
          (concat "[?&]" (regexp-quote key) "=")
          query))))

(defun ytm-radio--source-kind (url json)
  "Return a source kind for URL and yt-dlp JSON."
  (cond ((ytm-radio--music-url-p url)
         (if (or (map-elt json 'entries)
                 (ytm-radio--url-has-query-key-p url "list"))
             'youtube-music-playlist
           'youtube-music-track))
        ((string-match-p "/@" url)
         'youtube-channel)
        ((or (map-elt json 'entries)
             (ytm-radio--url-has-query-key-p url "list"))
         'youtube-playlist)
        (t 'youtube-track)))

(defun ytm-radio--fallback-track-url (source-url id)
  "Return a watch URL for ID using SOURCE-URL to pick the host."
  (format "https://%s/watch?v=%s"
          (if (ytm-radio--music-url-p source-url)
              "music.youtube.com"
            "www.youtube.com")
          id))

(defun ytm-radio--best-thumbnail-url (json)
  "Return the best thumbnail URL in JSON, or nil."
  (or (map-elt json 'thumbnail)
      (when-let* ((thumbnails (map-elt json 'thumbnails))
                  (last-thumbnail (car (last thumbnails))))
        (map-elt last-thumbnail 'url))))

(defun ytm-radio--track-url (json source-url)
  "Return the playable URL for JSON from SOURCE-URL."
  (let ((url (or (map-elt json 'webpage_url)
                 (map-elt json 'original_url)
                 (map-elt json 'url))))
    (cond ((and (stringp url)
                (string-match-p "\\`https?://" url))
           url)
          ((map-elt json 'id)
           (ytm-radio--fallback-track-url source-url (map-elt json 'id)))
          (t source-url))))

(defun ytm-radio--track-from-json (json source-id source-kind source-url)
  "Return a track from JSON.
SOURCE-ID and SOURCE-KIND identify the owner.  SOURCE-URL is used to
build a watch URL when yt-dlp returns only a video id."
  (ytm-radio--make-track
   :id (or (map-elt json 'id) (ytm-radio--track-url json source-url))
   :title (or (map-elt json 'title)
              (map-elt json 'track)
              (map-elt json 'fulltitle)
              "")
   :url (ytm-radio--track-url json source-url)
   :duration (map-elt json 'duration)
   :artist (or (map-elt json 'artist)
               (map-elt json 'uploader)
               (map-elt json 'channel))
   :album (map-elt json 'album)
   :thumbnail-url (ytm-radio--best-thumbnail-url json)
   :source-id source-id
   :source-kind source-kind))

(defun ytm-radio--source-id (json url)
  "Return a stable source id from JSON and URL."
  (or (map-elt json 'playlist_id)
      (map-elt json 'channel_id)
      (map-elt json 'id)
      url))

(defun ytm-radio--source-title-from-json (json url)
  "Return a display title from JSON and URL."
  (or (map-elt json 'title)
      (map-elt json 'playlist_title)
      (map-elt json 'channel)
      url))

(defun ytm-radio--source-from-json (json url)
  "Normalize yt-dlp JSON from URL into a source alist."
  (let* ((id (ytm-radio--source-id json url))
         (kind (ytm-radio--source-kind url json))
         (entries (or (map-elt json 'entries) (list json)))
         (tracks (seq-keep
                  (lambda (entry)
                    (when (and entry
                               (or (map-elt entry 'id)
                                   (map-elt entry 'url)
                                   (not (map-elt json 'entries))))
                      (ytm-radio--track-from-json entry id kind url)))
                  entries)))
    (ytm-radio--make-source
     :id id
     :kind kind
     :title (ytm-radio--source-title-from-json json url)
     :url url
     :tracks tracks
     :items tracks
     :continuation nil)))

(defun ytm-radio--fetch-source (url)
  "Fetch URL through yt-dlp and return a normalized source."
  (ytm-radio--source-from-json (ytm-radio--call-yt-dlp url) url))

;;; Account helper

(defun ytm-radio--ensure-readable-file (file label)
  "Signal a user error unless FILE named LABEL is readable."
  (unless (and file (file-readable-p file))
    (user-error "%s is not configured or readable" label)))

(defun ytm-radio--helper-limit (target)
  "Return the configured helper limit for TARGET."
  (if (equal target "home")
      ytm-radio-helper-home-limit
    ytm-radio-helper-library-limit))

(defun ytm-radio--helper-browse-arguments (target)
  "Return helper arguments for browsing TARGET."
  (append (list "browse" target)
          (when ytm-radio-helper-auth-file
            (list "--auth" (expand-file-name ytm-radio-helper-auth-file)))
          (when ytm-radio-helper-use-mock-data
            (list "--mock"))
          (list "--limit"
                (number-to-string (ytm-radio--helper-limit target)))))

(defun ytm-radio--helper-browse-id-arguments (browse-id &optional params)
  "Return helper arguments for browsing YouTube Music BROWSE-ID and PARAMS."
  (append (list "browse-id" browse-id)
          (when (and (stringp params)
                     (not (string-empty-p params)))
            (list "--params" params))
          (when ytm-radio-helper-auth-file
            (list "--auth" (expand-file-name ytm-radio-helper-auth-file)))
          (when ytm-radio-helper-use-mock-data
            (list "--mock"))
          (list "--limit"
                (number-to-string ytm-radio-helper-library-limit))))

(defun ytm-radio--helper-search-arguments (query)
  "Return helper arguments for searching YouTube Music for QUERY."
  (append (list "search" query)
          (when ytm-radio-helper-auth-file
            (list "--auth" (expand-file-name ytm-radio-helper-auth-file)))
          (when ytm-radio-helper-use-mock-data
            (list "--mock"))
          (list "--limit"
                (number-to-string ytm-radio-helper-library-limit))))

(defun ytm-radio--helper-import-browser-arguments (browser output)
  "Return helper arguments for importing BROWSER cookies into OUTPUT."
  (list "auth"
        "import-browser"
        "--browser"
        browser
        "--output"
        (expand-file-name output)
        "--yt-dlp"
        ytm-radio-yt-dlp-program))

(defun ytm-radio--helper-import-headers-arguments (input output)
  "Return helper arguments for importing request headers from INPUT into OUTPUT."
  (list "auth"
        "import-headers"
        "--input"
        (expand-file-name input)
        "--output"
        (expand-file-name output)))

(defun ytm-radio--helper-import-dia-arguments (output &optional restart)
  "Return helper arguments for importing Dia login into OUTPUT.
When RESTART is non-nil, allow the helper to restart Dia once."
  (append (list "auth"
                "import-dia"
                "--output"
                (expand-file-name output)
                "--port"
                (number-to-string ytm-radio-helper-dia-cdp-port)
                "--app"
                (expand-file-name ytm-radio-helper-dia-app))
          (when restart
            (list "--restart"))))

(defun ytm-radio--auth-import-candidates ()
  "Return login source candidates for `ytm-radio-auth-import'."
  (delete-dups (append ytm-radio-helper-browser-candidates
                       (list "dia"))))

(defun ytm-radio--dia-auth-source-p (source)
  "Return non-nil when SOURCE names Dia."
  (string-equal (downcase (string-trim source)) "dia"))

(defun ytm-radio--call-helper (arguments)
  "Run the external helper with ARGUMENTS and return parsed JSON."
  (ytm-radio--ensure-program ytm-radio-helper-command "ytm-radio-helper")
  (ytm-radio--call-json-process
   ytm-radio-helper-command
   arguments
   (lambda (diagnostic)
     (user-error "Account helper failed: %s" diagnostic))))

(defun ytm-radio--helper-envelope-data (envelope)
  "Return the data alist from helper ENVELOPE."
  (unless (map-elt envelope 'ok)
    (user-error "Account helper returned an error"))
  (unless (equal (map-elt envelope 'schema) 1)
    (user-error "Unsupported helper schema %S" (map-elt envelope 'schema)))
  (or (map-elt envelope 'data)
      (user-error "Account helper returned no data")))

(defun ytm-radio--symbol-value (value fallback)
  "Return VALUE as a symbol, or FALLBACK when VALUE is absent."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t fallback)))

(defun ytm-radio--track-from-helper-item (item source-id source-kind)
  "Return a ytm-radio track from helper ITEM.
SOURCE-ID and SOURCE-KIND identify the imported helper source."
  (ytm-radio--make-track
   :id (map-elt item 'id)
   :title (map-elt item 'title)
   :url (map-elt item 'url)
   :duration (map-elt item 'duration)
   :artist (map-elt item 'artist)
   :album (map-elt item 'album)
   :thumbnail-url (map-elt item 'thumbnail-url)
   :source-id source-id
   :source-kind source-kind))

(defun ytm-radio--helper-track-item-p (item)
  "Return non-nil when helper ITEM is playable."
  (and item
       (member (or (map-elt item 'type) "track")
               '("track" "episode"))
       (map-elt item 'url)))

(defun ytm-radio--source-from-helper (source)
  "Return a ytm-radio source from helper SOURCE."
  (let* ((id (map-elt source 'id))
         (kind (ytm-radio--symbol-value (map-elt source 'kind)
                                        'account))
         (items (or (map-elt source 'items)
                    (map-elt source 'tracks)
                    nil))
         (tracks (seq-keep
                  (lambda (item)
                    (when (ytm-radio--helper-track-item-p item)
                      (ytm-radio--track-from-helper-item item id kind)))
                  items)))
    (ytm-radio--make-source
     :id id
     :kind kind
     :title (map-elt source 'title)
     :url (map-elt source 'url)
     :tracks tracks
     :items items
     :continuation (map-elt source 'continuation)
     :subtitle (map-elt source 'subtitle)
     :thumbnail-url (map-elt source 'thumbnail-url))))

(defun ytm-radio--helper-sources (data)
  "Return normalized sources from helper DATA."
  (seq-keep #'ytm-radio--source-from-helper
            (or (map-elt data 'sources) nil)))

(defun ytm-radio--helper-target-source-p (source target)
  "Return non-nil when SOURCE belongs to helper TARGET."
  (let ((id (or (map-elt source :id) ""))
        (kind (symbol-name (or (map-elt source :kind) 'unknown))))
    (pcase target
      ("home"
       (or (string-prefix-p "ytm:home" id)
           (member kind '("youtube-music-home"
                          "youtube-music-home-section"))))
      ("explore"
       (or (string-prefix-p "ytm:explore" id)
           (member kind '("youtube-music-explore"
                          "youtube-music-explore-section"))))
      ("library"
       (or (string-prefix-p "ytm:library" id)
           (member kind '("youtube-music-library"
                          "youtube-music-library-section"
                          "youtube-music-liked"))))
      ("library-songs"
       (string-prefix-p "ytm:library:songs" id))
      ("library-albums"
       (string-prefix-p "ytm:library:albums" id))
      ("library-artists"
       (string-prefix-p "ytm:library:artists" id))
      ("library-playlists"
       (string-prefix-p "ytm:library:playlists" id))
      ("liked"
       (or (string-prefix-p "ytm:library:liked" id)
           (string-equal kind "youtube-music-liked")))
      ("search"
       (or (string-prefix-p "ytm:search" id)
           (string-equal kind "youtube-music-search")))
      (_ nil))))

(defun ytm-radio--drop-helper-target-sources (target)
  "Remove existing helper sources for TARGET from state."
  (setf (map-elt ytm-radio--state :sources)
        (seq-remove
         (lambda (cell)
           (ytm-radio--helper-target-source-p (cdr cell) target))
         (ytm-radio--sources))))

(defun ytm-radio--import-sources (sources)
  "Import SOURCES into state and return the number imported."
  (dolist (source sources)
    (ytm-radio--put-source source))
  (ytm-radio--save)
  (ytm-radio--render)
  (length sources))

(defun ytm-radio--fetch-helper-sources (arguments)
  "Return helper sources fetched with ARGUMENTS."
  (ytm-radio--helper-sources
   (ytm-radio--helper-envelope-data
    (ytm-radio--call-helper arguments))))

(defun ytm-radio--fetch-helper-target-sources (target)
  "Return helper sources for TARGET."
  (ytm-radio--fetch-helper-sources
   (ytm-radio--helper-browse-arguments target)))

(defun ytm-radio--fetch-helper-browse-id-sources (browse-id &optional params)
  "Return helper sources for YouTube Music BROWSE-ID and PARAMS."
  (ytm-radio--fetch-helper-sources
   (ytm-radio--helper-browse-id-arguments browse-id params)))

(defun ytm-radio--import-helper-target (target label)
  "Import helper TARGET and report LABEL."
  (ytm-radio--ensure-loaded)
  (unless ytm-radio-helper-use-mock-data
    (ytm-radio--ensure-readable-file
     ytm-radio-helper-auth-file
     "YouTube Music helper auth file"))
  (let* ((sources (ytm-radio--fetch-helper-target-sources target))
         (track-count (seq-reduce
                       (lambda (count source)
                         (+ count (length (map-elt source :tracks))))
                       sources
                       0)))
    (unless sources
      (user-error "No %s returned" label))
    (ytm-radio--drop-helper-target-sources target)
    (ytm-radio--import-sources sources)
    (message "Imported %s: %d sources, %d tracks"
             label
             (length sources)
             track-count)))

;;; Playback

(defun ytm-radio--mpv-raw-options-argument ()
  "Return the mpv ytdl raw options argument, or nil."
  (when ytm-radio-ytdl-raw-options
    (concat "--ytdl-raw-options="
            (mapconcat #'identity ytm-radio-ytdl-raw-options ","))))

(defun ytm-radio--mpv-arguments (socket url)
  "Return mpv arguments for SOCKET and media URL."
  (append ytm-radio-mpv-extra-args
          (delq nil (list (ytm-radio--mpv-raw-options-argument)
                          "--no-video"
                          (concat "--input-ipc-server=" socket)
                          url))))

(defun ytm-radio--set-status (status)
  "Set player STATUS and refresh the UI."
  (setf (map-elt ytm-radio--player :status) status)
  (ytm-radio--render))

(defun ytm-radio--stop-process ()
  "Stop the current mpv process and IPC connection."
  (let ((process (map-elt ytm-radio--player :process))
        (ipc-process (map-elt ytm-radio--player :ipc-process)))
    (ytm-radio--cancel-progress-render)
    (setf (map-elt ytm-radio--player :process) nil
          (map-elt ytm-radio--player :ipc-process) nil
          (map-elt ytm-radio--player :socket) nil
          (map-elt ytm-radio--player :position) nil
          (map-elt ytm-radio--player :duration) nil
          (map-elt ytm-radio--player :status) 'stopped)
    (when (process-live-p ipc-process)
      (delete-process ipc-process))
    (when (process-live-p process)
      (delete-process process))))

(defun ytm-radio--play-track (track)
  "Play TRACK with mpv."
  (ytm-radio--ensure-program ytm-radio-mpv-program "mpv")
  (unless (map-elt track :url)
    (user-error "Track has no playable URL"))
  (ytm-radio--stop-process)
  (let* ((socket (make-temp-name
                  (file-name-concat temporary-file-directory "ytm-radio-mpv-")))
         (args (ytm-radio--mpv-arguments socket (map-elt track :url)))
         (process (apply #'start-process
                         "ytm-radio-mpv" nil ytm-radio-mpv-program args)))
    (set-process-sentinel process #'ytm-radio--mpv-sentinel)
    (setf (map-elt ytm-radio--player :process) process
          (map-elt ytm-radio--player :socket) socket
          (map-elt ytm-radio--player :current-track) track
          (map-elt ytm-radio--player :status) 'loading
          (map-elt ytm-radio--player :position) nil
          (map-elt ytm-radio--player :duration) (map-elt track :duration)
          (map-elt ytm-radio--state :last-track-id) (map-elt track :id))
    (ytm-radio--save)
    (ytm-radio--mpv-connect socket process 0)
    (ytm-radio--render)
    (ytm-radio--show-now-playing nil)))

(defun ytm-radio--mpv-connect (socket process attempt)
  "Connect to mpv SOCKET for PROCESS, retrying from ATTEMPT."
  (when (and (< attempt 40)
             (process-live-p process)
             (eq process (map-elt ytm-radio--player :process)))
    (condition-case nil
        (let ((ipc (make-network-process
                    :name "ytm-radio-mpv-ipc"
                    :family 'local
                    :service socket
                    :coding 'utf-8
                    :noquery t
                    :filter #'ytm-radio--mpv-filter)))
          (process-put ipc 'pending "")
          (process-put ipc 'request-id 0)
          (process-put ipc 'callbacks (make-hash-table :test 'eql))
          (setf (map-elt ytm-radio--player :ipc-process) ipc)
          (ytm-radio--mpv-send (list "observe_property" 1 "pause"))
          (ytm-radio--mpv-send (list "observe_property" 2 "core-idle"))
          (ytm-radio--mpv-send (list "observe_property" 3 "time-pos"))
          (ytm-radio--mpv-send (list "observe_property" 4 "duration")))
      (error
       (run-at-time 0.05 nil
                    #'ytm-radio--mpv-connect socket process (1+ attempt))))))

(defun ytm-radio--mpv-send (command)
  "Send COMMAND to the current mpv IPC process."
  (when-let* ((ipc (map-elt ytm-radio--player :ipc-process))
              ((process-live-p ipc)))
    (process-send-string
     ipc
     (concat (json-encode (list (cons 'command command))) "\n"))))

(defun ytm-radio--render-now-playing-without-fit ()
  "Render the now-playing buffer without resizing its child frame."
  (let ((ytm-radio--inhibit-frame-fit t))
    (ytm-radio--render-now-playing)))

(defun ytm-radio--run-progress-render ()
  "Run a pending throttled progress refresh."
  (setq ytm-radio--progress-render-timer nil)
  (ytm-radio--render-now-playing-without-fit))

(defun ytm-radio--schedule-progress-render ()
  "Schedule a throttled now-playing progress refresh."
  (unless (timerp ytm-radio--progress-render-timer)
    (setq ytm-radio--progress-render-timer
          (run-at-time 0.5 nil #'ytm-radio--run-progress-render))))

(defun ytm-radio--cancel-progress-render ()
  "Cancel any pending now-playing progress refresh."
  (when (timerp ytm-radio--progress-render-timer)
    (cancel-timer ytm-radio--progress-render-timer)
    (setq ytm-radio--progress-render-timer nil)))

(defun ytm-radio--set-playback-property (property value)
  "Set playback PROPERTY to VALUE and refresh the now-playing view."
  (setf (map-elt ytm-radio--player property) value)
  (if (eq property :position)
      (ytm-radio--schedule-progress-render)
    (ytm-radio--render-now-playing-without-fit)))

(defun ytm-radio--mpv-filter (process output)
  "Parse newline-delimited JSON OUTPUT from mpv PROCESS."
  (let ((pending (concat (process-get process 'pending) output)))
    (while (string-match "\n" pending)
      (ytm-radio--mpv-dispatch process
                               (substring pending 0 (match-beginning 0)))
      (setq pending (substring pending (match-end 0))))
    (process-put process 'pending pending)))

(defun ytm-radio--mpv-dispatch (_process line)
  "Dispatch one mpv JSON message LINE."
  (when-let* ((msg (ignore-errors
                     (json-parse-string line
                                        :object-type 'alist
                                        :null-object nil
                                        :false-object nil)))
              (event (map-elt msg 'event)))
    (ytm-radio--mpv-event event msg)))

(defun ytm-radio--mpv-event (event msg)
  "Mirror mpv EVENT and MSG into player state."
  (pcase event
    ("property-change"
     (pcase (map-elt msg 'name)
       ("pause"
        (ytm-radio--set-status (if (map-elt msg 'data) 'paused 'playing)))
       ("core-idle"
        (when (not (map-elt msg 'data))
          (ytm-radio--set-status 'playing)))
       ("time-pos"
        (ytm-radio--set-playback-property :position (map-elt msg 'data)))
       ("duration"
        (ytm-radio--set-playback-property :duration (map-elt msg 'data)))))
    ("end-file"
     (when (equal (map-elt msg 'reason) "error")
       (ytm-radio--set-status 'stopped)
       (message "Playback error: %s"
                (or (map-elt msg 'file_error) "unknown error"))))))

(defun ytm-radio--mpv-sentinel (process _event)
  "Advance when mpv PROCESS exits cleanly."
  (when (and (not (process-live-p process))
             (eq process (map-elt ytm-radio--player :process)))
    (if-let* ((current (map-elt ytm-radio--player :current-track))
              (next (and (zerop (process-exit-status process))
                         (ytm-radio--next-track current t))))
        (ytm-radio--play-track next)
      (ytm-radio--stop-process)
      (ytm-radio--render))))

(defun ytm-radio--same-track-p (left right)
  "Return non-nil when LEFT and RIGHT identify the same track."
  (and left
       right
       (equal (map-elt left :id) (map-elt right :id))))

(defun ytm-radio--random-track (&optional except)
  "Return a random known track, avoiding EXCEPT when possible."
  (let* ((tracks (ytm-radio--all-tracks))
         (candidates (seq-remove
                      (lambda (track)
                        (ytm-radio--same-track-p track except))
                      tracks))
         (choices (if candidates candidates tracks)))
    (when choices
      (nth (random (length choices)) choices))))

(defun ytm-radio--neighbor-track (track direction)
  "Return TRACK's neighbor in DIRECTION, either `next' or `previous'."
  (let ((tracks (ytm-radio--all-tracks)))
    (pcase direction
      ('next
       (seq-first
        (cdr (seq-drop-while
              (lambda (other)
                (not (equal (map-elt other :id) (map-elt track :id))))
              tracks))))
      ('previous
       (seq-first
        (seq-reverse
         (seq-take-while
          (lambda (other)
            (not (equal (map-elt other :id) (map-elt track :id))))
          tracks)))))))

(defun ytm-radio--next-track (track &optional automatic)
  "Return the known track after TRACK.
When AUTOMATIC is non-nil, honor single-track repeat."
  (cond
   ((and automatic (eq (map-elt ytm-radio--player :repeat) 'one))
    track)
   ((map-elt ytm-radio--player :shuffle)
    (ytm-radio--random-track track))
   ((ytm-radio--neighbor-track track 'next))
   ((eq (map-elt ytm-radio--player :repeat) 'list)
    (car (ytm-radio--all-tracks)))))

(defun ytm-radio--previous-track (track)
  "Return the known track before TRACK."
  (cond
   ((map-elt ytm-radio--player :shuffle)
    (ytm-radio--random-track track))
   ((ytm-radio--neighbor-track track 'previous))
   ((eq (map-elt ytm-radio--player :repeat) 'list)
    (car (last (ytm-radio--all-tracks))))))

;;; UI

(defvar ytm-radio--mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ytm-radio-add-url)
    (define-key map (kbd "A") #'ytm-radio-auth-import)
    (define-key map (kbd "c") #'ytm-radio-now-playing)
    (define-key map (kbd "E") #'ytm-radio-import-ytmusic-explore)
    (define-key map (kbd "L") #'ytm-radio-import-ytmusic-library)
    (define-key map (kbd "i") #'ytm-radio-import-ytmusic-liked)
    (define-key map (kbd "r") #'ytm-radio-import-ytmusic-home)
    (define-key map (kbd "RET") #'ytm-radio-open-at-point)
    (define-key map (kbd "o") #'ytm-radio-open-at-point)
    (define-key map (kbd "l") #'ytm-radio-open-at-point)
    (define-key map (kbd "j") #'ytm-radio-next-item)
    (define-key map (kbd "k") #'ytm-radio-previous-item)
    (define-key map (kbd "<down>") #'ytm-radio-next-item)
    (define-key map (kbd "<up>") #'ytm-radio-previous-item)
    (define-key map (kbd "g") #'ytm-radio-refresh)
    (define-key map (kbd "/") #'ytm-radio-search)
    (define-key map (kbd "TAB") #'ytm-radio-next-section)
    (define-key map (kbd "<backtab>") #'ytm-radio-previous-section)
    (define-key map (kbd "b") #'ytm-radio-back)
    (define-key map (kbd "h") #'ytm-radio-back)
    (define-key map (kbd "s") #'ytm-radio-play-source)
    (define-key map (kbd "SPC") #'ytm-radio-toggle-pause)
    (define-key map (kbd "n") #'ytm-radio-next)
    (define-key map (kbd "p") #'ytm-radio-previous)
    (define-key map (kbd "S") #'ytm-radio-share)
    (define-key map (kbd "f") #'ytm-radio-seek-forward)
    (define-key map (kbd "B") #'ytm-radio-seek-backward)
    (define-key map (kbd "q") #'ytm-radio-hide)
    map)
  "Keymap for `ytm-radio--mode'.")

(define-derived-mode ytm-radio--mode special-mode "ytm-radio"
  "Major mode for the ytm-radio browser buffer."
  (setq-local mode-line-format nil)
  (setq-local imenu-create-index-function
              #'ytm-radio--imenu-create-index))

(defvar ytm-radio--now-playing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'ytm-radio-toggle-pause)
    (define-key map (kbd "n") #'ytm-radio-next)
    (define-key map (kbd "p") #'ytm-radio-previous)
    (define-key map (kbd "r") #'ytm-radio-cycle-repeat)
    (define-key map (kbd "s") #'ytm-radio-toggle-shuffle)
    (define-key map (kbd "S") #'ytm-radio-share)
    (define-key map (kbd "q") #'ytm-radio-hide)
    (dolist (command '(scroll-up-command scroll-down-command
                       scroll-up scroll-down scroll-left scroll-right
                       mwheel-scroll pixel-scroll-precision))
      (define-key map (vector 'remap command) #'ignore))
    map)
  "Keymap for `ytm-radio--now-playing-mode'.")

(define-derived-mode ytm-radio--now-playing-mode special-mode "ytm-radio-now"
  "Major mode for the ytm-radio now-playing child frame."
  (setq-local mode-line-format nil)
  (setq-local cursor-type nil)
  (setq-local truncate-lines nil)
  (setq-local overflow-newline-into-fringe t)
  (setq-local fringe-indicator-alist
              (assq-delete-all
               'continuation
               (assq-delete-all 'truncation
                                (copy-tree fringe-indicator-alist))))
  (setq-local left-fringe-width 0)
  (setq-local right-fringe-width 0)
  (setq-local vertical-scroll-bar nil)
  (setq-local horizontal-scroll-bar nil)
  (setq-local indicate-buffer-boundaries nil)
  (setq-local indicate-empty-lines nil)
  (setq-local cursor-in-non-selected-windows nil)
  (add-hook 'window-scroll-functions #'ytm-radio--prevent-scroll nil t))

(defun ytm-radio--prevent-scroll (window start)
  "Keep WINDOW pinned to the top when START is moved by scrolling."
  (when (> start (point-min))
    (set-window-start window (point-min) t)))

(defun ytm-radio--buffer ()
  "Return the ytm-radio browser buffer, creating it when needed."
  (let ((buffer (get-buffer-create ytm-radio--library-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ytm-radio--mode)
        (ytm-radio--mode)))
    buffer))

(defun ytm-radio--now-playing-buffer ()
  "Return the now-playing buffer, creating it when needed."
  (let ((buffer (get-buffer-create ytm-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ytm-radio--now-playing-mode)
        (ytm-radio--now-playing-mode)))
    buffer))

(defun ytm-radio--track-title (track)
  "Return TRACK's display title."
  (or (and-let* ((title (map-elt track :title))
                 ((not (string-empty-p title))))
        title)
      (map-elt track :id)
      "Untitled"))

(defun ytm-radio--source-display-title (source)
  "Return SOURCE's display title."
  (or (map-elt source :title)
      (map-elt source :id)
      "Untitled source"))

(defun ytm-radio--track-label (track)
  "Return the completion label for TRACK."
  (let* ((source (ytm-radio--source (map-elt track :source-id)))
         (source-title (if source
                           (ytm-radio--source-display-title source)
                         (or (map-elt track :source-id) "Unknown source"))))
    (format "%s - %s" source-title (ytm-radio--track-title track))))

(defun ytm-radio--format-status ()
  "Return the current player status as a string."
  (symbol-name (or (map-elt ytm-radio--player :status) 'idle)))

(defun ytm-radio--format-duration (seconds)
  "Return SECONDS as a compact duration string."
  (when (numberp seconds)
    (setq seconds (floor seconds))
    (if (>= seconds 3600)
	        (format "%d:%02d:%02d"
	                (/ seconds 3600)
	                (% (/ seconds 60) 60)
	                (% seconds 60))
	      (format "%d:%02d" (/ seconds 60) (% seconds 60)))))

(defconst ytm-radio--progress-bar-max-width 16
  "Maximum number of cells used for the now-playing progress bar.")

(defconst ytm-radio--progress-bar-min-width 5
  "Minimum number of cells used for the now-playing progress bar.")

(defconst ytm-radio--progress-line-safety-columns 2
  "Extra text columns reserved to keep the progress line from wrapping.")

(defconst ytm-radio--progress-line-safety-pixels 2
  "Extra pixels reserved to keep the progress line from wrapping.")

(defun ytm-radio--progress-line-pixel-safety ()
  "Return a pixel safety margin for now-playing progress lines."
  (+ ytm-radio--progress-line-safety-pixels
     (* ytm-radio--progress-line-safety-columns
        (frame-char-width (ytm-radio--now-playing-frame)))))

(defun ytm-radio--progress-bar (position duration width)
  "Return a Unicode progress bar for POSITION, DURATION, and WIDTH.
When DURATION is not known, return a fixed-width placeholder bar."
  (when (>= width ytm-radio--progress-bar-min-width)
    (if (and (numberp duration)
             (> duration 0))
        (let* ((position (if (numberp position)
                             (min duration (max 0 position))
                           0))
               (ratio (/ (float position) duration))
               (filled (min width
                            (floor (* ratio width)))))
          (concat
           (propertize (make-string filled ?▰)
                       'face 'ytm-radio-progress-filled)
           (propertize (make-string (- width filled) ?▱) 'face 'shadow)))
      (propertize (make-string width ?▱) 'face 'shadow))))

(defun ytm-radio--progress-line-text (left-label bar right-label)
  "Return progress line text using LEFT-LABEL, BAR, and RIGHT-LABEL."
  (format "%s %s %s" left-label bar right-label))

(defun ytm-radio--progress-line-fits-p (line)
  "Return non-nil when progress LINE fits on one now-playing line."
  (if (display-graphic-p (ytm-radio--now-playing-frame))
      (<= (string-pixel-width line (current-buffer))
          (- (ytm-radio--now-playing-text-pixel-width)
             (ytm-radio--progress-line-pixel-safety)))
    (<= (string-width line)
        (- (ytm-radio--now-playing-text-width)
           ytm-radio--progress-line-safety-columns))))

(defun ytm-radio--progress-bar-width (left-label right-label position duration)
  "Return a progress bar width for POSITION and DURATION.
The bar is measured between LEFT-LABEL and RIGHT-LABEL."
  (let ((available (- (ytm-radio--now-playing-text-width)
                      (string-width left-label)
                      (string-width right-label)
                      2
                      ytm-radio--progress-line-safety-columns)))
    (when (>= available ytm-radio--progress-bar-min-width)
      (cl-loop
       for width downfrom (min ytm-radio--progress-bar-max-width available)
       downto ytm-radio--progress-bar-min-width
       for bar = (ytm-radio--progress-bar position duration width)
       for line = (and bar
                       (ytm-radio--progress-line-text
                        left-label bar right-label))
       when (and line (ytm-radio--progress-line-fits-p line))
       return width))))

(defun ytm-radio--playback-time-label (track)
  "Return a compact playback time label for TRACK."
  (let* ((position (map-elt ytm-radio--player :position))
         (duration (or (map-elt ytm-radio--player :duration)
                       (map-elt track :duration)))
         (position-label (ytm-radio--format-duration position))
         (duration-label (ytm-radio--format-duration duration))
         (left-label (or position-label "0:00"))
         (right-label (or duration-label "--:--")))
    (if-let* ((bar-width (ytm-radio--progress-bar-width left-label
                                                        right-label
                                                        position
                                                        duration))
              (bar (ytm-radio--progress-bar position duration bar-width)))
        (ytm-radio--progress-line-text left-label bar right-label)
      (let ((fallback (format "%s/%s" left-label right-label)))
        (if (ytm-radio--progress-line-fits-p fallback)
            fallback
          (ytm-radio--truncate fallback
                               (ytm-radio--now-playing-text-width)))))))

(defun ytm-radio--item-title (item)
  "Return ITEM's display title."
  (or (map-elt item 'title)
      (map-elt item :title)
      (map-elt item 'id)
      (map-elt item :id)
      "Untitled"))

(defun ytm-radio--item-type (item)
  "Return ITEM's display type."
  (or (map-elt item 'type)
      (map-elt item :type)
      (when (or (map-elt item :source-id)
                (ytm-radio--helper-track-item-p item))
        "track")
      "item"))

(defun ytm-radio--item-url (item)
  "Return ITEM's URL, if any."
  (or (map-elt item 'url)
      (map-elt item :url)))

(defun ytm-radio--item-browse-id (item)
  "Return ITEM's YouTube Music browse id, if any."
  (or (map-elt item 'browse-id)
      (map-elt item :browse-id)))

(defun ytm-radio--item-browse-params (item)
  "Return ITEM's YouTube Music browse params, if any."
  (or (map-elt item 'browse-params)
      (map-elt item :browse-params)))

(defun ytm-radio--item-playlist-id (item)
  "Return ITEM's YouTube Music playlist id, if any."
  (or (map-elt item 'playlist-id)
      (map-elt item :playlist-id)))

(defun ytm-radio--item-detail (item)
  "Return compact secondary text for ITEM."
  (string-join
   (delq nil
         (list (or (map-elt item 'artist) (map-elt item :artist))
               (or (map-elt item 'album) (map-elt item :album))
               (or (map-elt item 'subtitle) (map-elt item :subtitle))
               (ytm-radio--format-duration
                (or (map-elt item 'duration) (map-elt item :duration)))))
   " - "))

(defun ytm-radio--item-summary (item)
  "Return a one-line summary for ITEM."
  (string-join
   (delq nil
         (list (ytm-radio--item-type item)
               (let ((detail (ytm-radio--item-detail item)))
                 (unless (string-empty-p detail)
                   detail))))
   " | "))

(defun ytm-radio--item-type-label (item)
  "Return a compact fixed-width type label for ITEM."
  (pcase (ytm-radio--item-type item)
    ("track" (ytm-radio--mdicon "nf-md-music_note" "SONG"))
    ("playlist" (ytm-radio--mdicon "nf-md-playlist_music" "LIST"))
    ("album" (ytm-radio--mdicon "nf-md-album" "ALBM"))
    ("artist" (ytm-radio--mdicon "nf-md-account_music" "ARTS"))
    ("podcast" (ytm-radio--mdicon "nf-md-podcast" "POD"))
    ("episode" (ytm-radio--mdicon "nf-md-radio" "EP"))
    (_ "ITEM")))

(defun ytm-radio--item-type-face (item)
  "Return the face used for ITEM's compact type label."
  (pcase (ytm-radio--item-type item)
    ("track" 'success)
    ("episode" 'success)
    ((or "playlist" "album") 'font-lock-keyword-face)
    ((or "artist" "podcast") 'font-lock-type-face)
    (_ 'shadow)))

(defun ytm-radio--truncate (text width)
  "Return TEXT truncated to WIDTH display columns."
  (truncate-string-to-width (or text "") width nil nil "..."))

(defun ytm-radio--pad-right (text width)
  "Return TEXT padded on the right to display WIDTH columns."
  (let* ((text (or text ""))
         (padding (max 0 (- width (string-width text)))))
    (concat text (make-string padding ?\s))))

(defun ytm-radio--item-id (item)
  "Return ITEM's id, if any."
  (or (map-elt item 'id)
      (map-elt item :id)))

(defun ytm-radio--item-thumbnail-url (item)
  "Return ITEM's thumbnail URL, deriving a YouTube fallback when possible."
  (or (map-elt item 'thumbnail-url)
      (map-elt item :thumbnail-url)
      (when (string-equal (ytm-radio--item-type item) "track")
        (when-let* ((id (ytm-radio--item-id item))
                    ((string-match-p "\\`[[:alnum:]_-]+\\'" id)))
          (format "https://i.ytimg.com/vi/%s/hqdefault.jpg" id)))))

(defun ytm-radio--view-kind ()
  "Return the kind of the current browser view."
  (if (symbolp ytm-radio--browser-view)
      ytm-radio--browser-view
    (or (map-elt ytm-radio--browser-view :kind) 'home)))

(defun ytm-radio--view-value (key)
  "Return current browser view value for KEY."
  (unless (symbolp ytm-radio--browser-view)
    (map-elt ytm-radio--browser-view key)))

(defun ytm-radio--set-browser-view (view &optional replace)
  "Set browser VIEW and remember history unless REPLACE is non-nil."
  (unless replace
    (push ytm-radio--browser-view ytm-radio--browser-history))
  (setq ytm-radio--browser-view view)
  (ytm-radio--render-browser t))

(defun ytm-radio--source-kind-string (source)
  "Return SOURCE kind as a string."
  (symbol-name (or (map-elt source :kind) 'unknown)))

(defun ytm-radio--home-source-p (source)
  "Return non-nil when SOURCE belongs to the Home view."
  (let ((id (or (map-elt source :id) ""))
        (kind (ytm-radio--source-kind-string source)))
    (or (string-prefix-p "ytm:home" id)
        (member kind '("youtube-music-home"
                       "youtube-music-home-section")))))

(defun ytm-radio--library-source-p (source)
  "Return non-nil when SOURCE belongs to the Library view."
  (let ((id (or (map-elt source :id) ""))
        (kind (ytm-radio--source-kind-string source)))
    (or (string-prefix-p "ytm:library" id)
        (member kind '("youtube-music-library"
                       "youtube-music-library-section"
                       "youtube-music-liked")))))

(defun ytm-radio--explore-source-p (source)
  "Return non-nil when SOURCE belongs to the Explore view."
  (let ((id (or (map-elt source :id) ""))
        (kind (ytm-radio--source-kind-string source)))
    (or (string-prefix-p "ytm:explore" id)
        (member kind '("youtube-music-explore"
                       "youtube-music-explore-section")))))

(defun ytm-radio--search-source-p (source)
  "Return non-nil when SOURCE belongs to the Search view."
  (let ((id (or (map-elt source :id) ""))
        (kind (ytm-radio--source-kind-string source)))
    (or (string-prefix-p "ytm:search" id)
        (string-equal kind "youtube-music-search"))))

(defun ytm-radio--browser-sources ()
  "Return sources selected by the current browser view."
  (let ((sources (map-values (ytm-radio--sources))))
    (pcase (ytm-radio--view-kind)
      ('home
       (or (seq-filter #'ytm-radio--home-source-p sources)
           sources))
      ('explore
       (seq-filter #'ytm-radio--explore-source-p sources))
      ('library
       (seq-filter #'ytm-radio--library-source-p sources))
      ('search
       (seq-filter #'ytm-radio--search-source-p sources))
      ('section
       (when-let* ((id (ytm-radio--view-value :source-id))
                   (source (ytm-radio--source id)))
         (list source)))
      ('detail
       (seq-keep #'ytm-radio--source (ytm-radio--view-value :source-ids)))
      ('all sources)
      (_ sources))))

(defun ytm-radio--browser-title ()
  "Return title for the current browser view."
  (pcase (ytm-radio--view-kind)
    ('home "Home")
    ('explore "Explore")
    ('library "Library")
    ('search (or (ytm-radio--view-value :title) "Search"))
    ('section (or (ytm-radio--view-value :title) "Section"))
    ('detail (or (ytm-radio--view-value :title) "Detail"))
    ('all "All")
    (_ "Home")))

(defun ytm-radio--browser-title-visible-p ()
  "Return non-nil when the current browser view needs an inline title."
  (memq (ytm-radio--view-kind) '(search detail)))

(defun ytm-radio--point-property (property)
  "Return PROPERTY at point or the previous character."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) property))))

(defun ytm-radio--source-at-point ()
  "Return source stored at point, or nil."
  (ytm-radio--point-property 'ytm-radio-source))

(defun ytm-radio--item-at-point ()
  "Return item stored at point, or nil."
  (ytm-radio--point-property 'ytm-radio-item))

(defun ytm-radio--line-source-at-point ()
  "Return the nearest source stored on the current line."
  (or (ytm-radio--source-at-point)
      (save-excursion
        (beginning-of-line)
        (let ((end (line-end-position))
              source)
          (while (and (not source) (< (point) end))
            (setq source (get-text-property (point) 'ytm-radio-source))
            (goto-char (or (next-single-property-change
                            (point) 'ytm-radio-source nil end)
                           end)))
          source))))

(defun ytm-radio--enter-source (source)
  "Show SOURCE as a focused section."
  (ytm-radio--set-browser-view
   (list (cons :kind 'section)
         (cons :source-id (map-elt source :id))
         (cons :title (ytm-radio--source-display-title source)))))

(defun ytm-radio--playlist-browse-id (playlist-id)
  "Return the YouTube Music browse id for PLAYLIST-ID."
  (when (and (stringp playlist-id)
             (not (string-empty-p playlist-id)))
    (if (or (string-prefix-p "VL" playlist-id)
            (string-prefix-p "RD" playlist-id))
        playlist-id
      (concat "VL" playlist-id))))

(defun ytm-radio--url-query-value (query key)
  "Return KEY's value from URL QUERY string."
  (let ((value (cdr (assoc key (url-parse-query-string (or query ""))))))
    (if (listp value)
        (car value)
      value)))

(defun ytm-radio--music-url-detail-browse-id (url)
  "Return the detail browse id represented by YouTube Music URL."
  (when (and (stringp url)
             (string-match-p "\\`https?://" url))
    (let* ((parsed (url-generic-parse-url url))
           (host (downcase (or (url-host parsed) "")))
           (path (or (url-filename parsed) ""))
           (query-start (string-match-p "\\?" path))
           (path-only (if query-start
                          (substring path 0 query-start)
                        path))
           (query (and query-start
                       (substring path (1+ query-start)))))
      (when (string-suffix-p "music.youtube.com" host)
        (cond
         ((string-match "\\`/browse/\\([^/?#]+\\)" path-only)
          (match-string 1 path-only))
         ((string-equal path-only "/playlist")
          (ytm-radio--playlist-browse-id
           (ytm-radio--url-query-value query "list"))))))))

(defun ytm-radio--browse-endpoint (browse-id &optional params)
  "Return a helper browse endpoint for BROWSE-ID and PARAMS."
  (when (and (stringp browse-id)
             (not (string-empty-p browse-id)))
    (cons browse-id params)))

(defun ytm-radio--item-detail-browse (item)
  "Return ITEM's detail browse endpoint when it should use the helper."
  (let* ((type (ytm-radio--item-type item))
         (id (ytm-radio--item-id item))
         (playlist-browse-id
          (ytm-radio--playlist-browse-id (ytm-radio--item-playlist-id item)))
         (url-browse-id
         (ytm-radio--music-url-detail-browse-id (ytm-radio--item-url item)))
         (fallback-browse-id
          (when (member type '("album" "artist" "playlist" "podcast" "episode" "item"))
            (cond
             ((and id (string-prefix-p "MPRE" id)) id)
             ((and id (string-prefix-p "MPSP" id)) id)
             ((and id (string-prefix-p "MPED" id)) id)
             ((and id (string-prefix-p "UC" id)) id)
             ((and id (or (string-prefix-p "VL" id)
                          (string-prefix-p "RD" id)))
              id)
             ((and id (string-equal type "playlist"))
              (ytm-radio--playlist-browse-id id))))))
    (or (ytm-radio--browse-endpoint
         (ytm-radio--item-browse-id item)
         (ytm-radio--item-browse-params item))
        (ytm-radio--browse-endpoint playlist-browse-id)
        (ytm-radio--browse-endpoint url-browse-id)
        (ytm-radio--browse-endpoint fallback-browse-id))))

(defun ytm-radio--item-detail-browse-id (item)
  "Return ITEM's detail browse id when it should open through the helper."
  (car-safe (ytm-radio--item-detail-browse item)))

(defun ytm-radio--open-url-as-source (url)
  "Fetch URL as a source and show it without starting playback."
  (let ((source (ytm-radio--fetch-source url)))
    (ytm-radio--put-source source)
    (ytm-radio--save)
    (ytm-radio--enter-source source)))

(defun ytm-radio--open-browse-id-as-source (browse-id &optional params)
  "Fetch YouTube Music BROWSE-ID as a source and show it.
PARAMS is the optional YouTube Music browse endpoint params string."
  (unless ytm-radio-helper-use-mock-data
    (ytm-radio--ensure-readable-file
     ytm-radio-helper-auth-file
     "YouTube Music helper auth file"))
  (let ((sources (ytm-radio--fetch-helper-browse-id-sources browse-id params)))
    (unless sources
      (user-error "No YouTube Music detail returned for %s" browse-id))
    (ytm-radio--import-sources sources)
    (if (cdr sources)
        (ytm-radio--set-browser-view
         (list (cons :kind 'detail)
               (cons :source-ids (mapcar (lambda (source)
                                            (map-elt source :id))
                                          sources))
               (cons :title (ytm-radio--source-display-title (car sources))))
         t)
      (ytm-radio--enter-source (car sources)))))

(defun ytm-radio--open-item (source item)
  "Open ITEM from SOURCE using the browser's default action."
  (let ((track (ytm-radio--item-track item source))
        (browse (ytm-radio--item-detail-browse item))
        (url (ytm-radio--item-url item)))
    (cond
     (track
      (ytm-radio--play-track track))
     (browse
      (ytm-radio--open-browse-id-as-source (car browse) (cdr browse)))
     (url
      (ytm-radio--open-url-as-source url))
     (t
      (user-error "Item has no action")))))

(defun ytm-radio--section-positions ()
  "Return positions of rendered browser section headings."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (get-text-property (point) 'ytm-radio-section)
          (push (point) positions))
        (goto-char (or (next-single-property-change
                        (point) 'ytm-radio-section nil (point-max))
                       (point-max)))))
    (nreverse positions)))

(defun ytm-radio--imenu-create-index ()
  "Return an imenu index for Home, Explore, and Library sections."
  (when (memq (ytm-radio--view-kind) '(home explore library))
    (let (index)
      (dolist (position (ytm-radio--section-positions))
        (when-let* ((source (get-text-property position 'ytm-radio-source)))
          (push (cons (ytm-radio--source-display-title source) position)
                index)))
      (nreverse index))))

(defun ytm-radio--line-item-at-point ()
  "Return the item stored on the current line, or nil."
  (or (ytm-radio--item-at-point)
      (save-excursion
        (beginning-of-line)
        (let ((end (line-end-position))
              item)
          (while (and (not item) (< (point) end))
            (setq item (get-text-property (point) 'ytm-radio-item))
            (goto-char (or (next-single-property-change
                            (point) 'ytm-radio-item nil end)
                           end)))
          item))))

(defun ytm-radio--first-property-position (property)
  "Return the first buffer position containing PROPERTY, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (position)
      (while (and (not position) (< (point) (point-max)))
        (when (get-text-property (point) property)
          (setq position (point)))
        (goto-char (or (next-single-property-change
                        (point) property nil (point-max))
                       (point-max))))
      position)))

(defun ytm-radio--browser-start-position ()
  "Return the preferred browser content start position."
  (or (ytm-radio--first-property-position 'ytm-radio-item)
      (ytm-radio--first-property-position 'ytm-radio-section)
      (point-min)))

(defun ytm-radio--restore-browser-point (old-point reset)
  "Restore browser point after render.
OLD-POINT is the buffer position before render.  When RESET is non-nil,
move to the preferred content start."
  (if reset
      (goto-char (ytm-radio--browser-start-position))
    (goto-char (min (max old-point (point-min)) (point-max)))
    (when (eobp)
      (goto-char (ytm-radio--browser-start-position)))))

(defun ytm-radio--move-item-line (direction)
  "Move point to the next item line in DIRECTION."
  (let ((origin (point))
        (current (ytm-radio--line-item-at-point))
        (step (if (< direction 0) -1 1))
        (found nil))
    (while (and (not found)
                (= 0 (forward-line step)))
      (when-let* ((candidate (ytm-radio--line-item-at-point)))
        (when (or (not current)
                  (not (eq candidate current)))
          (setq found t))))
    (unless found
      (goto-char origin)
      (user-error (if (< direction 0) "No previous item" "No next item")))))

(defun ytm-radio--view-import-spec (view)
  "Return the helper import spec for browser VIEW, or nil."
  (pcase (if (symbolp view) view (map-elt view :kind))
    ('home '("home" . "home recommendations"))
    ('explore '("explore" . "explore"))
    ('library '("library" . "library"))
    (_ nil)))

(defun ytm-radio--select-browser-view (view)
  "Switch to browser VIEW, clearing old content before loading when needed."
  (ytm-radio--set-browser-view view)
  (when-let* ((import-spec (ytm-radio--view-import-spec view))
              ((not (ytm-radio--browser-sources))))
    (let ((ytm-radio--browser-loading-message
           (format "Loading %s..." (ytm-radio--browser-title))))
      (ytm-radio--render-browser)
      (redisplay t))
    (ytm-radio--import-helper-target (car import-spec) (cdr import-spec))
    (ytm-radio--set-browser-view view t)))

(defun ytm-radio--initial-home-import-available-p ()
  "Return non-nil when ytm-radio can load Home without prompting."
  (or ytm-radio-helper-use-mock-data
      (and ytm-radio-helper-auth-file
           (file-readable-p ytm-radio-helper-auth-file))))

(defun ytm-radio--maybe-refresh-initial-home ()
  "Refresh Home once on first browser open when account access is available."
  (when (and (eq (ytm-radio--view-kind) 'home)
             (not ytm-radio--initial-home-refreshed)
             (ytm-radio--initial-home-import-available-p))
    (let ((ytm-radio--browser-loading-message "Loading Home..."))
      (ytm-radio--render-browser t)
      (redisplay t))
    (ytm-radio--import-helper-target "home" "home recommendations")
    (setq ytm-radio--initial-home-refreshed t)
    (ytm-radio--set-browser-view 'home t)))

(defun ytm-radio--insert-button (label command)
  "Insert a text button with LABEL running COMMAND."
  (insert-text-button label
                      'action (lambda (_button)
                                (call-interactively command))
                      'follow-link t
                      'face 'ytm-radio-button))

(defun ytm-radio--insert-action-button (label action &optional face)
  "Insert a text button with LABEL running ACTION.
When FACE is non-nil, use it as the button face."
  (insert-text-button label
                      'action (lambda (_button)
                                (funcall action))
                      'follow-link t
                      'face (or face 'ytm-radio-button)))

(defun ytm-radio--insert-view-button (label view active)
  "Insert a browser tab LABEL for VIEW, marking ACTIVE tabs."
  (let ((start (point)))
    (insert-text-button label
                        'action (lambda (_button)
                                  (ytm-radio--select-browser-view view))
                        'follow-link t
                        'face (if active
                                  'ytm-radio-active-tab
                                'ytm-radio-button))
    (add-text-properties start (point)
                         (list 'ytm-radio-view view))))

(defun ytm-radio--insert-browser-tabs ()
  "Insert browser view tabs."
  (let ((kind (ytm-radio--view-kind)))
    (ytm-radio--insert-view-button "Home" 'home (eq kind 'home))
    (insert "   ")
    (ytm-radio--insert-view-button "Explore" 'explore (eq kind 'explore))
    (insert "   ")
    (ytm-radio--insert-view-button "Library" 'library (eq kind 'library))
    (insert "   ")
    (ytm-radio--insert-view-button "Search" 'search (eq kind 'search))
    (insert "\n")))

(defun ytm-radio--insert-browser-heading-padding ()
  "Insert thin vertical padding after the browser heading block."
  (insert ytm-radio--browser-heading-padding))

(defun ytm-radio--item-track (item source)
  "Return ITEM as a track owned by SOURCE, or nil."
  (cond
   ((map-elt item :source-id)
    item)
   ((ytm-radio--helper-track-item-p item)
    (ytm-radio--track-from-helper-item
     item
     (map-elt source :id)
     (or (map-elt source :kind) 'account)))))

(defun ytm-radio--play-source-object (source)
  "Play the first track in SOURCE."
  (let ((track (car (map-elt source :tracks))))
    (unless track
      (user-error "Source has no playable tracks"))
    (ytm-radio--play-track track)))

(defun ytm-radio--browser-thumbnail-pixel-size ()
  "Return the thumbnail edge size for two-line browser rows."
  (* 2 (ytm-radio--browser-thumbnail-row-height)))

(defun ytm-radio--browser-thumbnail-row-height ()
  "Return one rendered text row height in pixels for thumbnails."
  (max (frame-char-height (selected-frame))
       (ceiling (/ (float ytm-radio-browser-thumbnail-size) 2))))

(defun ytm-radio--browser-thumbnail-slot-width ()
  "Return thumbnail slot width in pixels."
  (ytm-radio--browser-thumbnail-pixel-size))

(defun ytm-radio--browser-thumbnail-columns ()
  "Return the display columns reserved for browser thumbnails."
  (let ((char-width (max 1 (frame-char-width (selected-frame)))))
    (max 6 (ceiling (/ (float (ytm-radio--browser-thumbnail-slot-width))
                       char-width)))))

(defun ytm-radio--item-type-cell (item)
  "Return ITEM's fixed-width type cell."
  (ytm-radio--pad-right (ytm-radio--item-type-label item) 4))

(defun ytm-radio--thumbnail-space ()
  "Return an empty thumbnail-width display string."
  (if (display-graphic-p)
      (propertize " "
                  'display
                  `(space :width (,(ytm-radio--browser-thumbnail-slot-width))))
    (make-string (ytm-radio--browser-thumbnail-columns) ?\s)))

(defun ytm-radio--buffer-u8 (position)
  "Return the unsigned byte at POSITION in the current unibyte buffer."
  (char-after position))

(defun ytm-radio--buffer-u16-be (position)
  "Return an unsigned big-endian 16-bit integer at POSITION."
  (+ (ash (ytm-radio--buffer-u8 position) 8)
     (ytm-radio--buffer-u8 (1+ position))))

(defun ytm-radio--buffer-u16-le (position)
  "Return an unsigned little-endian 16-bit integer at POSITION."
  (+ (ytm-radio--buffer-u8 position)
     (ash (ytm-radio--buffer-u8 (1+ position)) 8)))

(defun ytm-radio--buffer-u32-be (position)
  "Return an unsigned big-endian 32-bit integer at POSITION."
  (+ (ash (ytm-radio--buffer-u8 position) 24)
     (ash (ytm-radio--buffer-u8 (1+ position)) 16)
     (ash (ytm-radio--buffer-u8 (+ position 2)) 8)
     (ytm-radio--buffer-u8 (+ position 3))))

(defun ytm-radio--jpeg-dimensions ()
  "Return JPEG dimensions from the current unibyte buffer, or nil."
  (when (and (>= (point-max) 4)
             (= (ytm-radio--buffer-u8 1) #xff)
             (= (ytm-radio--buffer-u8 2) #xd8))
    (let ((position 3)
          dimensions)
      (while (and (not dimensions) (< position (point-max)))
        (while (and (< position (point-max))
                    (/= (ytm-radio--buffer-u8 position) #xff))
          (setq position (1+ position)))
        (while (and (< position (point-max))
                    (= (ytm-radio--buffer-u8 position) #xff))
          (setq position (1+ position)))
        (when (< position (point-max))
          (let ((marker (ytm-radio--buffer-u8 position)))
            (setq position (1+ position))
            (cond
             ((memq marker '(#xd8 #xd9 #x01)))
             ((= marker #xda)
              (setq position (point-max)))
             ((<= (+ position 8) (point-max))
              (let ((segment-length (ytm-radio--buffer-u16-be position)))
                (when (and (>= segment-length 7)
                           (memq marker '(#xc0 #xc1 #xc2 #xc3
                                           #xc5 #xc6 #xc7
                                           #xc9 #xca #xcb
                                           #xcd #xce #xcf)))
                  (setq dimensions
                        (cons (ytm-radio--buffer-u16-be (+ position 5))
                              (ytm-radio--buffer-u16-be (+ position 3)))))
                (setq position (+ position segment-length))))))))
      dimensions)))

(defun ytm-radio--png-dimensions ()
  "Return PNG dimensions from the current unibyte buffer, or nil."
  (when (and (>= (point-max) 24)
             (equal (buffer-substring-no-properties 1 9)
                    "\211PNG\r\n\032\n")
             (equal (buffer-substring-no-properties 13 17) "IHDR"))
    (cons (ytm-radio--buffer-u32-be 17)
          (ytm-radio--buffer-u32-be 21))))

(defun ytm-radio--gif-dimensions ()
  "Return GIF dimensions from the current unibyte buffer, or nil."
  (when (and (>= (point-max) 10)
             (member (buffer-substring-no-properties 1 7)
                     '("GIF87a" "GIF89a")))
    (cons (ytm-radio--buffer-u16-le 7)
          (ytm-radio--buffer-u16-le 9))))

(defun ytm-radio--image-file-dimensions (file)
  "Return image dimensions in pixels for FILE, or nil."
  (or (when-let* ((image (ignore-errors (create-image file nil nil))))
        (ignore-errors (image-size image t (selected-frame))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 4096)
        (or (ytm-radio--jpeg-dimensions)
            (ytm-radio--png-dimensions)
            (ytm-radio--gif-dimensions)))))

(defun ytm-radio--browser-thumbnail-display-size (file)
  "Return thumbnail display size for FILE without cropping."
  (let* ((slot-width (ytm-radio--browser-thumbnail-slot-width))
         (slot-height (ytm-radio--browser-thumbnail-pixel-size))
         (dimensions (ytm-radio--image-file-dimensions file)))
    (if (not dimensions)
        (cons slot-width slot-height)
      (let* ((natural-width (max 1 (ceiling (car dimensions))))
             (natural-height (max 1 (ceiling (cdr dimensions))))
             (scale (min (/ (float slot-width) natural-width)
                         (/ (float slot-height) natural-height))))
        (cons (max 1 (round (* natural-width scale)))
              (max 1 (round (* natural-height scale))))))))

(defun ytm-radio--image-mime-type (file)
  "Return a MIME type for image FILE, or nil when unsupported."
  (pcase (image-supported-file-p file)
    ('jpeg "image/jpeg")
    ('jpg "image/jpeg")
    ('png "image/png")
    ('gif "image/gif")
    ('webp "image/webp")
    ('svg "image/svg+xml")))

(defun ytm-radio--fit-rect (width height bounds-width bounds-height)
  "Return WIDTH and HEIGHT fitted inside BOUNDS-WIDTH by BOUNDS-HEIGHT."
  (let* ((scale (min (/ (float bounds-width) (max 1 width))
                     (/ (float bounds-height) (max 1 height))))
         (fit-width (max 1 (round (* width scale))))
         (fit-height (max 1 (round (* height scale)))))
    (list fit-width fit-height
          (/ (- bounds-width fit-width) 2)
          (/ (- bounds-height fit-height) 2))))

(defun ytm-radio--fill-rect (width height bounds-width bounds-height)
  "Return WIDTH and HEIGHT scaled to cover BOUNDS-WIDTH by BOUNDS-HEIGHT."
  (let* ((scale (max (/ (float bounds-width) (max 1 width))
                     (/ (float bounds-height) (max 1 height))))
         (fill-width (max 1 (round (* width scale))))
         (fill-height (max 1 (round (* height scale)))))
    (list fill-width fill-height
          (/ (- bounds-width fill-width) 2)
          (/ (- bounds-height fill-height) 2))))

(defun ytm-radio--browser-header-width ()
  "Return the pixel width for browser detail header images."
  (let* ((window (get-buffer-window (current-buffer)))
         (body-width (if window
                         (window-body-width window t)
                       (frame-pixel-width)))
         (char-width (max 1 (frame-char-width)))
         (width (- body-width (* 2 char-width))))
    (max 240 (min 920 width))))

(defun ytm-radio--svg-source-header-image (file title subtitle)
  "Return an SVG image using FILE as a dimmed TITLE and SUBTITLE background."
  (when (and (featurep 'svg)
             (image-type-available-p 'svg)
             (fboundp 'svg-create)
             (file-readable-p file))
    (when-let* ((mime-type (ytm-radio--image-mime-type file))
                (dimensions (ytm-radio--image-file-dimensions file)))
      (let* ((width (ytm-radio--browser-header-width))
             (height ytm-radio-browser-header-height)
             (svg (svg-create width height))
             (fill (ytm-radio--fill-rect (ceiling (car dimensions))
                                         (ceiling (cdr dimensions))
                                         width
                                         height))
             (title-columns (max 16 (floor (/ width 12))))
             (subtitle-columns (max 24 (floor (/ width 9))))
             (title (ytm-radio--truncate title title-columns))
             (subtitle (ytm-radio--truncate subtitle subtitle-columns))
             (text-x 20)
             (title-y (- height (if (string-empty-p subtitle) 32 48)))
             (subtitle-y (- height 24)))
        (condition-case nil
            (progn
              (if (fboundp 'svg-embed-base-uri-image)
                  (svg-embed-base-uri-image
                   svg
                   (file-name-nondirectory file)
                   :x (nth 2 fill)
                   :y (nth 3 fill)
                   :width (nth 0 fill)
                   :height (nth 1 fill))
                (svg-embed
                 svg
                 file
                 mime-type
                 nil
                 :x (nth 2 fill)
                 :y (nth 3 fill)
                 :width (nth 0 fill)
                 :height (nth 1 fill)))
              (svg-rectangle svg 0 0 width height
                             :fill "#141414"
                             :opacity 0.68)
              (svg-rectangle svg 0 0 width height
                             :fill "none"
                             :stroke "#4b5050"
                             :stroke-width 1)
              (svg-text svg title
                        :x text-x
                        :y title-y
                        :fill "#f4f1df"
                        :font-size 24
                        :font-family "monospace"
                        :font-weight "bold")
              (unless (string-empty-p subtitle)
                (svg-text svg subtitle
                          :x text-x
                          :y subtitle-y
                          :fill "#b9b4bc"
                          :font-size 15
                          :font-family "monospace"))
              (svg-image svg
                         :ascent 'center
                         :width width
                         :height height
                         :scale 1.0
                         :base-uri file))
          (error nil))))))

(defun ytm-radio--svg-thumbnail-image (file)
  "Return a fixed-canvas SVG thumbnail image for FILE, or nil."
  (when (and ytm-radio-browser-thumbnail-workaround-gaps
             (featurep 'svg)
             (image-type-available-p 'svg)
             (fboundp 'svg-create)
             (file-readable-p file))
    (when-let* ((mime-type (ytm-radio--image-mime-type file))
                (dimensions (ytm-radio--image-file-dimensions file)))
      (let* ((slot-width (ytm-radio--browser-thumbnail-slot-width))
             (slot-height (* 2 (ytm-radio--browser-thumbnail-row-height)))
             (svg (svg-create slot-width slot-height))
             (fit (ytm-radio--fit-rect (ceiling (car dimensions))
                                       (ceiling (cdr dimensions))
                                       slot-width
                                       slot-height)))
        (condition-case nil
            (progn
              (if (fboundp 'svg-embed-base-uri-image)
                  (svg-embed-base-uri-image
                   svg
                   (file-name-nondirectory file)
                   :x (nth 2 fit)
                   :y (nth 3 fit)
                   :width (nth 0 fit)
                   :height (nth 1 fit))
                (svg-embed
                 svg
                 file
                 mime-type
                 nil
                 :x (nth 2 fit)
                 :y (nth 3 fit)
                 :width (nth 0 fit)
                 :height (nth 1 fit)))
              (svg-image svg
                         :ascent 'center
                         :width slot-width
                         :height slot-height
                         :scale 1.0
                         :base-uri file))
          (error nil))))))

(defun ytm-radio--placeholder-thumbnail-label (item)
  "Return a compact placeholder label for ITEM."
  (pcase (ytm-radio--item-type item)
    ("track" "TR")
    ("playlist" "PL")
    ("album" "AL")
    ("artist" "AR")
    (_ "YT")))

(defun ytm-radio--placeholder-thumbnail-fill (item)
  "Return placeholder fill color for ITEM."
  (pcase (ytm-radio--item-type item)
    ("track" "#23352f")
    ("playlist" "#263244")
    ("album" "#392f46")
    ("artist" "#2f3b35")
    (_ "#303336")))

(defun ytm-radio--placeholder-thumbnail-image (item)
  "Return a fixed-canvas placeholder thumbnail image for ITEM."
  (when (and (display-graphic-p)
             (featurep 'svg)
             (image-type-available-p 'svg)
             (fboundp 'svg-create))
    (let* ((slot-width (ytm-radio--browser-thumbnail-slot-width))
           (slot-height (ytm-radio--browser-thumbnail-pixel-size))
           (font-size (max 9 (floor (* slot-width 0.28))))
           (svg (svg-create slot-width slot-height)))
      (svg-rectangle svg 0 0 slot-width slot-height
                     :fill (ytm-radio--placeholder-thumbnail-fill item))
      (svg-rectangle svg 0 0 slot-width slot-height
                     :fill "none"
                     :stroke "#4b5050"
                     :stroke-width 1)
      (svg-text svg (ytm-radio--placeholder-thumbnail-label item)
                :x (/ slot-width 2)
                :y (/ slot-height 2)
                :fill "#d8dfd0"
                :font-size font-size
                :font-family "monospace"
                :font-weight "bold"
                :text-anchor "middle"
                :dominant-baseline "central")
      (list (svg-image svg
                       :ascent 'center
                       :width slot-width
                       :height slot-height
                       :scale 1.0)
            slot-width
            slot-height
            'fixed-canvas))))

(defun ytm-radio--thumbnail-image-from-file (file)
  "Return thumbnail image data for FILE."
  (when-let* ((size (ytm-radio--browser-thumbnail-display-size file))
              (image (or (ytm-radio--svg-thumbnail-image file)
                         (ignore-errors
                           (create-image file nil nil
                                         :width (car size)
                                         :height (cdr size)
                                         :ascent 'center)))))
    (when (eq (car-safe image) 'image)
      (if (eq (plist-get (cdr image) :type) 'svg)
          (list image
                (ytm-radio--browser-thumbnail-slot-width)
                (ytm-radio--browser-thumbnail-pixel-size)
                'fixed-canvas)
        (list image (car size) (cdr size))))))

(defun ytm-radio--item-thumbnail-image (item)
  "Return ITEM's thumbnail image data when available."
  (when (display-graphic-p)
    (let* ((url (ytm-radio--item-thumbnail-url item))
           (file (and url
                      (ytm-radio--ensure-cover-file
                       url
                       (lambda (_url _file)
                         (ytm-radio--render-browser))))))
      (or (and file (ytm-radio--thumbnail-image-from-file file))
          (ytm-radio--placeholder-thumbnail-image item)))))

(defun ytm-radio--thumbnail-slice (thumbnail slice)
  "Return THUMBNAIL display string for top or bottom SLICE."
  (let* ((row-height (ytm-radio--browser-thumbnail-row-height))
         (display (if (eq (nth 3 thumbnail) 'fixed-canvas)
                      `((slice 0
                               ,(if (eq slice 'top)
                                    0
                                  (max 0 (1- row-height)))
                               1.0
                               ,row-height)
                        ,(car thumbnail))
                    `((slice 0.0
                             ,(if (eq slice 'top) 0.0 0.49)
                             1.0001
                             0.51005)
                      ,(car thumbnail)))))
    (propertize " " 'display display 'line-height t)))

(defun ytm-radio--thumbnail-full (thumbnail)
  "Return THUMBNAIL display string for a compact single-line row."
  (propertize " " 'display (car thumbnail) 'line-height t))

(defun ytm-radio--insert-pixel-space (pixels)
  "Insert a horizontal display space of PIXELS."
  (when (> pixels 0)
    (insert (propertize " "
                        'display `(space :width (,pixels))))))

(defun ytm-radio--insert-thumbnail-cell (thumbnail slice)
  "Insert a thumbnail cell using THUMBNAIL and SLICE.
SLICE is either `top', `bottom', or nil for the full placeholder."
  (insert "  ")
  (cond
   ((and thumbnail (memq slice '(top bottom)))
    (let* ((image-width (cadr thumbnail))
           (empty-width (max 0 (- (ytm-radio--browser-thumbnail-slot-width)
                                  image-width)))
           (left-pad (/ empty-width 2))
           (right-pad (- empty-width left-pad)))
      (ytm-radio--insert-pixel-space left-pad)
      (insert (ytm-radio--thumbnail-slice thumbnail slice))
      (ytm-radio--insert-pixel-space right-pad)))
   (thumbnail
    (let* ((image-width (cadr thumbnail))
           (empty-width (max 0 (- (ytm-radio--browser-thumbnail-slot-width)
                                  image-width)))
           (left-pad (/ empty-width 2))
           (right-pad (- empty-width left-pad)))
      (ytm-radio--insert-pixel-space left-pad)
      (insert (ytm-radio--thumbnail-full thumbnail))
      (ytm-radio--insert-pixel-space right-pad)))
   (t
    (insert (ytm-radio--thumbnail-space))))
  (insert "  "))

(defun ytm-radio--item-prefix-string (index _type-cell _item)
  "Return the first-line item prefix for INDEX."
  (propertize (format "%02d " index) 'face 'shadow))

(defun ytm-radio--item-detail-prefix-string (_index type-cell item)
  "Return the second-line item prefix for TYPE-CELL and ITEM."
  (propertize type-cell 'face (ytm-radio--item-type-face item)))

(defun ytm-radio--insert-aligned-prefix (prefix peer-prefix)
  "Insert PREFIX padded to align with PEER-PREFIX, plus a text gap."
  (insert prefix)
  (if (display-graphic-p)
      (let* ((prefix-width (string-pixel-width prefix (current-buffer)))
             (peer-width (string-pixel-width peer-prefix (current-buffer)))
             (gap-width (string-pixel-width "  " (current-buffer)))
             (target-width (+ (max prefix-width peer-width) gap-width)))
        (ytm-radio--insert-pixel-space (- target-width prefix-width)))
    (insert (make-string
             (+ (max 0 (- (string-width peer-prefix)
                          (string-width prefix)))
                2)
             ?\s))))

(defun ytm-radio--insert-item-prefix (prefix peer-prefix)
  "Insert item PREFIX aligned with PEER-PREFIX."
  (ytm-radio--insert-aligned-prefix prefix peer-prefix))

(defun ytm-radio--insert-detail-prefix (prefix peer-prefix)
  "Insert detail PREFIX aligned with PEER-PREFIX."
  (ytm-radio--insert-aligned-prefix prefix peer-prefix))

(defun ytm-radio--insert-item-row-newline (gapless)
  "Insert a row newline.
When GAPLESS is non-nil, remove extra line spacing between thumbnail
slices so covers do not appear split in the middle."
  (insert (if gapless
              (propertize "\n" 'line-height t)
            "\n")))

(defun ytm-radio--insert-source-item (source item index &optional compact)
  "Insert ITEM from SOURCE at one-based INDEX.
When COMPACT is non-nil, render only the title row."
  (let* ((start (point))
         (title (ytm-radio--truncate (ytm-radio--item-title item) 56))
         (detail (ytm-radio--truncate (ytm-radio--item-detail item) 84))
         (type-cell (ytm-radio--item-type-cell item))
         (prefix (ytm-radio--item-prefix-string index type-cell item))
         (detail-prefix
          (ytm-radio--item-detail-prefix-string index type-cell item))
         (thumbnail (ytm-radio--item-thumbnail-image item))
         (two-line-p (or thumbnail (not (string-empty-p detail))))
         (gapless-thumbnail-p (and thumbnail two-line-p))
         (track (ytm-radio--item-track item source))
         (actionable (or track
                         (ytm-radio--item-detail-browse-id item)
                         (ytm-radio--item-url item))))
    (ytm-radio--insert-thumbnail-cell thumbnail
                                      (if (and two-line-p (not compact))
                                          'top
                                        nil))
    (ytm-radio--insert-item-prefix prefix detail-prefix)
    (if actionable
        (ytm-radio--insert-action-button
         title
         (lambda () (ytm-radio--open-item source item))
         'ytm-radio-item-title)
      (insert title))
    (ytm-radio--insert-item-row-newline (and gapless-thumbnail-p
                                             (not compact)))
    (when (and two-line-p (not compact))
      (ytm-radio--insert-thumbnail-cell thumbnail 'bottom)
      (ytm-radio--insert-detail-prefix detail-prefix prefix)
      (unless (string-empty-p detail)
        (insert (propertize detail 'face 'shadow)))
      (insert "\n"))
    (add-text-properties start (point)
                         (list 'ytm-radio-source source
                               'ytm-radio-item item))))

(defun ytm-radio--source-items (source)
  "Return display items for SOURCE."
  (or (map-elt source :items)
      (map-elt source :tracks)
      nil))

(defun ytm-radio--source-subtitle (source)
  "Return SOURCE subtitle, if any."
  (or (map-elt source :subtitle)
      (map-elt source 'subtitle)))

(defun ytm-radio--source-thumbnail-url (source)
  "Return SOURCE thumbnail URL, if any."
  (or (map-elt source :thumbnail-url)
      (map-elt source 'thumbnail-url)))

(defun ytm-radio--source-header-p (source)
  "Return non-nil when SOURCE is a metadata-only detail header."
  (and (null (ytm-radio--source-items source))
       (or (ytm-radio--source-subtitle source)
           (ytm-radio--source-thumbnail-url source))))

(defun ytm-radio--source-header-background-image (source)
  "Return a detail header background image for SOURCE, if available."
  (when-let* ((url (and (display-graphic-p)
                        (ytm-radio--source-thumbnail-url source)))
              (file (ytm-radio--ensure-cover-file
                     url
                     (lambda (_url _file)
                       (ytm-radio--render-browser)))))
    (ytm-radio--svg-source-header-image
     file
     (ytm-radio--source-display-title source)
     (or (ytm-radio--source-subtitle source) ""))))

(defun ytm-radio--insert-source-header-background
    (source image title subtitle &optional omit-leading-space)
  "Insert SOURCE header using IMAGE background, TITLE, and SUBTITLE.
When OMIT-LEADING-SPACE is non-nil, do not insert the leading blank line."
  (let ((start (point)))
    (unless omit-leading-space
      (insert "\n"))
    (insert (propertize title
                        'display image
                        'line-height t))
    (unless (string-empty-p subtitle)
      (insert (propertize (concat " " subtitle)
                          'display "")))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'ytm-radio-section t
                               'ytm-radio-source source))))

(defun ytm-radio--insert-source-header (source &optional omit-leading-space)
  "Insert metadata-only SOURCE as a detail header.
When OMIT-LEADING-SPACE is non-nil, do not insert the leading blank line."
  (let* ((title (ytm-radio--source-display-title source))
         (subtitle (or (ytm-radio--source-subtitle source) ""))
         (background (ytm-radio--source-header-background-image source))
         (thumbnail
          (unless background
            (ytm-radio--item-thumbnail-image
             `((type . "artist")
               (title . ,title)
               (thumbnail-url . ,(ytm-radio--source-thumbnail-url source))))))
         (two-line-p (or thumbnail (not (string-empty-p subtitle)))))
    (if background
        (ytm-radio--insert-source-header-background
         source background title subtitle omit-leading-space)
      (let ((start (point)))
        (unless omit-leading-space
          (insert "\n"))
        (ytm-radio--insert-thumbnail-cell thumbnail (if two-line-p 'top nil))
        (insert (propertize title 'face 'ytm-radio-section-title))
        (insert "\n")
        (when two-line-p
          (ytm-radio--insert-thumbnail-cell thumbnail 'bottom)
          (unless (string-empty-p subtitle)
            (insert (propertize subtitle 'face 'shadow)))
          (insert "\n"))
        (add-text-properties start (point)
                             (list 'ytm-radio-section t
                                   'ytm-radio-source source))))))

(defun ytm-radio--render ()
  "Render all visible ytm-radio buffers."
  (ytm-radio--render-browser)
  (ytm-radio--render-now-playing))

(defun ytm-radio--insert-source-section (source &optional omit-leading-space)
  "Insert SOURCE as a browser section.
When OMIT-LEADING-SPACE is non-nil, do not insert the leading blank line."
  (if (ytm-radio--source-header-p source)
      (ytm-radio--insert-source-header source omit-leading-space)
    (let* ((items (ytm-radio--source-items source))
           (overview (not (eq (ytm-radio--view-kind) 'section)))
           (visible-items (if overview
                              (seq-take items ytm-radio--browser-section-limit)
                            items))
           (compact-items (eq (ytm-radio--view-kind) 'library))
           (start (point)))
      (unless omit-leading-space
        (insert "\n"))
      (insert-text-button (ytm-radio--source-display-title source)
                          'action (lambda (_button)
                                    (ytm-radio--enter-source source))
                          'follow-link t
                          'face 'ytm-radio-section-title)
      (add-text-properties start (point)
                           (list 'ytm-radio-section t
                                 'ytm-radio-source source))
      (insert "  "
              (propertize
               (format "%s / %d items / %d tracks"
                       (ytm-radio--source-kind-string source)
                       (length items)
                       (length (map-elt source :tracks)))
               'face 'shadow)
              "\n")
      (ytm-radio--insert-browser-heading-padding)
      (cl-loop for item in visible-items
               for index from 1
               do (ytm-radio--insert-source-item
                   source item index compact-items))
      (when (and overview (> (length items) (length visible-items)))
        (insert "       ")
        (ytm-radio--insert-action-button
         (format "%d more" (- (length items) (length visible-items)))
         (lambda () (ytm-radio--enter-source source)))
        (insert "\n")))))

(defun ytm-radio--render-browser (&optional reset-point)
  "Render the current package state into the browser buffer.
When RESET-POINT is non-nil, move point to the first browser content item."
  (when-let* ((buffer (get-buffer ytm-radio--library-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (sources (ytm-radio--browser-sources))
            (old-point (point)))
        (erase-buffer)
        (ytm-radio--insert-browser-tabs)
        (when (ytm-radio--browser-title-visible-p)
          (insert "\n")
          (insert (propertize (ytm-radio--browser-title) 'face 'bold)))
        (ytm-radio--insert-browser-heading-padding)
        (when (ytm-radio--empty-catalog-p)
          (insert "Add a URL, or import your YouTube Music library/home.\n")
          (insert "Use login once to import a browser session.\n"))
        (cond
         (ytm-radio--browser-loading-message
          (insert (propertize ytm-radio--browser-loading-message
                              'face 'shadow)
                  "\n"))
         ((ytm-radio--empty-catalog-p)
          (insert "No YouTube Music pages imported yet.\n"))
         ((not sources)
          (insert "No content in this view yet.\n"))
         (t
          (let ((omit-first-leading-space
                 (not (eq (ytm-radio--view-kind) 'library))))
            (cl-loop for source in sources
                     for first = t then nil
                     do (ytm-radio--insert-source-section
                         source
                         (and first omit-first-leading-space))))))
        (ytm-radio--restore-browser-point old-point reset-point)))))

(defun ytm-radio--cover-cache-path (url)
  "Return the local cache path for cover URL, or nil."
  (when (and (stringp url)
             (string-match-p "\\`https?://" url))
    (expand-file-name (concat (secure-hash 'sha1 url) ".jpg")
                      ytm-radio-cover-cache-directory)))

(defun ytm-radio--cover-file (url)
  "Return a cached local cover file for URL, or nil."
  (when-let* ((file (ytm-radio--cover-cache-path url)))
    (when (file-readable-p file)
      file)))

(defun ytm-radio--cache-cover (url callback)
  "Fetch cover URL asynchronously and call CALLBACK with URL and file."
  (when-let* ((file (ytm-radio--cover-cache-path url)))
    (unless (or (file-readable-p file)
                (gethash url ytm-radio--cover-downloads))
      (puthash url t ytm-radio--cover-downloads)
      (condition-case nil
          (progn
            (make-directory ytm-radio-cover-cache-directory t)
            (let* ((url-show-status nil)
                   (process
                    (url-retrieve
                     url
                     (lambda (status)
                       (unwind-protect
                           (progn
                             (remhash url ytm-radio--cover-downloads)
                             (unless (plist-get status :error)
                               (goto-char (point-min))
                               (when (search-forward "\n\n" nil t)
                                 (let ((coding-system-for-write 'binary))
                                   (write-region (point) (point-max)
                                                 file nil 'silent))
                                 (when (and callback (file-readable-p file))
                                   (funcall callback url file)))))
                         (kill-buffer (current-buffer))))
                     nil t t)))
              (unless process
                (remhash url ytm-radio--cover-downloads))))
        (error
         (remhash url ytm-radio--cover-downloads))))))

(defun ytm-radio--ensure-cover-file (url callback)
  "Return cached cover file for URL, scheduling CALLBACK if it is missing."
  (or (ytm-radio--cover-file url)
      (progn
        (ytm-radio--cache-cover url callback)
        nil)))

(defun ytm-radio--scaled-cover-size (natural-width natural-height)
  "Return cover display size for NATURAL-WIDTH and NATURAL-HEIGHT."
  (let* ((natural-width (max 1 natural-width))
         (natural-height (max 1 natural-height))
         (scale (min (/ (float ytm-radio-cover-max-width) natural-width)
                     (/ (float ytm-radio-cover-max-height) natural-height))))
    (cons (max 1 (round (* natural-width scale)))
          (max 1 (round (* natural-height scale))))))

(defun ytm-radio--cover-display-size (file)
  "Return display size for cover FILE, or nil."
  (when-let* ((image (ignore-errors (create-image file nil nil)))
              (dimensions (ignore-errors
                            (image-size image t
                                        (ytm-radio--now-playing-frame)))))
    (ytm-radio--scaled-cover-size (ceiling (car dimensions))
                                  (ceiling (cdr dimensions)))))

(defun ytm-radio--cover-spec (track)
  "Return an image spec and display size for TRACK's cover."
  (when-let* ((thumbnail (ytm-radio--track-thumbnail-url track))
              (file (and (display-graphic-p)
                         (ytm-radio--ensure-cover-file
                          thumbnail
                          (lambda (url _file)
                            (when-let* ((current (ytm-radio--current-track)))
                              (when (equal url
                                           (ytm-radio--track-thumbnail-url
                                            current))
                                (ytm-radio--render-now-playing)))))))
              (size (ytm-radio--cover-display-size file))
              (image (ignore-errors
                       (create-image file nil nil
                                     :width (car size)
                                     :height (cdr size)))))
    (list image size)))

(defun ytm-radio--track-thumbnail-url (track)
  "Return TRACK's thumbnail URL, deriving a YouTube fallback when needed."
  (or (map-elt track :thumbnail-url)
      (when-let* ((id (map-elt track :id))
                  ((string-match-p "\\`[[:alnum:]_-]+\\'" id)))
        (format "https://i.ytimg.com/vi/%s/hqdefault.jpg" id))))

(defun ytm-radio--insert-cover (cover-spec)
  "Insert COVER-SPEC's image or a textual placeholder."
  (insert ytm-radio--now-playing-thin-padding)
  (if-let* ((image (car-safe cover-spec)))
      (progn
        (insert (make-string ytm-radio--cover-left-padding-columns ?\s))
        (insert-image image "cover")
        (insert "\n"))
    (insert "[cover]\n")))

(defconst ytm-radio--now-playing-control-separator "  "
  "Separator used between compact now-playing controls.")

(defun ytm-radio--now-playing-controls-text ()
  "Return plain fallback text width for now-playing controls."
  (string-join (mapcar #'car (ytm-radio--now-playing-controls))
               ytm-radio--now-playing-control-separator))

(defun ytm-radio--now-playing-frame ()
  "Return the now-playing frame, or the selected frame as fallback."
  (if (frame-live-p ytm-radio--frame)
      ytm-radio--frame
    (selected-frame)))

(defun ytm-radio--now-playing-content-columns ()
  "Return the text columns used for the now-playing cover content."
  (let* ((frame (ytm-radio--now-playing-frame))
         (char-width (max 1 (frame-char-width frame)))
         (cover-width (or ytm-radio--cover-render-width
                          ytm-radio-cover-max-width))
         (cover-columns (ceiling cover-width char-width))
         (controls-columns (string-width
                            (ytm-radio--now-playing-controls-text))))
    (max 1 cover-columns controls-columns)))

(defun ytm-radio--now-playing-layout-columns ()
  "Return the total text columns used for the now-playing layout."
  (+ ytm-radio--cover-left-padding-columns
     (ytm-radio--now-playing-content-columns)))

(defun ytm-radio--now-playing-layout-columns-for-cover (cover-width frame)
  "Return layout columns needed for COVER-WIDTH pixels in FRAME."
  (let* ((char-width (max 1 (frame-char-width frame)))
         (cover-columns (ceiling cover-width char-width))
         (controls-columns (string-width
                            (ytm-radio--now-playing-controls-text))))
    (+ ytm-radio--cover-left-padding-columns
       (max 1 cover-columns controls-columns))))

(defun ytm-radio--now-playing-column-width ()
  "Return the text columns used for centered now-playing rows."
  (ytm-radio--now-playing-layout-columns))

(defun ytm-radio--now-playing-text-width ()
  "Return the text width used below the now-playing cover."
  (max 8 (ytm-radio--now-playing-column-width)))

(defun ytm-radio--now-playing-window-body-pixel-width ()
  "Return the now-playing child frame body width in pixels, or nil."
  (when (frame-live-p ytm-radio--frame)
    (let ((window (frame-root-window ytm-radio--frame)))
      (when (window-live-p window)
        (window-body-width window t)))))

(defun ytm-radio--insert-centered-now-playing-line (text &optional face)
  "Insert TEXT centered in the now-playing layout, optionally using FACE."
  (let* ((width (ytm-radio--now-playing-text-width))
         (text (ytm-radio--truncate text width)))
    (if (display-graphic-p (ytm-radio--now-playing-frame))
        (let ((padding (max 0 (/ (- (ytm-radio--now-playing-text-pixel-width)
                                    (string-pixel-width text (current-buffer)))
                                 2))))
          (ytm-radio--insert-pixel-space padding))
      (let ((padding (max 0 (/ (- width (string-width text)) 2))))
        (insert (make-string padding ?\s))))
    (insert (if face (propertize text 'face face) text))
    (insert "\n")))

(defun ytm-radio--now-playing-text-pixel-width ()
  "Return the now-playing text width in pixels."
  (let ((layout-width
         (* (ytm-radio--now-playing-text-width)
            (max 1 (frame-char-width (ytm-radio--now-playing-frame)))))
        (body-width (ytm-radio--now-playing-window-body-pixel-width)))
    (if body-width
        (max 1 (min layout-width body-width))
      layout-width)))

(defun ytm-radio--now-playing-control-label (icon)
  "Return a control label for ICON."
  (format "%s" icon))

(defun ytm-radio--mdicon (name fallback)
  "Return Material Design icon NAME, or FALLBACK when unavailable."
  (if (and (require 'nerd-icons nil t)
           (fboundp 'nerd-icons-mdicon))
      (condition-case nil
          (funcall #'nerd-icons-mdicon name :height 1.0)
        (error fallback))
    fallback))

(define-button-type 'ytm-radio-now-playing-button
  'follow-link t
  'face 'default
  'mouse-face 'highlight)

(defun ytm-radio--insert-now-playing-control (icon command help &optional face)
  "Insert a now-playing ICON button running COMMAND with HELP text.
When FACE is non-nil, use it for the button label."
  (insert-text-button (ytm-radio--now-playing-control-label icon)
                      'type 'ytm-radio-now-playing-button
                      'action (lambda (_button)
                                (call-interactively command))
                      'help-echo help
                      'face (or face 'default)
                      'mouse-face 'highlight))

(defun ytm-radio--repeat-control ()
  "Return the repeat control button spec."
  (pcase (map-elt ytm-radio--player :repeat)
    ('one
     (list (ytm-radio--mdicon "nf-md-repeat_once" "1")
           #'ytm-radio-cycle-repeat
           "Repeat one"
           'bold))
    ('list
     (list (ytm-radio--mdicon "nf-md-repeat" "R")
           #'ytm-radio-cycle-repeat
           "Repeat list"
           'bold))
    (_
     (list (ytm-radio--mdicon "nf-md-repeat_off" "R")
           #'ytm-radio-cycle-repeat
           "Repeat off"
           'shadow))))

(defun ytm-radio--shuffle-control ()
  "Return the shuffle control button spec."
  (if (map-elt ytm-radio--player :shuffle)
      (list (ytm-radio--mdicon "nf-md-shuffle" "S")
            #'ytm-radio-toggle-shuffle
            "Shuffle on"
            'bold)
    (list (ytm-radio--mdicon "nf-md-shuffle_disabled" "S")
          #'ytm-radio-toggle-shuffle
          "Shuffle off"
          'shadow)))

(defun ytm-radio--now-playing-controls ()
  "Return now-playing controls as button specs."
  (list
   (ytm-radio--repeat-control)
   (list (ytm-radio--mdicon "nf-md-skip_previous" "<<")
         #'ytm-radio-previous
         "Previous track")
   (list (if (eq (map-elt ytm-radio--player :status) 'playing)
             (ytm-radio--mdicon "nf-md-pause" "||")
           (ytm-radio--mdicon "nf-md-play" ">"))
         #'ytm-radio-toggle-pause
         "Play or pause")
   (list (ytm-radio--mdicon "nf-md-skip_next" ">>")
         #'ytm-radio-next
         "Next track")
   (ytm-radio--shuffle-control)))

(defun ytm-radio--insert-now-playing-controls ()
  "Insert centered now-playing controls."
  (let* ((separator ytm-radio--now-playing-control-separator)
         (controls (ytm-radio--now-playing-controls))
         (labels (mapcar #'car controls))
         (controls-text (string-join labels separator)))
    (if (display-graphic-p (ytm-radio--now-playing-frame))
        (let* ((controls-width
                (string-pixel-width controls-text (current-buffer)))
               (padding (max 0 (/ (- (ytm-radio--now-playing-text-pixel-width)
                                     controls-width)
                                  2))))
          (ytm-radio--insert-pixel-space padding))
      (let* ((controls-width (string-width controls-text))
             (padding (max 0 (/ (- (ytm-radio--now-playing-text-width)
                                  controls-width)
                               2))))
        (insert (make-string padding ?\s))))
    (cl-loop for (icon command help face) in controls
             for first = t then nil
             unless first do (insert separator)
             do (ytm-radio--insert-now-playing-control icon command help face))))

(defun ytm-radio--render-now-playing ()
  "Render the now-playing buffer."
  (when-let* ((buffer (get-buffer ytm-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (old-point (point))
            (track (ytm-radio--current-track)))
        (erase-buffer)
        (if track
            (let* ((cover-spec (ytm-radio--cover-spec track))
                   (cover-size (cadr cover-spec))
                   (ytm-radio--cover-render-width (car-safe cover-size))
                   (text-width (ytm-radio--now-playing-text-width)))
              (ytm-radio--insert-cover cover-spec)
              (ytm-radio--insert-centered-now-playing-line
               (ytm-radio--truncate
                (ytm-radio--track-title track)
                text-width)
               'bold)
              (when-let* ((artist (map-elt track :artist)))
                (ytm-radio--insert-centered-now-playing-line
                 (ytm-radio--truncate artist text-width)
                 'shadow))
              (when-let* ((time-label (ytm-radio--playback-time-label track)))
                (ytm-radio--insert-centered-now-playing-line
                 time-label))
              (insert ytm-radio--now-playing-thin-padding)
              (ytm-radio--insert-now-playing-controls)
              (insert "\n")
              (insert ytm-radio--now-playing-thin-padding))
          (insert "No track\n"))
        (goto-char (min (max old-point (point-min)) (point-max)))
        (when (eobp)
          (goto-char (point-min)))))
    (when (and (frame-live-p ytm-radio--frame)
               (not ytm-radio--inhibit-frame-fit))
      (ytm-radio--fit-frame ytm-radio--frame buffer)
      (ytm-radio--position-frame ytm-radio--frame))))

(defun ytm-radio--show-regular-buffer (buffer)
  "Show BUFFER in a regular Emacs window."
  (pop-to-buffer buffer))

(defun ytm-radio--delete-frame ()
  "Delete the now-playing child frame, if any."
  (when (frame-live-p ytm-radio--frame)
    (let ((parent (frame-parent ytm-radio--frame)))
      (delete-frame ytm-radio--frame)
      (when (frame-live-p parent)
        (select-frame-set-input-focus parent))))
  (setq ytm-radio--frame nil))

(defun ytm-radio--buffer-image (buffer)
  "Return the first image displayed in BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (image)
        (while (and (not image) (not (eobp)))
          (when-let* ((display (get-text-property (point) 'display))
                      ((eq (car-safe display) 'image)))
            (setq image display))
          (goto-char (or (next-single-property-change (point) 'display)
                         (point-max))))
        image))))

(defun ytm-radio--now-playing-line-count (buffer)
  "Return BUFFER's line count."
  (with-current-buffer buffer
    (line-number-at-pos (point-max))))

(defun ytm-radio--now-playing-frame-height (frame buffer image)
  "Return FRAME height needed for BUFFER containing IMAGE."
  (let ((window (frame-root-window frame)))
    (or (with-current-buffer buffer
          (when-let* ((size (ignore-errors
                              (window-text-pixel-size
                               window (point-min) (point-max) nil nil))))
            (+ (ceiling (cdr size))
               (frame-char-height frame))))
        (let ((dimensions (image-size image t frame))
              (lines (ytm-radio--now-playing-line-count buffer)))
          (+ (ceiling (cdr dimensions))
             (* (max 0 (1- lines))
                (frame-char-height frame)))))))

(defun ytm-radio--now-playing-debug-data ()
  "Return live geometry data for the now-playing child frame."
  (unless (frame-live-p ytm-radio--frame)
    (user-error "No live ytm-radio child frame"))
  (let* ((frame ytm-radio--frame)
         (window (frame-root-window frame))
         (buffer (window-buffer window))
         (image (ytm-radio--buffer-image buffer))
         (inside (window-inside-pixel-edges window))
         (window-edges (window-pixel-edges window))
         (image-size (and image
                          (ignore-errors (image-size image t frame))))
         first-line-size)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (setq first-line-size
              (ignore-errors
                (window-text-pixel-size
                 window (point-min) (line-end-position) t nil)))))
    `((frame-pixel-width . ,(frame-pixel-width frame))
      (frame-inner-width . ,(frame-inner-width frame))
      (frame-text-width . ,(frame-text-width frame))
      (frame-char-width . ,(frame-char-width frame))
      (cover-left-padding-columns . ,ytm-radio--cover-left-padding-columns)
      (window-pixel-width . ,(window-pixel-width window))
      (window-body-width-px . ,(window-body-width window t))
      (window-body-width-cols . ,(window-body-width window))
      (window-pixel-edges . ,window-edges)
      (window-inside-pixel-edges . ,inside)
      (window-inside-width . ,(- (nth 2 inside) (nth 0 inside)))
      (image-size . ,image-size)
      (first-line-text-pixel-size . ,first-line-size)
      (right-gap-from-first-line . ,(and first-line-size
                                         (- (- (nth 2 inside) (nth 0 inside))
                                            (car first-line-size))))
      (right-gap-from-image . ,(and image-size
                                    (- (- (nth 2 inside) (nth 0 inside))
                                       (car image-size))))
      (truncate-lines . ,truncate-lines)
      (overflow-newline-into-fringe . ,overflow-newline-into-fringe)
      (fringes . ,(window-fringes window))
      (margins . ,(window-margins window))
      (scroll-bars . ,(window-scroll-bars window))
      (frame-left-fringe . ,(frame-parameter frame 'left-fringe))
      (frame-right-fringe . ,(frame-parameter frame 'right-fringe))
      (frame-scroll-bar-width . ,(frame-parameter frame 'scroll-bar-width))
      (frame-internal-border-width
       . ,(frame-parameter frame 'internal-border-width))
      (frame-child-frame-border-width
       . ,(frame-parameter frame 'child-frame-border-width)))))

(defun ytm-radio--fit-frame (frame buffer)
  "Size FRAME to fit BUFFER's image and text."
  (let ((frame-resize-pixelwise t))
    (if-let* ((image (ytm-radio--buffer-image buffer)))
        (let* ((image-size (image-size image t frame))
               (columns (ytm-radio--now-playing-layout-columns-for-cover
                         (car image-size)
                         frame)))
          (set-frame-width frame columns)
          (set-frame-height
           frame
           (ytm-radio--now-playing-frame-height frame buffer image)
           nil
           t))
      (make-frame-visible frame)
      (fit-frame-to-buffer frame)
      (set-frame-width frame (max ytm-radio-child-frame-width
                                  (+ 2 (frame-width frame)))))))

(defun ytm-radio--position-frame (frame)
  "Position child FRAME at the lower right of its parent."
  (when-let* ((parent (frame-parent frame)))
    (let* ((bottom-window (car (window-at-side-list parent 'bottom)))
           (mode-line-height (if bottom-window
                                 (window-mode-line-height bottom-window)
                               0))
           (content-bottom (- (frame-pixel-height parent)
                              (window-pixel-height (minibuffer-window parent))
                              mode-line-height))
           (x-margin (* 2 (frame-char-width parent)))
           (y-margin (frame-char-height parent)))
      (set-frame-position
       frame
       (max 0 (- (frame-pixel-width parent)
                 (frame-pixel-width frame)
                 x-margin))
       (max 0 (- content-bottom
                 (frame-pixel-height frame)
                 y-margin))))))

(defun ytm-radio--apply-child-frame-border-face (frame)
  "Apply ytm-radio child-frame border styling to FRAME."
  (let ((background (face-background 'ytm-radio-child-frame-border frame t)))
    (set-face-background 'child-frame-border
                         (or background "gray50")
                         frame)))

(defun ytm-radio--ensure-frame (buffer)
  "Return a child frame showing the now-playing BUFFER."
  (unless (frame-live-p ytm-radio--frame)
    (let* ((parent (selected-frame))
           (frame-resize-pixelwise t)
           (frame (make-frame
                   `((parent-frame . ,parent)
                     (minibuffer . nil)
                     (undecorated . t)
                     (skip-taskbar . t)
                     (no-other-frame . t)
                     (unsplittable . t)
                     (left-fringe . 0)
                     (right-fringe . 0)
                     (vertical-scroll-bars . nil)
                     (horizontal-scroll-bars . nil)
                     (scroll-bar-width . 0)
                     (scroll-bar-height . 0)
	                     (right-divider-width . 0)
	                     (bottom-divider-width . 0)
	                     (menu-bar-lines . 0)
	                     (tool-bar-lines . 0)
	                     (tab-bar-lines . 0)
	                     (internal-border-width . 0)
	                     (child-frame-border-width . ,ytm-radio--frame-border-width)
	                     (no-focus-on-map . t)
	                     (visibility . nil)))))
	      (setq ytm-radio--frame frame)))
  (ytm-radio--apply-child-frame-border-face ytm-radio--frame)
  (let ((window (frame-root-window ytm-radio--frame)))
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    (set-window-fringes window 0 0 nil t)
    (set-window-margins window 0 0)
    (set-window-scroll-bars window 0 nil 0 nil t))
  (ytm-radio--fit-frame ytm-radio--frame buffer)
  (ytm-radio--position-frame ytm-radio--frame)
  ytm-radio--frame)

(defun ytm-radio--show-child-frame (buffer &optional focus)
  "Show now-playing BUFFER in a child frame.
When FOCUS is non-nil, select the child frame."
  (let ((selected-frame (selected-frame))
        (selected-window (selected-window))
        (frame (ytm-radio--ensure-frame buffer)))
    (unwind-protect
        (progn
          (unless (frame-visible-p frame)
            (make-frame-visible frame))
          (when focus
            (select-frame-set-input-focus frame))
          frame)
      (unless focus
        (when (frame-live-p selected-frame)
          (select-frame selected-frame)
          (when (window-live-p selected-window)
            (select-window selected-window)))))))

(defun ytm-radio--reposition-on-resize (frame)
  "Re-pin the now-playing child frame when parent FRAME changes size."
  (when (and (frame-live-p ytm-radio--frame)
             (eq frame (frame-parent ytm-radio--frame)))
    (ytm-radio--position-frame ytm-radio--frame)))

(add-hook 'window-size-change-functions #'ytm-radio--reposition-on-resize)

(defun ytm-radio--show-buffer (buffer)
  "Show browser BUFFER in a regular Emacs window."
  (ytm-radio--show-regular-buffer buffer))

(defun ytm-radio--show-now-playing (&optional focus)
  "Show the now-playing view using `ytm-radio-display-style'.
When FOCUS is non-nil, focus the now-playing child frame."
  (let ((buffer (ytm-radio--now-playing-buffer)))
    (ytm-radio--render-now-playing)
    (if (and (eq ytm-radio-display-style 'child-frame)
             (display-graphic-p))
        (ytm-radio--show-child-frame buffer focus)
      (ytm-radio--show-regular-buffer buffer))))

;;; Commands

;;;###autoload
(defun ytm-radio-open-at-point ()
  "Open the ytm-radio source or item at point."
  (interactive)
  (ytm-radio--ensure-loaded)
  (if-let* ((item (ytm-radio--item-at-point))
            (source (ytm-radio--line-source-at-point)))
      (ytm-radio--open-item source item)
    (if-let* ((source (ytm-radio--source-at-point)))
        (ytm-radio--enter-source source)
      (user-error "No ytm-radio item at point"))))

;;;###autoload
(defun ytm-radio-back ()
  "Return to the previous ytm-radio browser view."
  (interactive)
  (if-let* ((previous (pop ytm-radio--browser-history)))
      (ytm-radio--set-browser-view previous t)
    (user-error "No previous ytm-radio view")))

;;;###autoload
(defun ytm-radio-next-item ()
  "Move point to the next item row."
  (interactive)
  (ytm-radio--move-item-line 1))

;;;###autoload
(defun ytm-radio-previous-item ()
  "Move point to the previous item row."
  (interactive)
  (ytm-radio--move-item-line -1))

;;;###autoload
(defun ytm-radio-next-section ()
  "Move point to the next ytm-radio browser section."
  (interactive)
  (let* ((positions (ytm-radio--section-positions))
         (next (seq-find (lambda (position) (> position (point)))
                         positions)))
    (if next
        (goto-char next)
      (user-error "No next section"))))

;;;###autoload
(defun ytm-radio-previous-section ()
  "Move point to the previous ytm-radio browser section."
  (interactive)
  (let* ((positions (reverse (ytm-radio--section-positions)))
         (previous (seq-find (lambda (position) (< position (point)))
                             positions)))
    (if previous
        (goto-char previous)
      (user-error "No previous section"))))

;;;###autoload
(defun ytm-radio-refresh ()
  "Refresh the current ytm-radio browser view."
  (interactive)
  (ytm-radio--ensure-loaded)
  (pcase (ytm-radio--view-kind)
    ('home
     (ytm-radio--import-helper-target "home" "home recommendations"))
    ('explore
     (ytm-radio--import-helper-target "explore" "explore"))
    ('library
     (ytm-radio--import-helper-target "library" "library"))
    ('search
     (if-let* ((query (ytm-radio--view-value :query)))
         (ytm-radio-search query)
       (call-interactively #'ytm-radio-search)))
    ('section
     (ytm-radio--render-browser))
    (_
     (ytm-radio--render-browser))))

;;;###autoload
(defun ytm-radio-search (query)
  "Search YouTube Music for QUERY through the Rust helper."
  (interactive (list (read-string "YouTube Music search: ")))
  (ytm-radio--ensure-loaded)
  (unless ytm-radio-helper-use-mock-data
    (ytm-radio--ensure-readable-file
     ytm-radio-helper-auth-file
     "YouTube Music helper auth file"))
  (let ((sources (ytm-radio--fetch-helper-sources
                  (ytm-radio--helper-search-arguments query))))
    (unless sources
      (user-error "No search results returned"))
    (ytm-radio--drop-helper-target-sources "search")
    (ytm-radio--import-sources sources)
    (ytm-radio--set-browser-view
     (list (cons :kind 'search)
           (cons :query query)
           (cons :title (format "Search: %s" query)))
     t)
    (message "Imported search results for %s" query)))

;;;###autoload
(defun ytm-radio-auth-import (source output)
  "Import YouTube Music authentication from SOURCE into OUTPUT.
SOURCE is a login source such as \"chrome\", \"firefox\", \"safari\",
or \"dia\"."
  (interactive
   (list
    (completing-read "Login source: "
                     (ytm-radio--auth-import-candidates)
                     nil nil nil nil ytm-radio-helper-browser)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (if (ytm-radio--dia-auth-source-p source)
      (ytm-radio-auth-import-dia output)
    (ytm-radio-auth-import-browser source output)))

;;;###autoload
(defun ytm-radio-auth-import-dia (output)
  "Import YouTube Music authentication from Dia into OUTPUT."
  (interactive
   (list
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (condition-case error
      (ytm-radio--helper-envelope-data
       (ytm-radio--call-helper
        (ytm-radio--helper-import-dia-arguments output)))
    (user-error
     (let ((message (error-message-string error)))
       (if (and (string-match-p "quit Dia and run import again" message)
                (yes-or-no-p
                 "Dia must be restarted once for login import.  Restart Dia now? "))
             (ytm-radio--helper-envelope-data
              (ytm-radio--call-helper
               (ytm-radio--helper-import-dia-arguments output t)))
         (signal (car error) (cdr error))))))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (setq ytm-radio--initial-home-refreshed nil)
  (message "YouTube Music Dia session imported"))

;;;###autoload
(defun ytm-radio-auth-import-browser (browser output)
  "Import YouTube Music authentication from BROWSER into OUTPUT."
  (interactive
   (list
    (completing-read "Browser specification: "
                     ytm-radio-helper-browser-candidates
                     nil nil nil nil ytm-radio-helper-browser)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (ytm-radio--helper-envelope-data
   (ytm-radio--call-helper
    (ytm-radio--helper-import-browser-arguments browser output)))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (setq ytm-radio--initial-home-refreshed nil)
  (message "YouTube Music browser session imported"))

;;;###autoload
(defun ytm-radio-auth-import-headers (input output)
  "Import YouTube Music authentication from browser request headers.
INPUT is a text file containing copied request headers.  OUTPUT is the
helper auth JSON file."
  (interactive
   (list
    (read-file-name "Headers file: " nil nil t)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (ytm-radio--helper-envelope-data
   (ytm-radio--call-helper
    (ytm-radio--helper-import-headers-arguments input output)))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (setq ytm-radio--initial-home-refreshed nil)
  (message "YouTube Music browser headers imported"))

;;;###autoload
(defun ytm-radio ()
  "Open the ytm-radio YouTube Music browser."
  (interactive)
  (ytm-radio--ensure-loaded)
  (let ((buffer (ytm-radio--buffer)))
    (ytm-radio--render)
    (ytm-radio--show-buffer buffer)
    (ytm-radio--maybe-refresh-initial-home)))

;;;###autoload
(defun ytm-radio-now-playing ()
  "Show the now-playing cover view."
  (interactive)
  (ytm-radio--ensure-loaded)
  (ytm-radio--show-now-playing t))

;;;###autoload
(defun ytm-radio-debug-now-playing-frame ()
  "Copy now-playing child-frame geometry diagnostics to the kill ring."
  (interactive)
  (let ((text (prin1-to-string (ytm-radio--now-playing-debug-data))))
    (kill-new text)
    (message "ytm-radio child-frame diagnostics copied: %s" text)))

;;;###autoload
(defun ytm-radio-add-url (url)
  "Add URL as a source and play its first track."
  (interactive (list (read-string "YouTube or YouTube Music URL: ")))
  (ytm-radio--ensure-loaded)
  (let ((source (ytm-radio--fetch-source url)))
    (unless (map-elt source :tracks)
      (user-error "No playable tracks found"))
    (ytm-radio--put-source source)
    (ytm-radio--save)
    (message "Added %s (%d tracks)"
             (ytm-radio--source-display-title source)
             (length (map-elt source :tracks)))
    (ytm-radio--play-track (car (map-elt source :tracks)))))

;;;###autoload
(defun ytm-radio-import-ytmusic-library ()
  "Import YouTube Music library sources through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "library" "library")
  (ytm-radio--set-browser-view 'library t))

;;;###autoload
(defun ytm-radio-import-ytmusic-home ()
  "Import YouTube Music home recommendations through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "home" "home recommendations")
  (ytm-radio--set-browser-view 'home t))

;;;###autoload
(defun ytm-radio-import-ytmusic-explore ()
  "Import YouTube Music explore sections through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "explore" "explore")
  (ytm-radio--set-browser-view 'explore t))

;;;###autoload
(defun ytm-radio-import-ytmusic-liked ()
  "Import YouTube Music liked songs through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "liked" "liked songs")
  (ytm-radio--set-browser-view 'library t))

;;;###autoload
(defun ytm-radio-play-track ()
  "Select and play a known track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (let ((choices (mapcar (lambda (track)
                           (cons (ytm-radio--track-label track) track))
                         (ytm-radio--all-tracks))))
    (unless choices
      (user-error "No tracks; add a URL first"))
    (ytm-radio--play-track
     (cdr (assoc (completing-read "Track: " choices nil t) choices)))))

;;;###autoload
(defun ytm-radio-play-source ()
  "Select a source and play its first track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (if-let* ((source (ytm-radio--line-source-at-point)))
      (ytm-radio--play-source-object source)
    (let ((choices (mapcar (lambda (source)
                             (cons (ytm-radio--source-display-title source) source))
                           (map-values (ytm-radio--sources)))))
      (unless choices
        (user-error "No sources; add a URL first"))
      (let* ((source (cdr (assoc (completing-read "Source: " choices nil t)
                                 choices))))
        (ytm-radio--play-source-object source)))))

;;;###autoload
(defun ytm-radio-toggle-pause ()
  "Toggle playback pause, or resume the last known track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (cond ((process-live-p (map-elt ytm-radio--player :process))
         (ytm-radio--mpv-send (list "cycle" "pause")))
        ((ytm-radio--current-track)
         (ytm-radio--play-track (ytm-radio--current-track)))
        (t
         (user-error "Nothing to play"))))

;;;###autoload
(defun ytm-radio-cycle-repeat ()
  "Cycle repeat mode between off, list, and one."
  (interactive)
  (let* ((next (pcase (map-elt ytm-radio--player :repeat)
                 ('list 'one)
                 ('one nil)
                 (_ 'list)))
         (label (pcase next
                  ('list "list")
                  ('one "one")
                  (_ "off"))))
    (setf (map-elt ytm-radio--player :repeat) next)
    (ytm-radio--render-now-playing)
    (message "Repeat: %s" label)))

;;;###autoload
(defun ytm-radio-toggle-shuffle ()
  "Toggle shuffle playback."
  (interactive)
  (let ((enabled (not (map-elt ytm-radio--player :shuffle))))
    (setf (map-elt ytm-radio--player :shuffle) enabled)
    (ytm-radio--render-now-playing)
    (message "Shuffle: %s" (if enabled "on" "off"))))

;;;###autoload
(defun ytm-radio-stop ()
  "Stop playback."
  (interactive)
  (ytm-radio--stop-process)
  (ytm-radio--render)
  (message "Stopped"))

;;;###autoload
(defun ytm-radio-next ()
  "Play the next track in catalog order."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (next (ytm-radio--next-track track)))
      (ytm-radio--play-track next)
    (user-error "No next track")))

;;;###autoload
(defun ytm-radio-previous ()
  "Play the previous track in catalog order."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (previous (ytm-radio--previous-track track)))
      (ytm-radio--play-track previous)
    (user-error "No previous track")))

;;;###autoload
(defun ytm-radio-share ()
  "Copy the current track URL for sharing."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (url (map-elt track :url)))
      (progn
        (kill-new url)
        (message "Copied track URL"))
    (user-error "No track URL to share")))

;;;###autoload
(defun ytm-radio-seek-forward (seconds)
  "Seek forward SECONDS seconds, defaulting to five."
  (interactive "P")
  (unless (process-live-p (map-elt ytm-radio--player :ipc-process))
    (user-error "Not playing"))
  (let ((amount (cond ((numberp seconds) seconds)
                      (seconds (* 60 (/ (prefix-numeric-value seconds) 4)))
                      (t 5))))
    (ytm-radio--mpv-send (list "seek" amount))))

;;;###autoload
(defun ytm-radio-seek-backward (seconds)
  "Seek backward SECONDS seconds, defaulting to five."
  (interactive "P")
  (unless seconds
    (setq seconds 5))
  (when (and seconds (not (numberp seconds)))
    (setq seconds (* 60 (/ (prefix-numeric-value seconds) 4))))
  (ytm-radio-seek-forward (- seconds)))

;;;###autoload
(defun ytm-radio-hide ()
  "Hide ytm-radio UI without stopping playback."
  (interactive)
  (ytm-radio--delete-frame)
  (dolist (buffer-name (list ytm-radio--library-buffer-name
                             ytm-radio--now-playing-buffer-name))
    (when-let* ((buffer (get-buffer buffer-name))
                (window (get-buffer-window buffer t)))
      (quit-window nil window))))

(provide 'ytm-radio)

;;; ytm-radio.el ends here
