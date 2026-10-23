;;;; observe.lisp --- where the time and money went: one session's turns,
;;;; each model call and step on the turn's own clock with the flags worth a
;;;; look (the web page's Run view), the bytes one call sent (its inspector),
;;;; and the usage across every session over a range (its Usage view).
;;;;
;;;; SPDX-License-Identifier: MIT
;;;;
;;;; Projections, never sources: every number is a fact the turn loop already
;;;; recorded -- turn.usage (tokens, price), turn.provider_request (the wait
;;;; for the first token, the stream), turn.tool_result (a step's time), the
;;;; retries, the model switches, the evictions and each turn's own start and
;;;; end -- so both rebuild from the log alone, and a number no fact carries is
;;;; absent from the answer: NIL is not zero. What counts as worth a look is
;;;; decided here and nowhere else; the page renders what it is sent.
;;;;
;;;; A call's start is placed back from its request fact, recorded as the
;;;; stream ended, by its wait and its stream; a step's from its result, by
;;;; its measured time. The usage read never hydrates a fact: SQLite pulls the few fields it sums
;;;; out of each payload, so a month of rounds is one scan.
;;;;
;;;; Retention: persisted-history; a call's bytes are debug-only (bodies.lisp).

(in-package #:nodecode.evolved)

(nlk:access (used nlk:turn-usage-event) (sent nlk:provider-request-event)
            (switch nlk:provider-fallback-event) (result nlk:tool-result-event)
            (call nlk:tool-call-event) (retry nlk:provider-retry-event))

(defmacro loop-vector (&body clauses)
  "LOOP over CLAUSES, what it answers as a vector: the JSON array a list of rows is sent as."
  `(coerce (loop ,@clauses) 'vector))

(defparameter +timeline-kinds+
  (list nlk::+kind-turn-started+ nlk::+kind-turn-completed+ nlk::+kind-turn-failed+
        nlk::+kind-turn-cancelled+ nlk::+kind-turn-usage+ nlk::+kind-provider-request+
        nlk::+kind-tool-call-started+ nlk::+kind-tool-result+ nlk::+kind-provider-retry+
        nlk::+kind-provider-fallback+ nlk::+kind-context-evicted+
        nlk::+kind-turn-context-evicted+)
  "The facts a session's timeline is folded from.")

(defstruct (timeline-turn (:conc-name tt-) (:copier nil))
  "One turn as the fold holds it."
  id prompt started-at started ended status detail evicted-p
  ;; NLK:TURN-ORIGIN: what began a turn no one asked, NIL for one someone did.
  origin
  (calls '()) (steps '()) (retries '()) (fallbacks '())
  ;; The request fact waiting for its round's usage, as (AT . EVENT).
  pending
  ;; What voided attempts billed: spent, though no round came of it.
  (voided-usd 0)
  (tool-calls (make-hash-table :test #'equal)))

(defun fold-timeline (events &aux (turns '()) (by-id (make-hash-table :test #'equal)))
  "EVENTS, a session's +TIMELINE-KINDS+ facts oldest first, as its
TIMELINE-TURNs, oldest first."
  (dolist (event events (nreverse turns))
    (let ((at (iso-8601-ms (nlk:event-occurred-at event)))
          ;; A fact of no turn (a session-wide eviction) is the open turn's.
          (turn (or (gethash (nlk:event-turn-id event) by-id) (first turns))))
      (when (typep event 'nlk:turn-started)
        (let ((new (make-timeline-turn :id (nlk:event-turn-id event)
                                       :prompt (nlk:turn-started-input event)
                                       :origin (nlk:turn-origin (nlk:turn-started-wake event) nil)
                                       :started-at (nlk:event-occurred-at event)
                                       :started at :status "running")))
          (setf (gethash (tt-id new) by-id) new)
          (push new turns)))
      (when turn
        (typecase event
          (nlk:turn-completed
           (setf (tt-ended turn) at (tt-status turn) "completed")
           ;; A recorded exchange says who recorded it on its completion.
           (unless (tt-origin turn)
             (setf (tt-origin turn) (nlk:turn-origin nil (nlk:turn-completed-recorder event))))
           ;; A recorded exchange is written whole once it settled: its
           ;; recorder's elapsed time is when the work behind it began.
           (when-let (elapsed (and at (nlk:turn-completed-elapsed-ms event)))
             (setf (tt-started turn) (- at elapsed))))
          (nlk:turn-failed (setf (tt-ended turn) at (tt-status turn) "failed"
                                 (tt-detail turn) (nlk:turn-failed-detail event)))
          (nlk:turn-cancelled (setf (tt-ended turn) at (tt-status turn) "cancelled"))
          (nlk:provider-request-event (setf (tt-pending turn) (cons at event)))
          (nlk:turn-usage-event
           (if (nlk:turn-usage-event-voided event)
               (when (nlk:turn-usage-event-cost-known event)
                 (incf (tt-voided-usd turn) (nlk:turn-usage-event-cost-usd event)))
               (destructuring-bind (&optional request-at . request) (tt-pending turn)
                 (setf (tt-pending turn) nil)
                 (push (list :usage event :request request :end (or request-at at))
                       (tt-calls turn)))))
          (nlk:tool-call-event
           (setf (gethash (nlk:tool-call-event-call-id event) (tt-tool-calls turn)) event))
          (nlk:tool-result-event (push (cons at event) (tt-steps turn)))
          (nlk:provider-retry-event (push (cons at event) (tt-retries turn)))
          (nlk:provider-fallback-event (push (cons at event) (tt-fallbacks turn)))
          ((or nlk:context-evicted-event nlk:turn-context-evicted-event)
           (setf (tt-evicted-p turn) t)))))))

(defun median-integer (values)
  "The middle of VALUES, integers, or NIL for none."
  (when values
    (let ((sorted (sort (copy-list values) #'<)))
      (nth (floor (length sorted) 2) sorted))))

(defun timeline-call-flags (used sent usual-wait first-p)
  "What is worth a look about one model call: \"slow_start\", \"cache_miss\"."
  (let* ((wait (and sent sent.ttft-ms))
         (cached (or used.cached-input-tokens 0))
         (fresh (+ (or used.input-tokens 0) (or used.cache-write-tokens 0))))
    ;; A slow start waited three times the session's usual wait, and at least ten
    ;; seconds; a cache miss sent a prompt less than half of which was reused,
    ;; once the part paid in full (8192 tokens) is worth a line.
    (append
     (and wait usual-wait
          (>= wait (max 10000 (* 3 usual-wait)))
          (list "slow_start"))
     ;; A session's first call has nothing to reuse yet.
     (and (not first-p) (>= fresh 8192)
          (< cached (* 1/2 (+ cached fresh)))
          (list "cache_miss")))))

(defun timeline-call-json (call turn-start usual-wait first-p)
  "One model call of a turn: its place on the turn's clock, what it sent and
wrote, what it cost, and its flags."
  (destructuring-bind (&key ((:usage used)) ((:request sent)) end) call
    (let* ((wait (and sent sent.ttft-ms))
           (stream (and sent sent.stream-duration-ms))
           (start (and end (- end (or wait 0) (or stream 0))))
           (diverged (and sent sent.prefix-diverged-in))
           ;; The message index a path like "input[17]" names.
           (bracket (and (stringp diverged) (position #\[ diverged))))
      (json-object
       :opt "at_ms" (and start turn-start (max 0 (- start turn-start)))
       :opt "wait_ms" wait
       :opt "stream_ms" stream
       "model" used.model
       "provider" used.provider
       :opt "effort" used.reasoning-effort
       :opt "input" used.input-tokens
       :opt "cached" used.cached-input-tokens
       :opt "cache_write" used.cache-write-tokens
       :opt "output" used.output-tokens
       :opt "reasoning" used.reasoning-tokens
       :opt "cost_usd" (and used.cost-known used.cost-usd)
       :opt "context" (and sent sent.estimated-context-tokens)
       :opt "messages" (and sent sent.provider-message-count)
       :opt "diverged_in" diverged
       :opt "diverged_at" (and bracket (parse-integer diverged :start (1+ bracket) :junk-allowed t))
       :opt "attempts" (and sent sent.transport-attempts)
       ;; What the request read (NLK:KEPT-REQUEST-BODY) finds the call's bytes by.
       :opt "round" (and sent sent.provider-round)
       :opt "finish" used.finish-reason
       :when used.estimated "estimated" t
       "flags" (coerce (timeline-call-flags used sent usual-wait first-p) 'vector)))))

(defun timeline-step-json (step turn turn-start)
  "One step of a turn: its place on the turn's clock, its time and its title."
  (destructuring-bind (at . result) step
    (let* ((ms result.duration-ms)
           (call (gethash result.call-id (tt-tool-calls turn)))
           (title (and call
                       (with-handlers ((error () nil))
                         (when-let (activity (tool-arguments-activity call.tool-name call.arguments
                                                                      :metadata result.metadata))
                           (activity-title activity))))))
      (json-object
       :opt "at_ms" (and at ms turn-start (max 0 (- at ms turn-start)))
       :opt "ms" ms
       "tool" result.tool-name
       "call_id" result.call-id
       :opt "title" title))))

(defun prompt-line (text &optional (limit 200))
  "TEXT on one line, runs of whitespace one space, at most LIMIT characters."
  (clip (one-line text) limit :ellipsis ""))

(defun sum-known (values)
  "The sum of VALUES' numbers, or NIL when none is one."
  (when-let (numbers (remove-if-not #'numberp values))
    (reduce #'+ numbers)))

(defun session-timeline-json (session-id &aux (now (iso-8601-ms (nlk::iso-now))))
  "SESSION-ID's turns as where their time and money went, with the totals."
  ;; A reflection's recap ran nothing in this session -- its work ran in the
  ;; session the reflection was forked into -- so it is no turn here. An exit's
  ;; wake did run a round of its own, and stays: named by its ORIGIN, numbered by
  ;; no one. N places a turn in the read (the address of it); NUMBER counts the
  ;; asks, the number the operator knows a turn by.
  (let* ((turns (remove "reflection" (fold-timeline (nlk:events :session-id session-id :kind +timeline-kinds+))
                        :key #'tt-origin :test #'equal))
         (calls (loop for turn in turns append (reverse (tt-calls turn))))
         ;; The middle wait for the first token over the calls, or NIL.
         (usual-wait (median-integer (loop for call in calls
                                           for sent = (getf call :request)
                                           for wait = (and sent sent.ttft-ms)
                                           when wait collect wait)))
         (used (getf (car (last calls)) :usage))
         (turn-objects
           (loop with asked = 0
                 for turn in turns
                 for n from 1
                 for number = (and (null (tt-origin turn)) (incf asked))
                 for start = (tt-started turn)
                 for turn-calls = (reverse (tt-calls turn))
                 for call-objects = (loop for call in turn-calls
                                          collect (timeline-call-json call start usual-wait
                                                                      (eq call (first calls))))
                 for step-objects = (loop for step in (reverse (tt-steps turn))
                                          collect (timeline-step-json step turn start))
                 for costs = (mapcar (lambda (call) (gethash "cost_usd" call)) call-objects)
                 for flags = (remove-duplicates
                              (append (loop for call in call-objects
                                            append (coerce (gethash "flags" call) 'list))
                                      (and (tt-retries turn) (list "retried"))
                                      (and (tt-fallbacks turn) (list "switched_model"))
                                      (and (tt-evicted-p turn) (list "memory_trimmed"))
                                      (and (equal "failed" (tt-status turn)) (list "failed")))
                              :test #'string= :from-end t)
                 collect
                 (json-object
                  "turn_id" (tt-id turn)
                  "n" n
                  :opt "number" number
                  :opt "origin" (tt-origin turn)
                  "prompt" (prompt-line (tt-prompt turn))
                  "status" (tt-status turn)
                  :opt "detail" (tt-detail turn)
                  :opt "started_at" (tt-started-at turn)
                  :opt "ms" (and start (- (or (tt-ended turn) now) start))
                  :opt "cost_usd" (sum-known (cons (and (plusp (tt-voided-usd turn))
                                                        (tt-voided-usd turn))
                                                   costs))
                  :when turn-calls "cost_complete" (every #'numberp costs)
                  "calls" (coerce call-objects 'vector)
                  "steps" (coerce step-objects 'vector)
                  "retries" (loop-vector for (at . retry) in (reverse (tt-retries turn))
                                         collect (json-object
                                                  :opt "at_ms" (and at start (max 0 (- at start)))
                                                  :opt "status" retry.status "detail" retry.detail
                                                  "delay_s" retry.delay-seconds))
                  "fallbacks" (loop-vector for (at . switch) in (reverse (tt-fallbacks turn))
                                           collect (json-object
                                                    :opt "at_ms" (and at start (max 0 (- at start)))
                                                    "from" (format nil "~a/~a" switch.from-provider
                                                                   switch.from-model)
                                                    "to" (format nil "~a/~a" switch.to-provider
                                                                 switch.to-model)
                                                    "reason" switch.reason))
                  "flags" (coerce flags 'vector)))))
    (flet ((total (key &optional (objects (loop for turn in turn-objects
                                                append (coerce (gethash "calls" turn) 'list))))
             (sum-known (mapcar (lambda (object) (gethash key object)) objects))))
      (json-object
       "session_id" session-id
       "turns" (coerce turn-objects 'vector)
       "totals"
       (json-object
        "turns" (count-if-not #'tt-origin turns)
        :opt "ms" (total "ms" turn-objects)
        :opt "cost_usd" (total "cost_usd" turn-objects)
        "cost_complete" (every (lambda (turn) (gethash "cost_complete" turn t)) turn-objects)
        "calls" (length calls)
        "steps" (loop for turn in turn-objects sum (length (gethash "steps" turn)))
        :opt "input" (total "input")
        :opt "cached" (total "cached")
        :opt "cache_write" (total "cache_write")
        :opt "output" (total "output")
        :opt "reasoning" (total "reasoning")
        :opt "wait_ms" (total "wait_ms")
        :opt "stream_ms" (total "stream_ms")
        :opt "step_ms" (total "ms" (loop for turn in turn-objects
                                         append (coerce (gethash "steps" turn) 'list)))
        :opt "usual_wait_ms" usual-wait
        :opt "peak_prompt" (and calls
                                (loop for call in calls
                                      for usage = (getf call :usage)
                                      maximize (+ (or (nlk:turn-usage-event-input-tokens usage) 0)
                                                  (or (nlk:turn-usage-event-cached-input-tokens usage) 0)
                                                  (or (nlk:turn-usage-event-cache-write-tokens usage) 0))))
        :opt "window" (and used (model-capability-context-tokens
                                 (resolve-model-capability used.model used.provider))))))))

(define-gateway-route handle-gateway-timeline-http (env session-id)
  "GET /api/gateway/sessions/<id>/timeline — where the session's time and
money went, turn by turn (SESSION-TIMELINE-JSON)."
  (:route :get "timeline" "session timeline")
  (session-timeline-json session-id))

;;; --- what a call sent: its request body, byte for byte -----------------------
;;; The bytes as they went out (NLK:KEPT-REQUEST-BODY), and beside them, in
;;; headers, how much the request kept before them already sent and where
;;; they first differ: the request fact's own diagnosis (REQUEST-PREFIX-
;;; DIAGNOSIS), which a session's first request lacks -- it had nothing
;;; before it -- and the kept chain does not.

(define-gateway-route handle-gateway-request-http (env session-id)
  "GET /api/gateway/sessions/<id>/request?turn=<turn_id>&round=<n> — the
exact body that model call sent, application/json, byte for byte; beside it
X-Shared-Bytes and X-Diverged-In, what it shares with the request kept before
it and where they part, and X-Previous, that request as `SESSION TURN ROUND'.
404 not_kept when it was not kept: recorded before bodies were, or dropped
past request_bodies.keep_mb."
  (:route :get "request" "request body")
  (let* ((query (gateway-query-parameters env))
         (turn (cdr (assoc "turn" query :test #'string=)))
         (round (parse-integer (or (cdr (assoc "round" query :test #'string=)) "") :junk-allowed t)))
    (multiple-value-bind (body previous from) (and turn round (nlk:kept-request-body session-id turn round))
      (if body
          (multiple-value-bind (shared diverged) (request-prefix-diagnosis previous body)
            (list 200 (list* :content-type "application/json" :content-length (length body)
                             :cache-control "private, no-cache"
                             (append (and shared (list :x-shared-bytes (princ-to-string shared)
                                                       :x-diverged-in diverged))
                                     (and from (list :x-previous (format nil "~{~a~^ ~}" from)))))
                  body))
          (gateway-error-response 404 "not_kept" "that call's request body was not kept")))))

;;; --- usage: every session over a range ---------------------------------------

(defun payload-columns (&rest keys)
  "The SQL column reading each of KEYS out of a fact's payload, a hyphenated key quoted."
  (loop for key in keys
        collect (format nil "json_extract(payload, '$.~:[~a~;\"~a\"~]')" (find #\- key) key)))

(defparameter +usage-columns+
  (list* "session_id" "occurred_at"
         (payload-columns "model" "provider" "input-tokens" "cached-input-tokens"
                          "cache-write-tokens" "output-tokens" "cost_known" "cost_usd" "voided"))
  "What the usage read takes out of each turn.usage fact, in USAGE-JSON's order.")

(defun usage-range-start (range &optional (now (get-universal-time)))
  "The universal time RANGE starts at: local midnight of the first of its
days, today counting as one -- \"today\", \"30d\", \"all\" (NIL), else seven."
  (when-let (days (dispatch range equal ("today" 1) ("30d" 30) ("all" nil) (t 7)))
    (multiple-value-bind (second minute hour) (decode-universal-time now)
      (- now second (* 60 minute) (* 3600 hour) (* 86400 (1- days))))))

(defun local-day (universal)
  "UNIVERSAL's local date as YYYY-MM-DD."
  (bind (((_ _ _ day month year) (decode-universal-time universal)))
    (format nil "~d-~2,'0d-~2,'0d" year month day)))

(defstruct (usage-sum (:conc-name us-) (:copier nil))
  "What a group of rounds adds up to."
  (calls 0) (cost 0) (priced 0) (input 0) (cached 0) (write 0) (output 0) (ms 0)
  ;; The turns that ended, and the ones of them that failed.
  (turns 0) (failed 0)
  ;; A model's waits for its first token, the time it spent writing, and the
  ;; status each of its failed attempts met.
  (waits '()) (streamed 0) (statuses '())
  (sessions (make-hash-table :test #'equal)))

(nlk:access (sum usage-sum))

(defun add-usage (sum session input cached write output cost)
  "Count one round of SESSION into SUM; COST NIL when it has no price."
  (incf sum.calls)
  (when cost (incf sum.cost cost) (incf sum.priced))
  (incf sum.input input)
  (incf sum.cached cached)
  (incf sum.write write)
  (incf sum.output output)
  (setf (gethash session sum.sessions) t))

(defun usage-sum-json (sum &rest more &aux (prompt (+ sum.input sum.cached sum.write)))
  "SUM's numbers, then MORE's keys and values."
  (let ((object (json-object
                 "calls" sum.calls :opt "cost_usd" (and (plusp sum.priced) sum.cost)
                 "unpriced" (- sum.calls sum.priced) "sessions" (hash-table-count sum.sessions)
                 "input" sum.input "cached" sum.cached "cache_write" sum.write "output" sum.output
                 :opt "cached_share" (and (plusp prompt) (/ sum.cached prompt 1d0))
                 :when (plusp sum.ms) "ms" sum.ms
                 :when (plusp sum.turns) "turns" sum.turns
                 :when (plusp sum.turns) "failed_turns" sum.failed
                 :when (plusp sum.turns) "error_rate" (/ sum.failed sum.turns 1d0))))
    (apply #'copy-json-object object more)))

(defun descending (&rest keys)
  "A sort predicate: the greater by the first of KEYS first, the next breaking a tie."
  (lambda (a b)
    (loop for key in keys
          for x = (funcall key a) and y = (funcall key b)
          unless (= x y) return (> x y))))

(defun ranked (table &optional limit)
  "TABLE's (NAME . USAGE-SUM) entries, costliest first, then busiest; the
first LIMIT of them when LIMIT is given."
  (let ((entries (sort (nreverse (alexandria:hash-table-alist table))
                       (descending #'us-cost #'us-calls) :key #'cdr)))
    (if (and limit (> (length entries) limit)) (subseq entries 0 limit) entries)))

(defun asked-where (where &key row literal)
  "WHERE narrowed to operator turns, excluding note sessions and reflection
recaps. ROW scopes the exclusions to a non-null event's identifiers;
LITERAL emits the same policy without parameters, for durable triggers."
  ;; One policy owns both live reads and the rebuild/incremental projection.
  ;; Scoped exclusions seek the two identifiers instead of copying every
  ;; reflection's identifier into a temporary set on each new usage fact.
  (flet ((value (text) (if literal (format nil "'~a'" text) "?")))
    (let ((prefix (if row (format nil "~a." row) "")))
      (cons (format nil "~@[~a and ~]~asession_id not in
                          (select session_id from session_directory where source = ~a~
                           ~@[ and session_id = ~a.session_id~])
                        and ~aturn_id not in
                          (select r.turn_id from events r where r.kind = ~a
                            and r.turn_id is not null
                            and json_extract(r.payload, '$.recorder') = 'reflection'~
                            ~@[ and r.turn_id = ~a.turn_id~])"
                    (first where) prefix (value nlk::+note-source+) row
                    prefix (value nlk::+kind-turn-completed+) row)
            (append (rest where)
                    (unless literal (list nlk::+note-source+ nlk::+kind-turn-completed+)))))))

(defun model-history-fill-sql (&optional scope)
  "Upsert eligible retained usage facts in SCOPE (or the log) into the
model history. One row per provider/model/turn/session; rounds only advance
recency, and ASKED-WHERE owns the exclusions."
  (format nil "insert into model_history (provider, model, turn_id, session_id, log_position)
      select json_extract(payload, '$.provider'), json_extract(payload, '$.model'),
             turn_id, session_id, max(log_position)
        from events where ~a
       group by 1, 2, 3, 4
      on conflict (provider, model, turn_id, session_id) do update
         set log_position = max(model_history.log_position, excluded.log_position)"
          (first (asked-where
                  (list (format nil "~@[~a and ~]kind = '~a' and turn_id is not null
                          and session_id is not null
                          and coalesce(json_extract(payload, '$.voided'), 0) = 0
                          and length(json_extract(payload, '$.provider')) > 0
                          and length(json_extract(payload, '$.model')) > 0"
                                scope nlk::+kind-turn-usage+))
                  :row (and scope "events") :literal t))))

(defparameter *model-history-schema*
  (list
   (list "table" "model_history"
         "create table model_history (
            provider not null, model not null, turn_id text not null,
            session_id text not null, log_position integer not null,
            primary key (provider, model, turn_id, session_id)) without rowid")
   (list "index" "model_history_by_turn"
         "create index model_history_by_turn on model_history (turn_id)")
   (list "index" "model_history_by_session"
         "create index model_history_by_session on model_history (session_id)")
   (list "trigger" "model_history_follows_usage"
         (format nil "create trigger model_history_follows_usage
            after insert on events when new.kind = '~a'
            begin ~a; end"
                 nlk::+kind-turn-usage+ (model-history-fill-sql "log_position = new.log_position")))
   (list "trigger" "model_history_follows_completion"
         (format nil "create trigger model_history_follows_completion
            after insert on events when new.kind = '~a'
            begin
              delete from model_history where turn_id = new.turn_id;
              ~a;
            end"
                 nlk::+kind-turn-completed+ (model-history-fill-sql "turn_id = new.turn_id")))
   (list "trigger" "model_history_follows_source"
         (format nil "create trigger model_history_follows_source
            after update of source on session_directory when new.source is not old.source
            begin
              delete from model_history where session_id = new.session_id;
              ~a;
            end"
                 (model-history-fill-sql "session_id = new.session_id"))))
  "Rebuildable persisted-history, never authority. Triggers keep it inside the
fact's transaction, including late reflection/source facts and rollback.")

(defun prepare-model-history (handle)
  "Discard a stale model projection shape before its schema is applied."
  ;; EXECUTE-SINGLE finalizes before DDL. Compare every trigger, not just the
  ;; table: IF NOT EXISTS would preserve stale eligibility or recency policy.
  (unless (every (lambda (entry)
                   (destructuring-bind (type name sql) entry
                     (equalp sql (sqlite:execute-single
                                  handle "select sql from sqlite_master where type = ? and name = ?"
                                  type name))))
                 *model-history-schema*)
    (dolist (entry *model-history-schema*)
      (when (string= "trigger" (first entry))
        (sqlite:execute-non-query handle (format nil "drop trigger if exists ~a" (second entry)))))
    (sqlite:execute-non-query handle "drop table if exists model_history"))
  ;; The displaced full-usage covering index has no remaining reader.
  (sqlite:execute-non-query handle "drop index if exists events_usage_by_model"))

(defun open-model-history ()
  "Install the model projection and derive it once from retained facts."
  (nlk::with-store-transaction (handle)
    ;; Recheck after the kernel schema: replacing events/the directory also
    ;; drops their triggers, so a surviving derived table must be rebuilt.
    (prepare-model-history handle)
    (unless (sqlite:execute-single handle
                                   "select 1 from sqlite_master where type = 'table' and name = 'model_history'")
      (dolist (entry *model-history-schema*)
        (sqlite:execute-non-query handle (third entry)))
      (sqlite:execute-non-query handle (model-history-fill-sql)))))

(pushnew 'prepare-model-history nlk::*schema-prepare-hooks*)
(pushnew 'open-model-history nlk::*store-open-hooks*)

(defun frequent-models-json ()
  "Past models ranked by distinct operator turns, newest usage first on a
 tie. Retained facts own history; the transactional projection avoids
 reading every round on each uncached picker open."
  (let ((rows (nlk::with-store-handle (handle)
                (nlk::sql-rows handle
                               "select provider, model, count(distinct turn_id), max(log_position)
                                  from model_history group by provider, model"))))
    (loop-vector for (provider model turns position)
                 in (sort rows (descending #'third #'fourth))
                 collect (json-object "provider" provider "model" model "turns" turns))))

(defun usage-json (range &aux (now (get-universal-time)))
  "What every session spent over RANGE (USAGE-RANGE-START): the totals, each
day, each model with its failed attempts, each folder with its failed turns,
and the costliest sessions."
  (nlk::with-store-reader ()
    (let* ((start (usage-range-start range now))
           (where (and start (list "occurred_at >= ?" (iso-time (- start +unix-epoch+)))))
           (rows (nlk:events :kind nlk::+kind-turn-usage+ :where where
                             :as :rows :columns +usage-columns+))
           (entries (make-hash-table :test #'equal))
           (prices (make-hash-table :test #'equal))
           (total (make-usage-sum)) (days (make-hash-table :test #'equal))
           (models (make-hash-table :test #'equal)) (folders (make-hash-table :test #'equal))
           (sessions (make-hash-table :test #'equal))
           (saved 0)
           ;; Rounds the nodecode.ai account paid -- the plan's requests or its
           ;; credit -- that have no API price here: counted, never `unpriced'
           ;; (a buyer's /usage said `1 call has no price', checkout audit
           ;; 2026-10-22).
           (account 0))
      (dolist (entry (nlk:list-sessions))
        (setf (gethash (getf entry :id) entries) entry))
      (labels ((root (id &aux (entry (gethash id entries)))
                 ;; A reflection's spend is the session's it reflected on.
                 (if (and entry (getf entry :parent)
                          (equal (getf entry :source) nlk::+note-source+))
                     (root (getf entry :parent))
                     id))
               (folder (id) (or (getf (gethash id entries) :working-directory) ""))
               (sum-of (table key) (alexandria:ensure-gethash key table (make-usage-sum)))
               (count-of (value) (if (realp value) (round value) 0)))
        (loop for (session at model provider input cached write output known cost voided) in rows
              for root = (root session)
              for day = (when-let (universal (iso-universal at)) (local-day universal))
              for counts = (list (count-of input) (count-of cached) (count-of write) (count-of output))
              for price = (and (eql known 1) (realp cost) cost)
              if (eql voided 1)
                ;; A voided attempt is no round, but its spend was real.
                do (when price (incf (us-cost total) price))
              else do (when (and (null price) (equal provider "nodecode")) (incf account))
                      (dolist (sum (remove nil (list total (and day (sum-of days day))
                                                     (sum-of models (list model provider))
                                                     (sum-of folders (folder root))
                                                     (sum-of sessions root))))
                        (apply #'add-usage sum root (append counts (list price))))
                      (when-let (saving (and (or (plusp (second counts)) (plusp (third counts)))
                                             (round-cache-saving
                                              (alexandria:ensure-gethash (cons model provider) prices
                                                                         (model-price model provider))
                                              :input-tokens (first counts)
                                              :cached-input-tokens (second counts)
                                              :cache-write-tokens (third counts))))
                        (incf saved saving)))
      (let* ((turns (nlk:events :kind (list nlk::+kind-turn-completed+ nlk::+kind-turn-failed+
                                            nlk::+kind-turn-cancelled+)
                                :where (asked-where where) :as :rows
                                ;; A turn's time is its end fact's clock less its
                                ;; start's, the start found through events_by_turn.
                                :columns '("session_id"
                                           "(select cast(round((julianday(events.occurred_at) - julianday(s.occurred_at)) * 86400000) as integer)
                                               from events s where s.turn_id = events.turn_id and s.kind = 'turn.started')"
                                           "kind")))
             (requests (nlk:events :kind nlk::+kind-provider-request+ :where where :as :rows
                                   :columns (payload-columns "model" "provider" "ttft-ms"
                                                             "stream-duration-ms")))
             (waits (sort (loop for (nil nil wait) in requests when (realp wait) collect wait) #'<)))
        (loop for (session ms kind) in turns
              for folder = (sum-of folders (folder (root session)))
              do (incf (us-turns folder))
                 (when (equal kind nlk::+kind-turn-failed+) (incf (us-failed folder)))
                 (when (realp ms)
                   (incf (us-ms (sum-of sessions session)) ms)
                   (incf (us-ms folder) ms)))
        ;; A model's attempt failed when it was retried, when the turn moved off
        ;; it (the switch's from-model), or when its provider failure ended the
        ;; turn; the rest of its attempts are its rounds. A failed turn names
        ;; the model its request targeted; one recorded before it did is charged
        ;; to the model its last attempt went to.
        (loop for (turn model provider status)
                in (nlk:events :kind (list nlk::+kind-provider-retry+ nlk::+kind-provider-fallback+
                                           nlk::+kind-turn-failed+)
                               :where (cons (format nil "~@[~a and ~](kind <> 'turn.failed' or ~
                                                     json_extract(payload, '$.\"condition-type\"') like 'PROVIDER-%')"
                                                    (first where))
                                            (rest where))
                               :as :rows
                               :columns '("turn_id"
                                          "coalesce(json_extract(payload, '$.\"from-model\"'), json_extract(payload, '$.model'))"
                                          "coalesce(json_extract(payload, '$.\"from-provider\"'), json_extract(payload, '$.provider'))"
                                          "json_extract(payload, '$.status')"))
              for key = (if (plusp (length model))
                            (list model provider)
                            (nlk:events :turn-id turn :order :newest :as :row
                                        :kind (list nlk::+kind-provider-request+ nlk::+kind-provider-retry+
                                                    nlk::+kind-provider-fallback+)
                                        :columns '("coalesce(json_extract(payload, '$.\"to-model\"'), json_extract(payload, '$.model'))"
                                                   "coalesce(json_extract(payload, '$.\"to-provider\"'), json_extract(payload, '$.provider'))")))
              when (plusp (length (first key)))
                do (push status (us-statuses (sum-of models key))))
        ;; Each model's waits and the time it spent writing, for its typical wait
        ;; and its speed.
        (loop for (model provider wait stream) in requests
              do (when-let (sum (gethash (list model provider) models))
                   (when (realp wait) (push wait sum.waits))
                   (when (realp stream) (incf sum.streamed stream))))
        (json-object
         "range" range
         :opt "from" (and start (iso-time (- start +unix-epoch+)))
         "totals" (usage-sum-json total
                                  "unpriced" (- (us-calls total) (us-priced total) account)
                                  "account_calls" account
                                  "saved_usd" (float saved 1d0)
                                  "turns" (nlk:events :kind nlk::+kind-turn-started+ :where (asked-where where)
                                                      :as :count)
                                  "failed_turns" (nlk:events :kind nlk::+kind-turn-failed+ :where (asked-where where)
                                                             :as :count))
         :opt "wait_p50_ms" (and waits (nth (floor (length waits) 2) waits))
         :opt "wait_p90_ms" (and waits (nth (floor (* 9 (length waits)) 10) waits))
         "days" (loop-vector for day in (if start
                                            (loop for universal from start to now by 86400
                                                  collect (local-day universal))
                                            (sort (alexandria:hash-table-keys days) #'string<))
                             for sum = (sum-of days day)
                             collect (usage-sum-json sum "day" day))
         "models" (loop-vector for ((model provider) . sum) in (ranked models)
                               for wait = (median-integer sum.waits)
                               for failed = sum.statuses
                               for attempts = (+ sum.calls (length failed))
                               ;; Each status the failures met, the commonest first.
                               for statuses = (sort (remove-duplicates (copy-list failed)) #'>
                                                    :key (lambda (status) (count status failed)))
                               collect (apply #'usage-sum-json sum "model" model "provider" provider
                                              "attempts" attempts "failed" (length failed)
                                              "error_rate" (/ (length failed) attempts 1d0)
                                              "statuses" (loop-vector for status in statuses
                                                                      collect (json-object :opt "status" status
                                                                                           "count" (count status failed)))
                                              (append
                                               (and wait (list "wait_p50_ms" wait))
                                               ;; Output over the time spent writing it.
                                               (and (plusp sum.streamed) (plusp sum.output)
                                                    (list "speed" (round sum.output
                                                                         (/ sum.streamed 1000)))))))
         "folders" (loop-vector for (name . sum) in (ranked folders 8)
                                collect (usage-sum-json sum "folder" name))
         "sessions" (loop-vector for (id . sum) in (ranked sessions 8)
                                 for entry = (gethash id entries)
                                 collect (usage-sum-json sum "id" id
                                                         "title" (or (getf entry :title) "")
                                                         "folder" (folder id)))))))))

(define-gateway-route handle-gateway-usage-http (env)
  "GET /api/gateway/usage?range=today|7d|30d|all — what every session spent
over the range (USAGE-JSON); seven days when unsaid."
  (:route :get "/api/gateway/usage" "usage")
  (usage-json (or (cdr (assoc "range" (gateway-query-parameters env) :test #'string=)) "7d")))

;;; --- activity: what the agent did over a range, and what went wrong -----------
;;; The Dashboard's second read, beside usage: each step sorted into the
;;; families the transcript titles it by (ACTIVITY-TITLE's own reader, so a
;;; step counts as `Read' here exactly where its card says `Read'), what each
;;; family cost, the hours the turns ran, the provider's failures, the turns
;;; that failed, and the newest model calls. A step failed when its result is
;;; the ERROR: text every reader of a tool result already keys on.

(defun step-families (name arguments)
  "What one call of tool NAME with ARGUMENTS did, as (FAMILY . ITEMS) in the
order it did them, or NIL when no activity family names it."
  (when-let (activity (with-handlers ((error () nil))
                        (tool-arguments-activity name (if (stringp arguments) arguments ""))))
    (if-let (entries (activity-entries activity))
      (loop for family in (remove-duplicates (mapcar #'first entries) :from-end t)
            collect (cons family (count family entries :key #'first)))
      (list (cons (activity-family activity) 1)))))

(defun step-title (name arguments)
  "One call of tool NAME in words, as its card titles it, else NAME."
  (or (with-handlers ((error () nil))
        (when-let (activity (tool-arguments-activity name (if (stringp arguments) arguments "")))
          (prompt-line (activity-title activity) 120)))
      name))

(defun by-count (table)
  "TABLE's (KEY COUNT . MORE) entries in its own order, then the commonest first."
  (sort (nreverse (alexandria:hash-table-alist table)) #'> :key #'second))

(defun spend-by-step-json (rounds)
  "Where ROUNDS' money went, each (POSITION TURN PRICE VOIDED .
WHAT-EACH-CALL-DID) with PRICE NIL for none: a round's price split evenly
over the calls it asked for, a call's share evenly over the families it did
(STEP-FAMILIES, else its tool's name), a round that asked for none writing
the reply, and what the voided attempts billed beside them. The parts sum to
the priced total; an unpriced round is counted, never summed as zero, and
still shares out the model calls. BY says what the parts are weighed by:
the money when most rounds have a price, else the model calls."
  (let ((parts (make-hash-table :test #'equal)) (spent nil) (answered 0) (unpriced 0))
    (flet ((charge (key cost share &aux (part (alexandria:ensure-gethash key parts (list nil 0 0))))
             ;; KEY's (COST ROUNDS CALLS): one more call, COST more spent
             ;; when known, and SHARE more of a round.
             (when cost (setf (first part) (+ (or (first part) 0) cost)))
             (incf (second part) share)
             (incf (third part))))
      (loop for (nil nil price voided . calls) in rounds
            do (when price (setf spent (+ (or spent 0) price)))
               (cond (voided (when price (charge :voided price 0)))
                     (t (incf answered)
                        (unless price (incf unpriced))
                        (if calls
                            (dolist (keys calls)
                              (dolist (key keys)
                                (let ((share (/ 1d0 (length calls) (length keys))))
                                  (charge key (and price (* price share)) share))))
                            (charge :reply price 1))))))
    (let ((money (and spent (>= (- answered unpriced) unpriced))))
      (flet ((weight (entry) (if money (or (second entry) 0) (third entry))))
        (json-object
         :opt "cost_usd" spent
         "rounds" answered
         "unpriced" unpriced
         "by" (if money "cost" "calls")
         "parts" (loop-vector for (key cost share calls)
                              in (sort (nreverse (alexandria:hash-table-alist parts))
                                       ;; The weightiest first, then the most model calls.
                                       (descending #'weight #'third))
                              for plist = (and (keywordp key) (activity-family-plist key))
                              collect (json-object :when plist "family" (string-downcase key)
                                                   :when plist "verb" (getf plist :past)
                                                   :when plist "many" (getf plist :many)
                                                   :when (stringp key) "tool" key
                                                   :when (eq key :reply) "reply" t
                                                   :when (eq key :voided) "voided" t
                                                   :opt "cost_usd" cost
                                                   "rounds" (float share 1d0)
                                                   "calls" calls)))))))

(defun activity-json (range &aux (now (get-universal-time)))
  "What the agent did over RANGE (USAGE-RANGE-START) and what went wrong: its
steps by family, the slowest of them, where the money went by step
(SPEND-BY-STEP-JSON), the hour each turn started, the provider's retries and
switches, the failed turns, and the newest calls."
  (nlk::with-store-reader ()
    (let* ((start (usage-range-start range now))
           (where (and start (list "occurred_at >= ?" (iso-time (- start +unix-epoch+)))))
           (results (make-hash-table :test #'equal))
           (families (make-hash-table :test #'eq))
           (others (make-hash-table :test #'equal))
           (hours (make-array '(7 24) :initial-element 0))
           (steps 0) (failed-steps 0) (step-ms 0) (slowest '())
           ;; The range's rounds, oldest first, as (POSITION TURN PRICE VOIDED .
           ;; WHAT-EACH-CALL-DID): a call belongs to the round its turn logged
           ;; last before it, and a voided attempt is no turn's round.
           (rounds (loop for (position turn cost voided)
                           in (nlk:events :kind nlk::+kind-turn-usage+ :where where :as :rows
                                          ;; The price is read only where it is known.
                                          :columns '("log_position" "turn_id"
                                                     "case when json_extract(payload, '$.cost_known')
                                                        then json_extract(payload, '$.cost_usd') end"
                                                     "json_extract(payload, '$.voided')"))
                         collect (list position turn (and (realp cost) cost) (eql voided 1))))
           (waiting rounds)
           (open-rounds (make-hash-table :test #'equal)))
      ;; The calls a page at a time: a month of arguments is tens of megabytes,
      ;; and only the six slowest are kept past their page. The results are
      ;; read once the first page says where the range's calls begin: a result
      ;; is logged after its call, so none before that is ever looked up, and
      ;; a week's read skips the older results' rows.
      (loop for after = nil then (first (car (last page)))
            for page = (nlk:events :kind nlk::+kind-tool-call-started+ :where where :after after
                                   :limit 2000 :as :rows
                                   :columns (list* "log_position" "session_id" "turn_id"
                                                   (payload-columns "call-id" "tool-name"
                                                                    "arguments")))
            while page
            do (unless after
                 (loop for (turn call ms error)
                         in (nlk:events :kind nlk::+kind-tool-result+ :where where
                                        :after (first (first page)) :as :rows
                                        :columns '("turn_id" "json_extract(payload, '$.\"call-id\"')"
                                                   "json_extract(payload, '$.\"duration-ms\"')"
                                                   "substr(json_extract(payload, '$.result'), 1, 6) = 'ERROR:'"))
                       do (setf (gethash (cons turn call) results) (cons ms (eql error 1)))))
               (loop for (position session turn call name arguments) in page
                     for (ms . failed) = (gethash (cons turn call) results)
                     for did = (step-families name arguments)
                     do (loop for round = (first waiting)
                              while (and round (< (first round) position))
                              do (pop waiting)
                                 (unless (fourth round) (setf (gethash (second round) open-rounds) round)))
                        (when-let (round (gethash turn open-rounds))
                          (push (if did (mapcar #'car did) (list name)) (cddddr round)))
                        (incf steps)
                        (when failed (incf failed-steps))
                        (when (realp ms)
                          (incf step-ms ms)
                          (when (or (< (length slowest) 6) (> ms (first (car (last slowest)))))
                            (setf slowest (merge 'list (list (list ms session turn name arguments))
                                                 slowest #'> :key #'first))
                            (when (> (length slowest) 6) (setf slowest (subseq slowest 0 6)))))
                        (if did
                            (loop for (family . items) in did
                                  for sum = (alexandria:ensure-gethash family families (list 0 0 0))
                                  do (incf (first sum)) (incf (second sum) items)
                                     (when failed (incf (third sum))))
                            (let ((sum (alexandria:ensure-gethash name others (list 0 0))))
                              (incf (first sum))
                              (when failed (incf (second sum)))))))
      (loop for (at) in (nlk:events :kind nlk::+kind-turn-started+ :where (asked-where where) :as :rows
                                    :columns '("occurred_at"))
            for universal = (iso-universal at)
            when universal
              do (bind (((_ _ hour _ _ _ weekday) (decode-universal-time universal)))
                   (incf (aref hours weekday hour))))
      (let ((retries (make-hash-table :test #'equal))
            (fallbacks (make-hash-table :test #'equal))
            (calls '()) (waiting (make-hash-table :test #'equal)))
        (loop for (status detail)
                in (nlk:events :kind nlk::+kind-provider-retry+ :where where :as :rows
                               :columns (payload-columns "status" "detail"))
              for sum = (alexandria:ensure-gethash status retries (list 0 nil))
              do (incf (first sum))
                 (setf (second sum) detail))
        (loop for (from to reason)
                in (nlk:events :kind nlk::+kind-provider-fallback+ :where where :as :rows
                               :columns (payload-columns "from-model" "to-model" "reason"))
              do (incf (gethash (list from to reason) fallbacks 0)))
        ;; Newest first, a round's usage comes just before its request: the
        ;; request that follows a usage in the same turn is that round's.
        (loop for (kind session turn at model provider input cached write output known cost voided wait stream)
                in (nlk:events :kind (list nlk::+kind-turn-usage+ nlk::+kind-provider-request+)
                               :where where :order :newest :limit 80 :as :rows
                               :columns (list* "kind" "session_id" "turn_id" "occurred_at"
                                               (append (subseq +usage-columns+ 2)
                                                       (payload-columns "ttft-ms" "stream-duration-ms"))))
              do (cond ((and (equal kind nlk::+kind-turn-usage+) (not (eql voided 1)))
                        (let ((call (json-object "at" at "session_id" session
                                                 "title" (nlk::session-title session)
                                                 "turn_id" turn "model" model "provider" provider
                                                 :opt "input" input :opt "cached" cached
                                                 :opt "cache_write" write :opt "output" output
                                                 :opt "cost_usd" (and (eql known 1) (realp cost) cost))))
                          (push call calls)
                          (setf (gethash turn waiting) call)))
                       ((equal kind nlk::+kind-provider-request+)
                        (when-let (call (gethash turn waiting))
                          (remhash turn waiting)
                          (when (realp wait) (setf (gethash "wait_ms" call) wait))
                          (when (realp stream) (setf (gethash "stream_ms" call) stream))))))
        (json-object
         "range" range
         :opt "from" (and start (iso-time (- start +unix-epoch+)))
         "steps" (json-object "count" steps "failed" failed-steps :when (plusp step-ms) "ms" step-ms)
         "families" (loop-vector for (family used items failed) in (by-count families)
                                 for plist = (activity-family-plist family)
                                 collect (json-object "family" (string-downcase family)
                                                      "verb" (getf plist :past)
                                                      "one" (getf plist :one) "many" (getf plist :many)
                                                      "calls" used "items" items "failed" failed))
         "other_tools" (loop-vector for (name used failed) in (by-count others)
                                    collect (json-object "tool" name "calls" used "failed" failed))
         "spend" (spend-by-step-json rounds)
         "slowest" (loop-vector for (ms session turn name arguments) in slowest
                                collect (json-object "ms" ms "session_id" session
                                                     "title" (nlk::session-title session)
                                                     "turn_id" turn "tool" name
                                                     "step" (step-title name arguments)))
         "hours" (loop-vector for day below 7
                              collect (loop-vector for hour below 24 collect (aref hours day hour)))
         "retries" (loop-vector for (status count detail) in (by-count retries)
                                collect (json-object :opt "status" status "count" count
                                                     "detail" (prompt-line detail 160)))
         "fallbacks" (loop-vector for (from to reason) being the hash-keys of fallbacks using (hash-value count)
                                  collect (json-object "from" from "to" to "reason" reason "count" count))
         "failed_turns"
         (json-object
          "count" (nlk:events :kind nlk::+kind-turn-failed+ :where (asked-where where) :as :count)
          "cancelled" (nlk:events :kind nlk::+kind-turn-cancelled+ :where (asked-where where) :as :count)
          "latest" (loop-vector for (session turn at detail status)
                                in (nlk:events :kind nlk::+kind-turn-failed+ :where (asked-where where)
                                               :order :newest :limit 6 :as :rows
                                               :columns (list* "session_id" "turn_id" "occurred_at"
                                                               (payload-columns "detail" "status")))
                                collect (json-object "session_id" session
                                                     "title" (nlk::session-title session)
                                                     "turn_id" turn "at" at
                                                     "detail" (prompt-line detail 200)
                                                     :opt "status" status)))
         "calls" (loop-vector for call in (nreverse calls) repeat 30 collect call))))))

(define-gateway-route handle-gateway-activity-http (env)
  "GET /api/gateway/activity?range=today|7d|30d|all — what the agent did over
the range and what went wrong (ACTIVITY-JSON); seven days when unsaid."
  (:route :get "/api/gateway/activity" "activity")
  ;; Sorting a month of steps conses a gigabyte and more in passing:
  ;; under the organism's 2 MB nursery that is a collection every two
  ;; megabytes. The read's nursery is the read's, as a compile's is
  ;; (COMPILE-LAYER-SHARES), and the cap comes back after.
  (nlk:with-nursery ((* 64 1024 1024))
    (activity-json (or (cdr (assoc "range" (gateway-query-parameters env) :test #'string=)) "7d"))))

;;; --- /usage: the usage read as text ---------------------------------------------
;;; One rendering for every text surface: the shell's /usage asks its gateway
;;; for the read, a channel's or the web page's `/' runs it in the gateway's own
;;; image (HEADLESS-USAGE), and both print USAGE-REPORT-TEXT of the same object.

(defun usage-range-word (args &aux (word (string-trim '(#\Space #\Tab) (or args ""))))
  "The range ARGS names for /usage -- seven days when empty -- or NIL."
  ;; What /usage takes after its name, and the range each word means.
  (dispatch word string-equal ("" "7d") ("today" "today") ("7d" "7d") ("week" "7d")
    ("30d" "30d") ("month" "30d") ("all" "all")))

(defun usage-field (object key &aux (value (and (hash-table-p object) (gethash key object))))
  "KEY of OBJECT, a usage read's object in memory or off the wire, NIL for
absent, null or false."
  (if (member value '(:null :false)) nil value))

(defun usd-text (value)
  "VALUE in dollars as a reader counts them, a dash for no price."
  (cond ((not (realp value)) "-")
        ((< value 0.01) (format nil "$~,3f" value))
        (t (format nil "$~,2f" value))))

(defun ms-text (ms)
  "MS as a wait reads: milliseconds, seconds to a tenth, then DURATION-TEXT;
a dash for none."
  (cond ((not (realp ms)) "-")
        ((< ms 1000) (format nil "~d ms" (round ms)))
        ((< ms 10000) (format nil "~,1f s" (/ ms 1000)))
        (t (duration-text (/ ms 1000)))))

(defun share-text (share)
  "SHARE, a fraction, as a whole percent; a dash for none."
  (if (realp share) (format nil "~d%" (round (* 100 share))) "-"))

(defun folder-tail (dir)
  "DIR's last two segments: what tells one project from another."
  (let ((parts (remove "" (uiop:split-string (or dir "") :separator "/") :test #'string=)))
    (if parts (format nil "~{~a~^/~}" (last parts 2)) "-")))

(defun counted (n word)
  "N WORDs, the count grouped by thousands."
  (format nil "~:d ~a~:[s~;~]" n word (eql n 1)))

(defun usage-range-phrase (range)
  "RANGE as /usage says it: today, these 30 days, all told, else this week."
  (dispatch range equal
    ("today" "today") ("30d" "these 30 days") ("all" "all told") (t "this week")))

(defun usage-headline (usage &aux (totals (usage-field usage "totals"))
                                  (cost (usage-field totals "cost_usd")))
  "The sentence the Usage view leads with: the range, the spend or the calls,
and the sessions."
  (format nil "~@(~a~), ~a across ~a." (usage-range-phrase (usage-field usage "range"))
          (if cost (usd-text cost) (counted (or (usage-field totals "calls") 0) "model call"))
          (counted (or (usage-field totals "sessions") 0) "session")))

(defun usage-since (usage)
  "The first local day USAGE counts, as \"Sep 20\", or NIL for everything."
  (when-let (universal (iso-universal (usage-field usage "from")))
    (bind (((_ _ _ day month) (decode-universal-time universal)))
      (format nil "~a ~d" (nth (1- month) '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul"
                                           "Aug" "Sep" "Oct" "Nov" "Dec"))
              day))))

(defun usage-sentences (usage &aux (totals (usage-field usage "totals"))
                                   (cost (usage-field totals "cost_usd"))
                                   (calls (or (usage-field totals "calls") 0))
                                   (unpriced (or (usage-field totals "unpriced") 0))
                                   (saved (usage-field totals "saved_usd"))
                                   (turns (or (usage-field totals "turns") 0)))
  "What follows the headline: the calls, the cache, the unpriced calls, the
failed turns -- each only when it says something."
  (remove nil
          (list (and cost (format nil "~a." (counted calls "model call")))
                (cond ((and (realp saved) (> saved 0.005))
                       (format nil "Reusing the prompt from cache saved about ~a." (usd-text saved)))
                      ((and (realp saved) (< saved -0.005))
                       (format nil "Writing the prompt to cache cost about ~a more than reading it back saved."
                               (usd-text (- saved))))
                      ((usage-field totals "cached_share")
                       (format nil "~a of the prompt came from cache."
                               (share-text (usage-field totals "cached_share")))))
                (let ((account (or (usage-field totals "account_calls") 0)))
                  (and (plusp account)
                       (format nil "~a on your nodecode.ai account, paid in its plan's requests or its credit."
                               (if (eql account 1) "1 call ran" (format nil "~:d calls ran" account)))))
                (and (plusp unpriced)
                     (format nil "~a no price~:[~;, so the spend is a floor~]."
                             (if (eql unpriced 1) "1 call has" (format nil "~:d calls have" unpriced))
                             cost))
                (and (plusp turns)
                     (format nil "~:d of ~a failed." (or (usage-field totals "failed_turns") 0)
                             (counted turns "turn"))))))

(defun usage-report-text (usage)
  "USAGE, the usage read (USAGE-JSON, or the copy its route sent), as the
lines a text surface prints: the Usage view's sentence and its tables."
  (flet ((clip (text width) (stub-clip (or text "") width "~"))
         (took (ms) (if (and (realp ms) (plusp ms)) (ms-text ms) "-")))
    (let ((cost (usage-field (usage-field usage "totals") "cost_usd")))
      (with-output-to-string (out)
        (format out "Usage · ~a~@[ (since ~a)~] · API-equivalent prices~%"
                (usage-range-phrase (usage-field usage "range")) (usage-since usage))
        (format out "~a~%~{~a~^ ~}~%" (usage-headline usage) (usage-sentences usage))
        (when (usage-field usage "wait_p50_ms")
          (format out "First word ~a typical (TTFT p50), ~a at p90.~%"
                  (ms-text (usage-field usage "wait_p50_ms")) (ms-text (usage-field usage "wait_p90_ms"))))
        (when-let (models (coerce (or (usage-field usage "models") #()) 'list))
          (format out "~%~32a ~8@a ~6@a ~9@a~%" "model" "calls" "cache" "spend")
          (dolist (model (subseq models 0 (min 6 (length models))))
            (format out "~32a ~8:d ~6@a ~9@a~%" (clip (usage-field model "model") 32)
                    (usage-field model "calls")
                    (share-text (usage-field model "cached_share"))
                    (usd-text (usage-field model "cost_usd")))))
        (when-let (rows (coerce (or (usage-field usage "sessions") #()) 'list))
          (format out "~%~a~%" (if cost "costliest sessions" "busiest sessions"))
          (dolist (row (subseq rows 0 (min 5 (length rows))))
            (format out "~32a ~16a ~8@a ~9@a~%"
                    (clip (let ((title (usage-field row "title")))
                            (if (plusp (length title)) title (usage-field row "id")))
                          32)
                    (clip (folder-tail (usage-field row "folder")) 16) (took (usage-field row "ms"))
                    (if (usage-field row "cost_usd") (usd-text (usage-field row "cost_usd"))
                        (format nil "~:d calls" (usage-field row "calls"))))))
        (when-let (folders (coerce (or (usage-field usage "folders") #()) 'list))
          (format out "~%~32a ~16@a ~8@a ~9@a~%" "folder" "sessions" "time" "spend")
          (dolist (folder (subseq folders 0 (min 5 (length folders))))
            (format out "~32a ~16:d ~8@a ~9@a~%" (clip (folder-tail (usage-field folder "folder")) 32)
                    (usage-field folder "sessions") (took (usage-field folder "ms"))
                    (usd-text (usage-field folder "cost_usd")))))))))

(defun headless-usage (args session-id)
  "The /usage answer without a shell: the usage read over the range ARGS
names, in this image, as text."
  (declare (ignore session-id))
  (if-let (range (usage-range-word args))
    (string-right-trim '(#\Newline) (usage-report-text (usage-json range)))
    "Usage: /usage [today | 7d | 30d | all]"))
