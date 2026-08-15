# frozen_string_literal: true

# This entry point deliberately captures boot errors. SketchUp's extension
# manager only reports a generic load failure, whereas this file writes the
# original Ruby exception and line number to the local bridge log.
require 'fileutils'
require 'time'
require File.join(File.dirname(__FILE__), 'version')

module CodexSketchupMcpBootstrap
  DEFAULT_RUNTIME_DIR = 'D:/project/sketchup-mcp-architecture/.runtime'.freeze
  LOG_DIR = File.expand_path(
    ENV.fetch('SKETCHUP_MCP_RUNTIME_DIR', DEFAULT_RUNTIME_DIR)
  ).freeze
  LOG_FILE = File.join(LOG_DIR, 'bridge_boot.log').freeze

  def self.log(message)
    FileUtils.mkdir_p(LOG_DIR)
    File.open(LOG_FILE, 'a:UTF-8') { |file| file.puts("[#{Time.now.utc.iso8601}] #{message}") }
  rescue StandardError
    nil
  end
end

begin
  CodexSketchupMcpBootstrap.log('Loading core bridge implementation')
  Sketchup.require('codex_sketchup_mcp/core')
  CodexSketchupMcpBootstrap.log('Core bridge implementation loaded')
rescue StandardError => error # SketchUp must remain usable if a local bridge update fails.
  CodexSketchupMcpBootstrap.log("BOOT ERROR: #{error.class}: #{error.message}")
  CodexSketchupMcpBootstrap.log(error.backtrace.join("\n")) if error.backtrace
end
