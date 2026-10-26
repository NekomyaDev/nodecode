;;;; connection.lisp --- the footer's connection knob: who can read a prompt sent to the model
;;;; this shell has chosen, and how it travels there, measured once when the model is chosen.
;;;;
;;;; SPDX-License-Identifier: MIT
;;;;
;;;; Two halves. What the wire says is measured: one TLS handshake with the endpoint the chosen
;;;; model's lane dials -- the protocol, whether the key exchange is post-quantum, who issued the
;;;; certificate, whether Cloudflare answers in front -- and nothing of the person's is sent. What
;;;; the provider promises is read from *PROVIDER-TERMS*, matched on that endpoint's host: a
;;;; host on no row is unknown, and so unsecure. Only NODECODE's own endpoint reads Private.

(in-package #:nodecode.evolved)

;;; --- what each provider promises ----------------------------------------------
;;; From a survey of each provider's own terms and privacy pages (checked 2026-10). A row's HOSTS
;;; decide who answers (a suffix, or a glob with *); its IDS are the providers whose API those
;;; terms are -- a subscription reaching the same host (a sign-in cell) is not on them, and reads
;;; unknown. STORED is what the terms say happens to a prompt; TRAINS and ZDR their defaults.

(defparameter *provider-terms-checked* "2026-10")

(defparameter *provider-terms*
  '((:name "NODECODE" :own t :hosts ("api.nodecode.ai") :ids ("nodecode") :where "DE → NL" :eu t
     :stored "no" :trains :no :zdr :yes :source "nodecode.ai/privacy")
    (:name "Anthropic" :hosts ("api.anthropic.com") :ids ("anthropic") :where "US"
     :stored "30 days" :trains :no :zdr :enterprise :source "privacy.anthropic.com")
    (:name "OpenAI" :hosts ("api.openai.com") :ids ("openai") :where "US" :eu :option
     :stored "30 days" :trains :no :zdr :request :source "openai.com/policies")
    (:name "Google" :hosts ("generativelanguage.googleapis.com") :ids ("google") :where "US"
     :stored "55 days" :trains :free-tier :zdr :no :source "ai.google.dev/gemini-api/terms")
    (:name "Google Vertex" :hosts ("aiplatform.googleapis.com" "*-aiplatform.googleapis.com")
     :ids ("google-vertex" "google-vertex-anthropic") :where "US" :eu :option
     :stored "24 h cache" :trains :no :zdr :yes :source "cloud.google.com/vertex-ai")
    (:name "Azure OpenAI" :hosts ("openai.azure.com" "services.ai.azure.com" "cognitiveservices.azure.com")
     :ids ("azure" "azure-cognitive-services") :where "US" :eu :option
     :stored "30 days" :trains :no :zdr :request :source "learn.microsoft.com/azure/ai-foundry")
    (:name "AWS Bedrock" :hosts ("bedrock-runtime.*.amazonaws.com") :ids ("amazon-bedrock") :where "US" :eu :option
     :stored "no" :trains :no :zdr :yes :source "aws.amazon.com/bedrock/security-compliance")
    (:name "xAI" :hosts ("api.x.ai") :ids ("xai") :where "US"
     :stored "30 days" :trains :no :zdr :enterprise :source "x.ai/legal")
    (:name "Cohere" :hosts ("api.cohere.com" "api.cohere.ai") :ids ("cohere") :where "CA"
     :stored "30 days" :trains :no :zdr :request :source "cohere.com/privacy")
    (:name "Perplexity" :hosts ("api.perplexity.ai") :ids ("perplexity" "perplexity-agent") :where "US"
     :stored "unknown" :trains :no :zdr :request :source "perplexity.ai/hub/legal")
    (:name "Mistral" :hosts ("api.mistral.ai") :ids ("mistral") :where "FR" :eu t
     :stored "30 days" :trains :free-tier :zdr :request :source "legal.mistral.ai")
    (:name "DeepSeek" :hosts ("api.deepseek.com") :ids ("deepseek") :where "CN"
     :stored "no limit" :trains :unknown :zdr :no :source "cdn.deepseek.com/policies")
    (:name "OpenRouter" :router t :hosts ("openrouter.ai") :ids ("openrouter") :where "US" :eu :option
     :stored "no" :trains :no :zdr :yes :source "openrouter.ai/privacy")
    (:name "Canopy Wave" :hosts ("canopywave.io") :ids ("canopywave") :where "US"
     :stored "no" :trains :no :zdr :yes :source "canopywave.com/zero-data-retention-policy")
    (:name "Nebius" :hosts ("api.tokenfactory.nebius.com" "api.studio.nebius.com" "api.studio.nebius.ai")
     :ids ("nebius") :where "NL" :eu :option
     :stored "yes" :trains :drafts :zdr :yes :source "docs.tokenfactory.nebius.com/legal")
    (:name "Regolo" :hosts ("api.regolo.ai") :ids ("regolo-ai") :where "IT" :eu t
     :stored "no" :trains :no :zdr :yes :source "regolo.ai/privacy")
    (:name "GreenPT" :hosts ("api.greenpt.ai") :ids ("greenpt") :where "NL" :eu t
     :stored "unknown" :trains :no :zdr :unknown :source "greenpt.com/privacy")
    (:name "Tensorix" :hosts ("api.tensorx.ai") :ids ("tensorx") :where "IE" :eu t
     :stored "no" :trains :no :zdr :yes :source "tensorix.ai/privacy")
    (:name "Infercom" :hosts ("api.infercom.ai") :ids ("infercom") :where "LU" :eu t
     :stored "no" :trains :no :zdr :yes :source "infercom.ai/privacy")
    (:name "Berget AI" :hosts ("api.berget.ai") :ids ("berget") :where "SE" :eu t
     :stored "unknown" :trains :unknown :zdr :unknown :source "berget.ai/privacy")
    (:name "evroc" :hosts ("evroc.com") :ids ("evroc") :where "SE" :eu t
     :stored "unknown" :trains :no :zdr :unknown :source "evroc.com/legal")
    (:name "AKI.IO" :hosts ("aki.io") :ids ("aki-io") :where "DE" :eu t
     :stored "unknown" :trains :unknown :zdr :unknown :source "aki.io/processors")
    (:name "Inceptron" :hosts ("api.inceptron.io") :ids ("inceptron") :where "SE" :eu t
     :stored "no" :trains :no :zdr :yes :source "inceptron.io")
    (:name "Lyceum" :hosts ("api.lyceum.technology") :ids ("lyceum") :where "DE" :eu t
     :stored "no" :trains :no :zdr :yes :source "lyceum.technology/trust")
    (:name "Scaleway" :hosts ("api.scaleway.ai") :ids ("scaleway") :where "FR" :eu t
     :stored "no" :trains :no :zdr :yes :source "scaleway.com/legal")
    (:name "OVHcloud" :hosts ("endpoints.kepler.ai.cloud.ovh.net") :ids ("ovhcloud") :where "FR" :eu t
     :stored "no" :trains :no :zdr :yes :source "ovhcloud.com/legal")
    (:name "IONOS" :hosts ("inference.de-txl.ionos.com") :ids ("ionos") :where "DE" :eu t
     :stored "no" :trains :no :zdr :yes :source "ionos.com/terms")
    (:name "STACKIT" :hosts ("model-serving.eu01.onstackit.cloud") :ids ("stackit") :where "DE" :eu t
     :stored "no" :trains :no :zdr :yes :source "stackit.com/privacy")
    (:name "Synthetic" :hosts ("api.synthetic.new") :ids ("synthetic") :where "US"
     :stored "14 days" :trains :no :zdr :unknown :source "synthetic.new/policies")
    (:name "Together AI" :hosts ("api.together.xyz" "api.together.ai") :ids ("togetherai") :where "US"
     :stored "yes" :trains :no :zdr :yes :source "together.ai/privacy")
    (:name "Fireworks" :hosts ("api.fireworks.ai") :ids ("fireworks-ai") :where "US"
     :stored "no" :trains :no :zdr :yes :source "fireworks.ai/privacy-policy")
    (:name "Groq" :hosts ("api.groq.com") :ids ("groq") :where "US" :eu :option
     :stored "up to 30 days" :trains :no :zdr :yes :source "console.groq.com/docs/your-data")
    (:name "Cerebras" :hosts ("api.cerebras.ai") :ids ("cerebras") :where "US"
     :stored "no" :trains :no :zdr :yes :source "cerebras.ai/privacy-policy")
    (:name "SambaNova" :hosts ("api.sambanova.ai") :ids ("sambanova") :where "US"
     :stored "no" :trains :no :zdr :yes :source "sambanova.ai/privacy-policy")
    (:name "DeepInfra" :hosts ("api.deepinfra.com") :ids ("deepinfra") :where "US"
     :stored "no" :trains :no :zdr :yes :source "deepinfra.com/privacy")
    (:name "Replicate" :hosts ("api.replicate.com") :ids ("replicate") :where "US"
     :stored "1 hour" :trains :unknown :zdr :no :source "replicate.com/privacy")
    (:name "Baseten" :hosts ("inference.baseten.co" "api.baseten.co") :ids ("baseten") :where "US" :eu :option
     :stored "no" :trains :no :zdr :yes :source "baseten.co/privacy-policy")
    (:name "Hyperbolic" :hosts ("api.hyperbolic.xyz") :ids ("hyperbolic") :where "US"
     :stored "no" :trains :no :zdr :yes :source "hyperbolic.xyz/privacy")
    (:name "Novita AI" :hosts ("api.novita.ai") :ids ("novita-ai") :where "US"
     :stored "unknown" :trains :no :zdr :yes :source "novita.ai/legal/privacy-policy")
    (:name "Lambda" :hosts ("api.lambdalabs.com" "api.lambda.ai") :ids ("lambda") :where "US"
     :stored "no" :trains :no :zdr :yes :source "lambda.ai/legal/privacy-policy")
    (:name "Featherless" :hosts ("api.featherless.ai") :ids ("featherless") :where "US"
     :stored "no" :trains :no :zdr :yes :source "featherless.ai/privacy")
    (:name "Chutes" :hosts ("chutes.ai") :ids ("chutes") :where "US"
     :stored "no" :trains :no :zdr :yes :source "chutes.ai/privacy")
    (:name "Parasail" :hosts ("api.parasail.io") :ids ("parasail") :where "US"
     :stored "no" :trains :no :zdr :yes :source "parasail.io/legal")
    (:name "Nscale" :hosts ("nscale.com") :ids ("nscale") :where "UK" :eu :option
     :stored "unknown" :trains :unknown :zdr :unknown :source "nscale.com/legal")
    (:name "Cloudflare" :hosts ("api.cloudflare.com") :ids ("cloudflare-workers-ai") :where "US" :eu :option
     :stored "no" :trains :no :zdr :yes :source "developers.cloudflare.com/workers-ai/privacy")
    (:name "Hugging Face" :router t :hosts ("router.huggingface.co" "api-inference.huggingface.co")
     :ids ("huggingface") :where "US"
     :stored "no" :trains :no :zdr :unknown :source "huggingface.co/privacy")
    (:name "Modal" :hosts ("modal.direct" "modal.run") :ids ("modal") :where "US" :eu :option
     :stored "up to 7 days" :trains :no :zdr :yes :source "modal.com/legal/privacy-policy")
    (:name "NVIDIA" :hosts ("integrate.api.nvidia.com") :ids ("nvidia") :where "US"
     :stored "unknown" :trains :unknown :zdr :no :source "build.nvidia.com")
    (:name "Inference.net" :hosts ("inference.net") :ids ("inference") :where "US"
     :stored "no" :trains :no :zdr :yes :source "inference.net/privacy")
    (:name "FriendliAI" :hosts ("api.friendli.ai") :ids ("friendli") :where "KR"
     :stored "no" :trains :no :zdr :yes :source "friendli.ai/privacy-policy")
    (:name "Alibaba Cloud" :hosts ("aliyuncs.com") :ids ("alibaba" "alibaba-cn") :where "CN" :eu :option
     :stored "unknown" :trains :no :zdr :no :source "alibabacloud.com/help/model-studio")
    (:name "Moonshot AI" :hosts ("api.moonshot.ai" "api.moonshot.cn" "api.kimi.com" "api.kimi.ai")
     :ids ("moonshotai" "moonshotai-cn") :where "CN"
     :stored "unknown" :trains :no :zdr :no :source "platform.moonshot.ai/docs")
    (:name "Z.ai" :hosts ("api.z.ai" "open.bigmodel.cn") :ids ("zai" "zhipuai") :where "CN"
     :stored "unknown" :trains :unknown :zdr :no :source "docs.z.ai/legal")
    (:name "MiniMax" :hosts ("api.minimax.io" "api.minimax.cn" "api.minimaxi.com") :ids ("minimax" "minimax-cn")
     :where "CN" :stored "unknown" :trains :unknown :zdr :no :source "minimax.io/platform/protocol")
    (:name "ByteDance" :hosts ("volces.com" "bytepluses.com") :ids ("volcengine" "byteplus") :where "CN"
     :stored "unknown" :trains :no :zdr :unknown :source "docs.byteplus.com/modelark")
    (:name "Baidu" :hosts ("qianfan.baidubce.com") :ids ("qianfan") :where "CN"
     :stored "unknown" :trains :unknown :zdr :no :source "cloud.baidu.com")
    (:name "Tencent" :hosts ("tencentcloudapi.com" "cloud.tencent.com" "tencentmaas.com") :ids ("tencent-tokenhub")
     :where "CN" :stored "unknown" :trains :unknown :zdr :no :source "cloud.tencent.com")
    (:name "StepFun" :hosts ("api.stepfun.com" "api.stepfun.ai") :ids ("stepfun" "stepfun-ai") :where "CN"
     :stored "unknown" :trains :unknown :zdr :no :source "platform.stepfun.com")
    (:name "01.AI" :hosts ("api.lingyiwanwu.com" "api.01.ai") :ids ("01-ai") :where "CN"
     :stored "unknown" :trains :unknown :zdr :no :source "platform.lingyiwanwu.com")
    (:name "SiliconFlow" :hosts ("api.siliconflow.com" "api.siliconflow.cn") :ids ("siliconflow" "siliconflow-cn")
     :where "CN" :stored "unknown" :trains :unknown :zdr :unknown :source "siliconflow.com/privacy")
    (:name "AI21" :hosts ("api.ai21.com") :ids ("ai21") :where "IL"
     :stored "unknown" :trains :unknown :zdr :enterprise :source "ai21.com/privacy-policy")
    (:name "Reka" :hosts ("api.reka.ai") :ids ("reka") :where "US"
     :stored "unknown" :trains :unknown :zdr :unknown :source "reka.ai/privacy")
    (:name "Writer" :hosts ("api.writer.com") :ids ("writer") :where "US"
     :stored "unknown" :trains :no :zdr :enterprise :source "writer.com/legal")
    (:name "Requesty" :router t :hosts ("requesty.ai") :ids ("requesty") :where "UK" :eu :option
     :stored "yes" :trains :no :zdr :request :source "requesty.ai/privacy")
    (:name "Eden AI" :router t :hosts ("api.edenai.run") :ids ("edenai") :where "FR" :eu :option
     :stored "unknown" :trains :no :zdr :unknown :source "edenai.co/privacy-policy")
    (:name "Portkey" :router t :hosts ("api.portkey.ai") :ids ("portkey") :where "US" :eu :option
     :stored "yes" :trains :no :zdr :request :source "portkey.ai/privacy-policy")
    (:name "Vercel" :router t :hosts ("ai-gateway.vercel.sh") :ids ("vercel") :where "US"
     :stored "unknown" :trains :no :zdr :request :source "vercel.com/legal/privacy-policy")
    (:name "Opper" :router t :hosts ("api.opper.ai") :ids ("opper") :where "SE" :eu :option
     :stored "unknown" :trains :no :zdr :unknown :source "opper.ai/privacy")
    (:name "Venice" :hosts ("api.venice.ai") :ids ("venice") :where "US"
     :stored "no" :trains :no :zdr :yes :source "venice.ai/privacy")
    (:name "Poe" :router t :hosts ("api.poe.com") :ids ("poe") :where "US"
     :stored "unknown" :trains :unknown :zdr :no :source "poe.com/privacy"))
  "Each provider's terms as a plist (see the section head); a host on no row is unknown.")

