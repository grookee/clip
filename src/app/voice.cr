require "log"
require "file_utils"
require "set"

module Kirk
  # Coordinates voice commands. SAPI (via the shim) recognizes phrases from a
  # generated SRGS grammar; recognized phrases map to actions by substring
  # match. Pipeline per event: confidence floor -> strict phrase match ->
  # chatter-burst gate -> cooldown -> action.
  #
  # Why the burst gate: the grammar constrains SAPI so ANY speech (e.g.
  # chatting on Discord) is force-mapped onto the closest command phrase at
  # low confidence. The confidence floor alone cannot separate deliberate
  # commands from conversation, because both decode in the same low range.
  # Continuous conversation surfaces dense bursts of candidates, while a
  # deliberate command is isolated, so contenders arriving inside
  # isolation_ms of a previous contender need high confidence to fire.
  class Voice
    enum Action
      Clip
      Record
      Screenshot
      None
    end

    # Outcome of the post-processing pipeline, for logging/tuning.
    enum Decision
      Fire
      BelowFloor
      NoPhraseMatch
      BurstSuppressed
      CoolingDown
    end

    getter session : VoiceSession?
    getter enabled : Bool

    @grammar_path : String
    @last_fire : Time::Instant? = nil
    @last_contender_at : Time::Instant? = nil
    @cooldown_ms : Int32
    @confidence_min : Float64
    @isolation_ms : Int32
    @high_confidence : Float64
    @phrases_normalized : Set(String) = Set(String).new

    def initialize(persist_dir : String, enabled : Bool)
      @enabled = enabled
      @cooldown_ms = 2500
      @confidence_min = 0.01
      @isolation_ms = 1200
      @high_confidence = 0.5
      @grammar_path = File.join(persist_dir, "voice.srgs")
      @session = nil
    end

    getter voice_language : String = "auto"

    def apply_settings(cfg : Kirk::Settings)
      @cooldown_ms = cfg.voice_cooldown_ms
      @confidence_min = cfg.voice_confidence
      @isolation_ms = cfg.voice_isolation_ms
      @high_confidence = cfg.voice_high_confidence
      @enabled = cfg.voice_enabled
      @voice_language = Voice.normalize_lang(cfg.voice_language)
    end

    # Normalizes the voice_language setting: "auto" (default) follows the
    # default SAPI recognizer; otherwise a BCP-47 tag such as "en-US".
    # Underscores are accepted ("en_US"); empty/invalid falls back to "auto".
    def self.normalize_lang(raw : String) : String
      s = raw.strip.gsub("_", "-")
      return "auto" if s.empty? || s.downcase == "auto"
      parts = s.split("-")
      return "auto" unless parts[0].size == 2 && parts[0].chars.all?(&.letter?)
      lang = parts[0].downcase
      if parts.size == 1
        return lang == "en" ? "en-US" : lang
      end
      return "auto" unless parts[1].size == 2 && parts[1].chars.all?(&.letter?)
      "#{lang}-#{parts[1].upcase}"
    end

    # LANGID (from SAPI's Language attribute, e.g. 0x409) -> BCP-47 grammar
    # language. Used as a fallback when the native tag query is unavailable;
    # the live path takes the tag straight from the selected recognizer.
    def self.bcp47_for_langid(langid : UInt32) : String
      case langid & 0xFFFF
      when 0x0409 then "en-US"
      when 0x0809 then "en-GB"
      when 0x0C09 then "en-AU"
      when 0x1009 then "en-CA"
      when 0x1409 then "en-NZ"
      when 0x1809 then "en-IE"
      when 0x1C09 then "en-ZA"
      when 0x0407 then "de-DE"
      when 0x040C then "fr-FR"
      when 0x040A then "es-ES"
      when 0x080A then "es-MX"
      when 0x0410 then "it-IT"
      when 0x0411 then "ja-JP"
      when 0x0412 then "ko-KR"
      when 0x0804 then "zh-CN"
      when 0x0404 then "zh-TW"
      when 0x0416 then "pt-BR"
      when 0x0816 then "pt-PT"
      when 0x0413 then "nl-NL"
      when 0x041D then "sv-SE"
      when 0x0415 then "pl-PL"
      when 0x0419 then "ru-RU"
      else
        case langid & 0x3FF
        when 0x09 then "en-US"
        when 0x07 then "de-DE"
        when 0x0C then "fr-FR"
        when 0x0A then "es-ES"
        when 0x10 then "it-IT"
        when 0x11 then "ja-JP"
        when 0x12 then "ko-KR"
        when 0x04 then "zh-CN"
        when 0x16 then "pt-BR"
        when 0x13 then "nl-NL"
        when 0x1D then "sv-SE"
        when 0x15 then "pl-PL"
        when 0x19 then "ru-RU"
        else          "en-US"
        end
      end
    end

    def self.hresult_name(hr : UInt32) : String
      case hr
      when 0x80045052_u32 then "SPERR_LANGID_MISMATCH"
      when 0x8004503A_u32 then "SPERR_NOT_FOUND"
      when 0x80004003_u32 then "E_POINTER"
      when 0x80070005_u32 then "E_ACCESSDENIED"
      else                     "unknown"
      end
    end

    # ";"-separated: "," fragments "Kirk, clip that!" into unmatchable pieces,
    # so recognition silently never fires. A legacy comma-joined value is kept
    # whole (or migrated when it matches the old default).
    LEGACY_DEFAULT = "kirk, clip that!,kirk clip that,kirk, clip it,hey kirk, clip that!"

    def self.parse_phrases(raw : String) : Array(String)
      if raw.includes?(";") || raw.includes?("\n")
        return raw.split(/;|\n/).map(&.strip).reject(&.empty?)
      end
      if raw.strip.downcase == LEGACY_DEFAULT
        Log.info { "voice: migrating legacy comma-separated voice_command to ';'-separated default" }
        return ["Kirk, clip that!", "Kirk clip that", "Kirk, clip it!", "Hey Kirk, clip that!", "Clip that, Kirk!"]
      end
      s = raw.strip
      s.empty? ? [] of String : [s]
    end

    # SAPI tokenizes punctuation inside a grammar <item> into separate
    # low-confidence tokens, dragging the averaged confidence below threshold
    # even for a perfect utterance. Strip it for the grammar.
    def self.grammar_text(phrase : String) : String
      cleaned = phrase.gsub(/[,!?.;:]/, " ").gsub(/\s+/, " ").strip
      cleaned.empty? ? phrase.strip : cleaned
    end

    # Canonical form for comparing a recognition against the configured
    # phrases: case-insensitive, punctuation/whitespace-insensitive.
    def self.normalize(phrase : String) : String
      grammar_text(phrase).downcase
    end

    def listening? : Bool
      @enabled && !@session.nil?
    end

    def build_grammar(phrases : Array(String), lang : String = "en-US")
      # "Kirk, clip that!" and "Kirk clip that" are the same token sequence to SAPI.
      seen = Set(String).new
      items = phrases.compact_map do |p|
        g = Voice.grammar_text(p)
        next nil if g.empty? || seen.includes?(g.downcase)
        seen << g.downcase
        "      <item>#{xml_escape(g)}</item>"
      end.join("\n")
      # The grammar language MUST match the selected SAPI recognizer's
      # language, or LoadCmdFromFile fails with SPERR_LANGID_MISMATCH
      # (0x80045052) - e.g. default recognizer en-GB (809) vs en-US grammar.
      grammar_lang = Voice.normalize_lang(lang)
      grammar_lang = "en-US" if grammar_lang == "auto"
      xml = <<-SRGS
      <?xml version="1.0" encoding="UTF-8"?>
      <grammar version="1.0" xml:lang="#{xml_escape(grammar_lang)}" root="Commands" xmlns="http://www.w3.org/2001/06/grammar">
        <rule id="Commands" scope="public">
          <one-of>
        #{items}
          </one-of>
        </rule>
      </grammar>
      SRGS
      File.write(@grammar_path, xml)
      @grammar_path
    end

    private def xml_escape(s : String) : String
      s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    # Idempotent. device_hint is matched against SAPI input descriptions, else
    # the SAPI default input is used. capture_audio only controls the ffmpeg
    # dshow mic baked into recordings.
    # The SRGS grammar language always follows the actually-selected SAPI
    # recognizer (queried after create), so a non-US default (e.g. en-GB 809
    # or de-DE) no longer fails with SPERR_LANGID_MISMATCH (0x80045052).
    def start(persist_dir : String, phrases : Array(String), device_hint : String? = nil, lang_hint : String? = nil)
      if !@enabled
        Log.info { "voice: not starting (voice commands OFF)" }
        return
      end
      if phrases.empty?
        Log.warn { "voice: not starting (no phrases configured)" }
        return
      end

      want_lang = Voice.normalize_lang(lang_hint || @voice_language)
      FileUtils.mkdir_p(persist_dir)
      @grammar_path = File.join(persist_dir, "voice.srgs")
      @phrases_normalized = Set(String).new(phrases.map { |p| Voice.normalize(p) }.reject(&.empty?))
      if @confidence_min > 0.2
        Log.warn { "voice: confidence floor #{@confidence_min} is very strict on the SAPI scale (clear commands decode around 0.02-0.05); commands may never fire - lower it in Settings > Voice commands" }
      end

      session = win32_voice_create(device_hint, want_lang)
      unless session.valid?
        hr = win32_voice_last_hresult.to_u32!
        Log.error { "voice: could not create SAPI session (listening INACTIVE, hr=0x#{hr.to_s(16)} (#{Voice.hresult_name(hr)})). Check: Windows Speech Recognition / speech pack installed, Settings > Privacy > Microphone allowed, and a SAPI input exists (see README voice troubleshooting)." }
        win32_voice_destroy(session)
        @session = nil
        return
      end
      reco_tag, reco_langid, reco_id = begin
        {session.recognizer_tag, session.recognizer_langid, session.recognizer_id}
      rescue
        {"en-US", 0_u32, ""}
      end
      reco_tag = "en-US" if reco_tag.strip.empty?
      # An explicit request that matches nothing stays on the default
      # recognizer; the grammar still follows the actual recognizer.
      if want_lang != "auto" && want_lang.downcase != reco_tag.downcase
        Log.warn { "voice: requested language #{want_lang} unavailable (recognizer #{reco_id} is #{reco_tag}); grammar follows the recognizer - set voice_language to \"auto\" or install the #{want_lang} speech pack" }
      end
      path = build_grammar(phrases, reco_tag)
      Log.info { "voice: starting (#{phrases.size} phrases, conf_min=#{@confidence_min}, high=#{@high_confidence}, cooldown=#{@cooldown_ms}ms, isolation=#{@isolation_ms}ms, grammar=#{path}, grammar_lang=#{reco_tag}, recognizer=#{reco_id} lang=#{reco_tag} (0x#{reco_langid.to_s(16)}), mic_hint=#{device_hint.inspect})" }
      phrases.each { |p| Log.debug { "voice: phrase '#{p}' -> grammar '#{Voice.grammar_text(p)}'" } }
      Log.info { "voice: audio input bound to '#{session.input_name}'" }
      unless session.load_grammar(path)
        detail = begin
          "exists=#{File.exists?(path)} size=#{File.exists?(path) ? File.size(path) : -1}"
        rescue
          "exists=? size=?"
        end
        hr = win32_voice_last_hresult.to_u32!
        name = Voice.hresult_name(hr)
        hint = hr == 0x80045052_u32 ? "grammar language must match the SAPI recognizer (grammar_lang=#{reco_tag} recognizer=#{reco_id}); try voice_language \"auto\" or install the matching speech pack" : "see README voice troubleshooting"
        Log.error { "voice: grammar load FAILED for #{path} (#{detail}, grammar_lang=#{reco_tag}, recognizer=#{reco_id}, listening INACTIVE, hr=0x#{hr.to_s(16)} (#{name}); #{hint})" }
        win32_voice_destroy(session)
        @session = nil
        return
      end
      Log.info { "voice: grammar loaded (#{phrases.size} phrases, lang=#{reco_tag})" }
      unless session.start
        hr = win32_voice_last_hresult.to_u32!
        Log.error { "voice: recognizer start FAILED (listening INACTIVE, hr=0x#{hr.to_s(16)} (#{Voice.hresult_name(hr)}))" }
        win32_voice_destroy(session)
        @session = nil
        return
      end
      @session = session
      Log.info { "voice: listening ACTIVE on '#{session.input_name}' (recognizer #{reco_tag})" }
    end

    def stop
      session = @session
      return unless session
      Log.info { "voice: stopping (listening INACTIVE)" }
      session.stop
      win32_voice_destroy(session)
      @session = nil
    end

    # Pure gate decision (no clock reads inside): `now` is injected so the
    # burst/cooldown logic is unit-testable without a SAPI session.
    # @last_contender_at tracks the previous contender (floor-passing,
    # phrase-matching candidate), updated by poll() - not here.
    def decide(phrase : String, confidence : Float64, now : Time::Instant) : Decision
      Voice.gate(
        phrase, confidence, @phrases_normalized,
        @confidence_min, @high_confidence, @isolation_ms, @cooldown_ms,
        @last_contender_at, @last_fire, now)
    end

    # Stateless core of decide(): all inputs explicit, so tests can drive
    # burst/cooldown scenarios with synthetic timestamps.
    def self.gate(phrase : String, confidence : Float64, phrases : Set(String),
                  floor : Float64, high_confidence : Float64, isolation_ms : Int32,
                  cooldown_ms : Int32,
                  last_contender_at : Time::Instant?, last_fire : Time::Instant?,
                  now : Time::Instant) : Decision
      return Decision::BelowFloor if confidence < floor
      return Decision::NoPhraseMatch unless phrases.includes?(Voice.normalize(phrase))
      high = Math.max(high_confidence, floor)
      if last = last_contender_at
        if (now - last).total_milliseconds < isolation_ms && confidence < high
          return Decision::BurstSuppressed
        end
      end
      if last = last_fire
        if (now - last).total_milliseconds < cooldown_ms
          return Decision::CoolingDown
        end
      end
      Decision::Fire
    end

    # Every surfaced recognition is logged at INFO with its confidence and
    # the gate outcome, so a too-strict (or too-loose) threshold is tunable
    # from the default local log instead of failing silently.
    def poll : Action
      return Action::None unless @enabled
      session = @session
      return Action::None unless session

      result = session.poll
      return Action::None unless result

      phrase, confidence = result
      now = Time.instant
      case decide(phrase, confidence, now)
      when Decision::BelowFloor
        Log.info { "voice: heard '#{phrase}' conf=#{confidence.round(3)} below floor #{@confidence_min} (no action)" }
        return Action::None
      when Decision::NoPhraseMatch
        Log.info { "voice: heard '#{phrase}' conf=#{confidence.round(3)} matches no configured phrase (no action)" }
        return Action::None
      when Decision::BurstSuppressed
        @last_contender_at = now
        Log.info { "voice: heard '#{phrase}' conf=#{confidence.round(3)} suppressed: chatter burst (pause ~#{@isolation_ms}ms before commands, or raise confidence above #{@high_confidence})" }
        return Action::None
      when Decision::CoolingDown
        @last_contender_at = now
        Log.debug { "voice: ignored (cooldown)" }
        return Action::None
      end

      @last_contender_at = now
      @last_fire = now
      Log.info { "voice: accepted '#{phrase}' conf=#{confidence.round(3)}" }
      match_action(phrase)
    end

    private def match_action(phrase : String) : Action
      p = phrase.downcase
      return Action::Screenshot if p.includes?("screenshot") || p.includes?("picture") || p.includes?("capture screen")
      return Action::Record if p.includes?("record") || p.includes?("start recording")
      return Action::Clip if p.includes?("clip")
      Action::None
    end
  end
end
