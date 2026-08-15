# frozen_string_literal: true

require 'json'

module CodexSketchupMcpRuntime
  CONFIG_FILE = File.join(File.dirname(__FILE__), 'runtime_config.json').freeze
  FALLBACK_RUNTIME_DIR = File.join(Dir.home, '.codex-sketchup-mcp').freeze

  def self.settings
    return @settings if defined?(@settings)

    @settings = JSON.parse(File.read(CONFIG_FILE, encoding: 'UTF-8'))
    @settings = {} unless @settings.is_a?(Hash)
    @settings
  rescue StandardError
    @settings = {}
  end

  def self.runtime_dir
    configured = settings.fetch('runtime_dir', '').to_s.strip
    configured.empty? ? FALLBACK_RUNTIME_DIR : configured
  end

  def self.file_bridge_dir(runtime_dir)
    configured = settings.fetch('file_bridge_dir', '').to_s.strip
    configured.empty? ? File.join(runtime_dir, 'file-queue') : configured
  end
end