(defun host-matches-p (host pattern)
  "Whether HOST is PATTERN or under it: a suffix on a dot, or a glob whose * is one label's part."
  (let ((host (string-downcase host)))
    (if (find #\* pattern)
        (and (ppcre:scan (format nil "^(?:[^.]+\\.)*~{~a~^[a-z0-9-]+~}$"
                                 (mapcar #'ppcre:quote-meta-chars (uiop:split-string pattern :separator "*")))
                         host)
             t)
        (or (string= host pattern) (uiop:string-suffix-p host (concatenate 'string "." pattern))))))

(defun provider-terms (host)
  "The *PROVIDER-TERMS* row HOST answers for, else NIL: not on the list."
  (and (stringp host)
       (find-if (lambda (row) (some (lambda (pattern) (host-matches-p host pattern)) (getf row :hosts)))
                *provider-terms*)))

;;; --- what the wire says ---------------------------------------------------------

(defparameter *public-certificate-issuers*
  '("let's encrypt" "google trust" "digicert" "sectigo" "comodo" "globalsign" "amazon" "microsoft"
    "godaddy" "starfield" "entrust" "zerossl" "identrust" "cloudflare" "ssl corporation" "certum"
    "asseco" "buypass" "harica" "actalis" "quovadis" "swisssign" "telia" "trustasia" "geant" "apple")
  "Public certificate authorities: an issuer outside them is a certificate this machine was made to
trust -- a company proxy or an antivirus reading the traffic.")

(defun connection-endpoint (provider model)
  "The URL a turn on PROVIDER's MODEL dials (EFFECTIVE-ENDPOINT's rule), else its base: the host
is what the check measures. NIL when nothing names one."
  (or (ignore-errors (lane-endpoint provider (resolve-model-lane provider model)))
      (ignore-errors (provider-endpoint provider))
      (ignore-errors (provider-base-url provider))))

(defun connection-proxy ()
  "The proxy every provider request goes through, else NIL."
  (let ((proxy dex:*default-proxy*))
    (and (stringp proxy) (plusp (length proxy)) proxy)))

(defun issuer-organization (oneline)
  "The O= of an X509_NAME_oneline string, else the whole string."
  (or (ppcre:register-groups-bind (org) ("/O=([^/]+)" oneline) org) oneline))

(defun tls-peer-facts (stream)
  "STREAM's handshake => (:TLS version :GROUP key exchange :ISSUER organization)."
  (let* ((handle (cl+ssl::ssl-stream-handle stream))
         (group-name (cffi:foreign-symbol-pointer "SSL_get0_group_name"))
         (certificate (cl+ssl:ssl-stream-x509-certificate stream)))
    (list :tls (cffi:foreign-funcall "SSL_get_version" :pointer handle :string)
          :group (and group-name (cffi:foreign-funcall-pointer group-name () :pointer handle :string))
          :issuer (unless (cffi:null-pointer-p certificate)
                    (unwind-protect
                         (issuer-organization
                          (cffi:with-foreign-pointer-as-string (buffer 512)
                            (cffi:foreign-funcall "X509_NAME_oneline"
                                                  :pointer (cffi:foreign-funcall "X509_get_issuer_name"
                                                                                 :pointer certificate :pointer)
                                                  :pointer buffer :int 512 :pointer)))
                      (cffi:foreign-funcall "X509_free" :pointer certificate :void))))))

(defun cloudflare-answers-p (stream host)
  "Whether a bare HEAD over STREAM is answered by Cloudflare's edge: it decrypts before the provider."
  (let ((crlf (coerce '(#\Return #\Newline) 'string)))
    (write-sequence (sb-ext:string-to-octets
                     (format nil "HEAD / HTTP/1.1~aHost: ~a~aUser-Agent: nodecode~aConnection: close~a~a"
                             crlf host crlf crlf crlf crlf)
                     :external-format :latin-1)
                    stream)
    (force-output stream)
    (let ((head (make-array 8192 :element-type '(unsigned-byte 8))) (end 0))
      (loop for byte = (read-byte stream nil)
            while (and byte (< end (length head)))
            do (setf (aref head end) byte) (incf end)
            until (and (>= end 4) (equalp (subseq head (- end 4) end) #(13 10 13 10))))
      (let ((text (string-downcase (sb-ext:octets-to-string head :end end :external-format :latin-1))))
        (and (or (ppcre:scan "(?m)^server:\\s*cloudflare" text) (ppcre:scan "(?m)^cf-ray:" text)) t)))))

(defun tls-handshake-facts (host port timeout)
  "One verified handshake with HOST:PORT => TLS-PEER-FACTS plus :CLOUDFLARE."
  (sb-sys:with-deadline (:seconds timeout)
    (let* ((socket (usocket:socket-connect host port :element-type '(unsigned-byte 8) :timeout timeout))
           (stream nil))
      (unwind-protect
           (progn (setf stream (cl+ssl:make-ssl-client-stream (usocket:socket-stream socket)
                                                              :hostname host :verify :required))
                  (append (tls-peer-facts stream) (list :cloudflare (cloudflare-answers-p stream host))))
        (when stream (ignore-errors (close stream :abort t)))
        (ignore-errors (usocket:socket-close socket))))))

(defun connection-probe (url &key (timeout 8))
  "Measure the connection URL's requests take, sending nothing of anyone's => a plist: :HOST, :PROXY,
and :LOCAL, :PLAIN (no TLS), the handshake's facts, :HTTPS alone (the handshake could not be read,
the exchange went through) or :ERROR."
  (let* ((uri (ignore-errors (quri:uri url)))
         (host (and uri (quri:uri-host uri)))
         (base (list :host host :proxy (connection-proxy))))
    (cond ((null host) (list* :error "no endpoint" base))
          ((local-endpoint-p url) (list* :local t base))
          ((not (string-equal (quri:uri-scheme uri) "https")) (list* :plain t base))
          (t (handler-case (append (tls-handshake-facts host (or (quri:uri-port uri) 443) timeout) base)
               (serious-condition (condition)
                 ;; Where this build reads no handshake (WinHTTP), the exchange itself still says
                 ;; it went over HTTPS and who answered.
                 (handler-case
                     (multiple-value-bind (body status headers) (http :head url :timeout timeout)
                       (declare (ignore body))
                       (list* :https (and status t)
                              :cloudflare (and (hash-table-p headers)
                                               (or (gethash "cf-ray" headers)
                                                   (search "cloudflare" (or (gethash "server" headers) "")))
                                               t)
                              base))
                   (serious-condition () (list* :error (princ-to-string condition) base)))))))))

;;; --- the verdict ------------------------------------------------------------------

(defun connection-label (level proxy)
  (case level
    (:private "Connection secure · Private")
    (:not-private (if proxy "Proxy · Not private" "Connection secure · Not private"))
    (:unknown "Unknown · Unsecure")
    (:local "Local")
    (:plain "Not encrypted")
    (t "Connection unchecked")))

(defun connection-rows (level probe terms plan)
  "The box's checklist: (MARK LABEL VALUE), MARK :OK measured or our own, :CLAIM the provider's
word, :NO exposed or unknown, NIL a plain line."
  (let* ((own (getf terms :own))
         (tls (getf probe :tls))
         (issuer (getf probe :issuer))
         (proxy (getf probe :proxy))
         (cloudflare (getf probe :cloudflare))
         (terms-known (and terms (not plan))))
    (flet ((promise (label good value) (list (cond ((not good) :no) (own :ok) (t :claim)) label value)))
      (if (eq level :local)
          (list (list (if (or tls (member (getf probe :host) '("localhost" "127.0.0.1" "::1") :test #'string-equal))
                          :ok :no)
                      "Encrypted" (if tls "TLS" "local"))
                (list :ok "Readable by" "your machine or network")
                (list :ok "Route" "local")
                (list :ok "Linked to you" "no"))
          (list
           (cond (tls (list :ok "Encrypted" (format nil "~a~:[~; · PQC~]" (ppcre:regex-replace "^TLSv" tls "TLS ")
                                                     (ppcre:scan "(?i)mlkem|kyber" (or (getf probe :group) "")))))
                 ((getf probe :https) (list :ok "Encrypted" "HTTPS"))
                 ((getf probe :plain) (list :no "Encrypted" "no"))
                 (t (list :no "Encrypted" "unchecked")))
           (cond (proxy (list :no "Intercepted" (format nil "proxy ~a" proxy)))
                 ((getf probe :plain) (list :no "Intercepted" "possible"))
                 ((null issuer) (list (if (getf probe :https) :claim :no) "Intercepted" "unchecked"))
                 ((some (lambda (name) (search name (string-downcase issuer))) *public-certificate-issuers*)
                  (list :ok "Intercepted" "no"))
                 (t (list :claim "Intercepted" issuer)))
           (list (if (and own (not cloudflare) (not proxy)) :ok :no) "Readable by"
                 (format nil "~{~a~^ · ~}"
                         (remove nil (list (and cloudflare "Cloudflare")
                                           (if terms (getf terms :name) (getf probe :host))
                                           (and (getf terms :router) "upstream per request")))))
           (if terms
               (promise "Route" (eq t (getf terms :eu))
                        (format nil "~a~@[ · ~a~]" (getf terms :where)
                                (case (getf terms :eu) ((t) "EU") (:option "EU option"))))
               (list :no "Route" "unknown"))
           (if terms-known
               (promise "Stored" (equal "no" (getf terms :stored)) (getf terms :stored))
               (list :no "Stored" "unknown"))
           (if terms-known
               (promise "Trained on" (eq :no (getf terms :trains))
                        (case (getf terms :trains)
                          (:no "no") (:free-tier "free tier") (:drafts "draft models") (t "unknown")))
               (list :no "Trained on" "unknown"))
           (if terms-known
               (promise "ZDR" (eq :yes (getf terms :zdr))
                        (case (getf terms :zdr)
                          (:yes "yes") (:request "on request") (:enterprise "enterprise") (:no "no")
                          (t "unknown")))
               (list :no "ZDR" "unknown"))
           (list (if own :ok :no) "Linked to you" (if own "country · billing" "your account"))
           (list nil "Source" (cond ((null terms) "not on our list")
                                    (plan "this plan is not on our list")
                                    (t (format nil "~a · ~a" (getf terms :source) *provider-terms-checked*)))))))))

(defun connection-verdict (provider probe)
  "What PROBE, the connection PROVIDER's turns take, means => (:LEVEL :LABEL :HOST :NAME :ROWS):
:PRIVATE only for NODECODE's own endpoint reached directly; :NOT-PRIVATE for a provider on the list,
:UNKNOWN for one that is not; :LOCAL, :PLAIN or :UNCHECKED when the wire said so."
  (let* ((terms (provider-terms (getf probe :host)))
         (plan (and terms (not (member provider (getf terms :ids) :test #'equal))))
         (proxy (getf probe :proxy))
         (level (cond ((getf probe :local) :local)
                      ((getf probe :plain) :plain)
                      ((getf probe :error) :unchecked)
                      ((and (getf terms :own) (not proxy) (not (getf probe :cloudflare))) :private)
                      (terms :not-private)
                      (t :unknown))))
    (list :level level :label (connection-label level proxy) :host (getf probe :host)
          :name (or (getf terms :name) (getf probe :host))
          :rows (connection-rows level probe terms plan))))

;;; --- the shell: measured once a pick, the knob, the box ------------------------------

(defvar *connection-checks* (make-hash-table :test #'equal :synchronized t)
  "(PROVIDER . MODEL) => that pick's CONNECTION-VERDICT, or :CHECKING while it is measured. Live-only:
one measurement a pick a shell.")

(defun connection-key (model)
  "(PROVIDER . MODEL-ID) of the target MODEL's footer names, else NIL."
  (multiple-value-bind (raw-provider raw-model state) (footer-identity model)
    (let ((provider (json-value raw-provider :text))
          (model-id (json-value raw-model :text)))
      (and (eq state :configured) provider (cons provider model-id)))))

(defun check-connection (model)
  "Measure the connection MODEL's chosen target takes, off the loop, unless this pick has been:
once when a model is chosen, before anyone prompts it."
  (when-let (key (connection-key model))
    (unless (gethash key *connection-checks*)
      (setf (gethash key *connection-checks*) :checking)
      (off-loop model
                (lambda ()
                  (connection-verdict (car key) (connection-probe (connection-endpoint (car key) (cdr key)))))
                (lambda (model value)
                  (setf (gethash key *connection-checks*)
                        (if (off-loop-failure value)
                            (connection-verdict (car key) (list :error (off-loop-failure value)))
                            value))
                  (render-state model))))))

(defun connection-knob-segs (model)
  "The footer's knob, a link to /privacy: green for Private, light blue otherwise; NIL before
the pick is known."
  (let* ((key (connection-key model))
         (check (and key (gethash key *connection-checks*)))
         (target (cons :command "privacy")))
    (when check
      (list (if (eq check :checking)
                (hover-seg model "◌ Checking connection…" target :muted)
                (hover-seg model (format nil "● ~a" (getf check :label)) target
                           (if (eq :private (getf check :level)) :success :connection)))))))

;;; The box stacks the checklist as pills, one a fact a line, a blank line between each. A pill is
;;; two halves like the footer's account badge: what it checks on the chip grey, padded so every
;;; split lines up, then the mark and the value on the verdict's own colour.

(defun connection-fact-text (fact)
  "FACT, a checklist row (MARK LABEL VALUE), as plain words: its mark, what it checks, its value."
  (destructuring-bind (mark label value) fact
    (format nil "~a ~a ~a" (case mark (:ok "✓") (:no "✗") (t "?")) label value)))

(defun connection-pill (fact label-width room)
  "FACT, a checklist row (MARK LABEL VALUE), as one pill no wider than ROOM: what it checks padded
to LABEL-WIDTH on the chip grey, then the mark and the value on the verdict's colour; where grounds
do not paint, the same words with the mark and value in that colour."
  (destructuring-bind (mark label value) fact
    (let ((tone (case mark (:ok :success) (:no :danger) (t :tool)))
          (sign (case mark (:ok "✓") (:no "✗") (t "?")))
          (pad (make-string (max 0 (- label-width (text-display-width label))) :initial-element #\Space)))
      (clip-segs (if (grounds-shown-p)
                     (let ((chip (style-for-tone :sheet-chip)))
                       (list (make-seg :text (format nil " ~a~a " label pad) :bold t
                                       :tone (vstyle :fg (visual-style-fg chip))
                                       :ground (vstyle :bg (visual-style-bg chip)))
                             (account-chip-seg (format nil "~a ~a" sign value) tone)))
                     (list (make-seg :text (format nil "~a~a " label pad) :tone :foreground :bold t)
                           (make-seg :text (format nil "~a ~a" sign value) :tone tone :bold t)))
                 room :mark *dialog-row-overflow-mark*))))

(defun connection-dialog-rows (key check &optional (room 96))
  "The box: the pick KEY names and its verdict, then CHECK's facts as pills stacked one to a line
with a blank line between each, no wider than ROOM columns, then where the terms come from."
  (when (consp check)
    (let* ((room (max 8 (- room 4)))
           (facts (remove nil (getf check :rows) :key #'first))
           (label-width (reduce #'max facts :key (lambda (fact) (text-display-width (second fact))) :initial-value 0))
           (source (find nil (getf check :rows) :key #'first))
           (indent (make-seg :text "    " :tone :muted)))
      (flet ((pill-row (fact)
               (let ((pill (connection-pill fact label-width room))
                     (row (make-picker-row :heading t :value (list :connection))))
                 (setf (picker-row-label row) (connection-fact-text fact)
                       (picker-row-paint row) (lambda (selected room)
                                                (declare (ignore selected room))
                                                (values (cons indent pill) nil)))
                 row))
             (blank () (make-picker-row :heading t :label "" :value (list :connection))))
        (append
         (list (make-picker-row :heading t :label (format nil "~@[~a · ~]~a" (cdr key) (getf check :name))
                                :mark "■" :mark-tone :accent :value (list :connection))
               (make-picker-row :heading t :label (getf check :label) :mark "●" :value (list :connection)
                                :mark-tone (if (eq :private (getf check :level)) :success :connection))
               (blank))
         (loop for (fact . more) on facts
               collect (pill-row fact)
               when more collect (blank))
         (when source
           (list (blank)
                 (make-picker-row :heading t :value (list :connection) :mark " "
                                  :label (format nil "~a ~a" (second source) (third source))))))))))

(defun slash-privacy-op (model)
  "Open the box the footer's knob opens: what the check measured for this pick and what the
provider's terms say."
  (let* ((key (connection-key model))
         (check (and key (gethash key *connection-checks*))))
    (open-picker-dialog model "Connection"
                        (connection-dialog-rows key check
                                                (- (docked-panel-room (chat-model-term-width model) t) 2))
                        (constantly nil)
                        :kind :privacy
                        :empty-label (if (eq check :checking) "Checking connection…" "No model chosen yet")
                        :hint "esc close")
    nil))
