class GoogleTranslateDiff::Request
  extend Dry::Initializer::Mixin

  param :from
  param :to
  param :values
  param :options

  def call
    unless GoogleTranslateDiff.api
      raise "Assign GoogleTranslateDiff.api before calling ::translate"
    end

    unless GoogleTranslateDiff.cache_store
      raise "Assign GoogleTranslateDiff.cache_store before calling ::translate"
    end

    return values if from == to || values.empty?

    puts "TEXTS:                  #{texts.inspect}"
    puts "TOKENS:                 #{tokens.inspect}"
    puts "TEXT_TOKENS:            #{text_tokens.inspect}"
    puts "TEXT_TOKENS DATA:       #{text_tokens_texts.inspect}"
    puts "CHUNKS:                 #{chunks.inspect}"
    puts "TRANSLATED CHUNKS:      #{chunks_translated.inspect}"
    puts "TEXT_TOKENS_TRANSLATED: #{text_tokens_translated.inspect}"
    puts "TOKENS_TRANSLATED:      #{tokens_translated.inspect}"
    puts "TEXTS_TRANSLATED:       #{texts_translated.inspect}"

    translation
  end

  private

  # Extracts flat text array
  # => "Name", "<b>Good</b> boy"
  #
  # #values might be something like { name: "Name", bio: "<b>Good</b> boy" }
  def texts
    @texts ||= GoogleTranslateDiff::Linearizer.linearize(values)
  end

  # Converts each array item to token list
  # => [..., [["<b>", :markup], ["Good", :text], ...]]
  def tokens
    @tokens ||= texts.map do |value|
      GoogleTranslateDiff::Tokenizer.tokenize(value)
    end
  end

  # Extracts text tokens from token list
  # => { ..., "1_1" => "Good", 1_3 => "Boy", ... }
  def text_tokens
    @text_tokens ||= extract_text_tokens.to_h
  end

  def extract_text_tokens
    tokens.each_with_object([]).with_index do |(group, result), group_index|
      group.each_with_index do |(value, type), index|
        result << ["#{group_index}_#{index}", value] if type == :text
      end
    end
  end

  # Extracts values from text tokens
  # => [ ..., "Good", "Boy", ... ]
  def text_tokens_texts
    @text_tokens_texts ||=
      GoogleTranslateDiff::Linearizer.linearize(text_tokens)
  end

  # Splits things requires translations to per-request chunks
  # (groups less 2k sym)
  # => [[ ..., "Good", "Boy", ... ]]
  def chunks
    @chunks ||= GoogleTranslateDiff::Chunker.new(text_tokens_texts).call
  end

  # Translates/loads from cache values from each chunk
  # => [[ ..., "Horoshiy", "Malchik", ... ]]
  def chunks_translated
    @chunks_translated ||= chunks.map do |chunk|
      cached, missing = cache.cached_and_missing(chunk)
      if missing.empty?
        cached
      else
        cache.store(chunk, cached, call_api(missing))
      end
    end
  end

  # Restores indexes for translated tokens
  # => { ..., "1_1" => "Horoshiy", 1_3 => "Malchik", ... }
  def text_tokens_translated
    @text_tokens_texts_translated ||=
      GoogleTranslateDiff::Linearizer.restore(
        text_tokens,
        chunks_translated.flatten
      )
  end

  # Restores tokens translated
  # => [[..., [ "Horoshiy", :text ], ...]]
  def tokens_translated
    @tokens_translated ||= tokens.dup.tap do |tokens|
      text_tokens_translated.each do |index, value|
        group_index, index = index.split("_")
        tokens[group_index.to_i][index.to_i] = [value, :text]
      end
    end
  end

  # Restores texts from tokens
  # [..., "<b>Horoshiy</b> Malchik", ...]
  def texts_translated
    @texts_translated ||= tokens_translated.map do |group|
      group.map(&:first).join
    end
  end

  # Final result
  def translation
    @translation ||=
      GoogleTranslateDiff::Linearizer.restore(
        values, texts_translated
      )
  end

  def call_api(values)
    [GoogleTranslateDiff.api.translate(*values, **options)].flatten.map(&:text)
  end

  def cache
    @cache ||= GoogleTranslateDiff::Cache.new(from, to)
  end

  # -----

  class Error < StandardError; end
  class RateLimitExceeded < Error; end

  RATELIMIT = 8000

  private

  def check_rate_limit(texts)
    size = texts.map(&:size).sum

    raise RateLimitExceeded if rate_limit.count + size >= RATELIMIT

    rate_limit.add size
  end

  def rate_limit
    @rate_limit ||= Redis::Ratelimit.new(
      "translator", interval: 100, bucket_count: 10, bucket_size: 15
    )
  end
end