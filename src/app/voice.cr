require "log"
require "file_utils"
require "set"

module Kirk
  # Coordinates voice commands. SAPI (via the shim) recognizes phrases from a
  # generated SRGS grammar; recognized phrases map to actions by substring
  # match. Pipeline per event: confidence check -> cooldown check -> action.
  class Voice
    enum Action
      Clip
      Record
      Screenshot
      None
    end

    getter session : VoiceSession?
    getter enabled : Bool

    @grammar_path : String
    @last_fire_ms : Int64 = 0
    @cooldown_ms : Int32
    @confidence_min : Float64

    def initialize(persist_dir : String, enabled : Bool)
      @enabled = enabled
      @cooldown_ms = 2500
      @confidence_min = 0.01
      @grammar_path = File.join(persist_dir, "voice.srgs")
      @session = nil
    end

    def apply_settings(cfg : Kirk::Settings)
      @cooldown_ms = cfg.voice_cooldown_ms
      @confidence_min = cfg.voice_confidence
      @enabled = cfg.voice_enabled
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

    def listening? : Bool
      @enabled && !@session.nil?
    end

    def build_grammar(phrases : Array(String))
      # "Kirk, clip that!" and "Kirk clip that" are the same token sequence to SAPI.
      seen = Set(String).new
      items = phrases.compact_map do |p|
        g = Voice.grammar_text(p)
        next nil if g.empty? || seen.includes?(g.downcase)
        seen << g.downcase
        "      <item>#{xml_escape(g)}</item>"
      end.join("\n")
      xml = <<-SRGS
      <?xml version="1.0" encoding="UTF-8"?>
      <grammar version="1.0" xml:lang="en-US" root="Commands" xmlns="http://www.w3.org/2001/06/grammar">
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
    def start(persist_dir : String, phrases : Array(String), device_hint : String? = nil)
      if !@enabled
        Log.info { "voice: not starting (voice commands OFF)" }
        return
      end
      if phrases.empty?
        Log.warn { "voice: not starting (no phrases configured)" }
        return
      end

      FileUtils.mkdir_p(persist_dir)
      @grammar_path = File.join(persist_dir, "voice.srgs")
      path = build_grammar(phrases)
      Log.info { "voice: starting (#{phrases.size} phrases, conf_min=#{@confidence_min}, cooldown=#{@cooldown_ms}ms, grammar=#{path}, mic_hint=#{device_hint.inspect})" }
      phrases.each { |p| Log.debug { "voice: phrase '#{p}' -> grammar '#{Voice.grammar_text(p)}'" } }

      session = win32_voice_create(device_hint)
      unless session.valid?
        Log.error { "voice: could not create SAPI session (listening INACTIVE, hr=0x#{win32_voice_last_hresult.to_u32!.to_s(16)})" }
        @session = nil
        return
      end
      Log.info { "voice: audio input bound to '#{session.input_name}'" }
      unless session.load_grammar(path)
        Log.error { "voice: grammar load FAILED for #{path} (listening INACTIVE, hr=0x#{win32_voice_last_hresult.to_u32!.to_s(16)})" }
        win32_voice_destroy(session)
        @session = nil
        return
      end
      Log.info { "voice: grammar loaded (#{phrases.size} phrases)" }
      unless session.start
        Log.error { "voice: recognizer start FAILED (listening INACTIVE, hr=0x#{win32_voice_last_hresult.to_u32!.to_s(16)})" }
        win32_voice_destroy(session)
        @session = nil
        return
      end
      @session = session
      Log.info { "voice: listening ACTIVE on '#{session.input_name}'" }
    end

    def stop
      session = @session
      return unless session
      Log.info { "voice: stopping (listening INACTIVE)" }
      session.stop
      win32_voice_destroy(session)
      @session = nil
    end

    # Low-confidence hypotheses log at INFO so a too-strict threshold is
    # visible in the default local log instead of failing silently.
    def poll : Action
      return Action::None unless @enabled
      session = @session
      return Action::None unless session

      result = session.poll
      return Action::None unless result

      phrase, confidence = result
      if confidence < @confidence_min
        Log.info { "voice: heard '#{phrase}' conf=#{confidence.round(3)} below threshold #{@confidence_min} (no action)" }
        return Action::None
      end
      Log.debug { "voice: '#{phrase}' conf=#{confidence.round(3)}" }

      now = Time.monotonic.total_milliseconds.to_i64
      if now - @last_fire_ms < @cooldown_ms
        Log.debug { "voice: ignored (cooldown)" }
        return Action::None
      end

      @last_fire_ms = now
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
