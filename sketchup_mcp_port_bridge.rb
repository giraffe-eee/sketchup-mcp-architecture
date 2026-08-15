# frozen_string_literal: true

# Codex SketchUp MCP Bridge extension loader.
#
# Keeping registration in this top-level file lets SketchUp's Extension
# Manager identify, enable, disable, and report the bridge correctly. The
# implementation lives in codex_sketchup_mcp/main.rb.

require 'sketchup'
require 'extensions'
require File.join(File.dirname(__FILE__), 'codex_sketchup_mcp', 'version')

module CodexSketchupMcpExtension
  EXTENSION_ID = 'codex_sketchup_mcp'.freeze
  EXTENSION_NAME = 'Codex SketchUp MCP Bridge'.freeze
  EXTENSION_PATH = File.join(EXTENSION_ID, 'main').freeze

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, EXTENSION_PATH)
    extension.description = 'Local bridge that lets Codex create and inspect SketchUp architectural models.'
    extension.version = CodexSketchupMcp::PLUGIN_VERSION
    extension.creator = 'Codex Local'
    extension.copyright = 'Copyright 2026'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
