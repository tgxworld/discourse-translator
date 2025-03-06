# frozen_string_literal: true

module Jobs
  class AutomaticTranslationBackfill < ::Jobs::Scheduled
    every 5.minutes

    BACKFILL_LOCK_KEY = "discourse_translator_backfill_lock"

    def execute(args = nil)
      return unless SiteSetting.translator_enabled
      return unless should_backfill?
      return unless secure_backfill_lock

      begin
        process_batch
      ensure
        Discourse.redis.del(BACKFILL_LOCK_KEY)
      end
    end

    def fetch_untranslated_model_ids(model, content_column, limit, target_locale)
      m = model.name.downcase
      DB.query_single(<<~SQL, target_locale: target_locale, limit: limit)
        SELECT m.id
        FROM #{model.table_name} m
        WHERE m.deleted_at IS NULL
          AND m.#{content_column} != ''
          AND m.user_id > 0
          AND (
            NOT EXISTS (
              SELECT 1
              FROM discourse_translator_#{m}_locales
              WHERE #{m}_id = m.id
            )
            OR EXISTS (
              SELECT 1
              FROM discourse_translator_#{m}_locales
              WHERE #{m}_id = m.id
              AND detected_locale != :target_locale
            )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM discourse_translator_#{m}_translations
            WHERE #{m}_id = m.id
            AND locale = :target_locale
          )
        ORDER BY m.updated_at DESC
        LIMIT :limit
      SQL
    end

    private

    def should_backfill?
      return false if SiteSetting.automatic_translation_target_languages.blank?
      return false if SiteSetting.automatic_translation_backfill_maximum_translations_per_hour == 0
      true
    end

    def secure_backfill_lock
      Discourse.redis.set(BACKFILL_LOCK_KEY, "1", ex: 5.minutes.to_i, nx: true)
    end

    def translations_per_run
      [(SiteSetting.automatic_translation_backfill_maximum_translations_per_hour / 12), 1].max
    end

    def backfill_locales
      @backfill_locales ||=
        SiteSetting.automatic_translation_target_languages.split("|").map { |l| l.gsub("_", "-") }
    end

    def translator
      @translator_klass ||= "DiscourseTranslator::#{SiteSetting.translator_provider}".constantize
    end

    def translate_records(type, record_ids, target_locale)
      record_ids.each do |id|
        record = type.find(id)
        begin
          translator.translate(record, target_locale.to_sym)
        rescue => e
          # continue with other locales even if one fails
          Rails.logger.warn(
            "Failed to machine-translate #{type.name}##{id} to #{target_locale}: #{e.message}\n#{e.backtrace.join("\n")}",
          )
          next
        end
      end
    end

    def process_batch
      models_translated = [Post, Topic].size
      avg_translations_per_model_per_language = [
        translations_per_run / models_translated / backfill_locales.size,
        1,
      ].max

      records_to_translate = avg_translations_per_model_per_language
      backfill_locales.each_with_index do |target_locale, i|
        topic_ids =
          fetch_untranslated_model_ids(Topic, "title", records_to_translate, target_locale)
        post_ids = fetch_untranslated_model_ids(Post, "cooked", records_to_translate, target_locale)

        # if we end up translating fewer records than records_to_translate,
        # add to the value so that the next locales can have more quota
        records_to_translate =
          avg_translations_per_model_per_language +
            ((records_to_translate - topic_ids.size - post_ids.size) / backfill_locales.size - i)
        next if topic_ids.empty? && post_ids.empty?

        DiscourseTranslator::VerboseLogger.log(
          "Translating #{topic_ids.size} topics and #{post_ids.size} posts to #{backfill_locales.join(", ")}",
        )

        translate_records(Topic, topic_ids, target_locale)
        translate_records(Post, post_ids, target_locale)
      end
    end
  end
end
