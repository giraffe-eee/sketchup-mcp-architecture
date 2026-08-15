# frozen_string_literal: true

require 'json'
require 'time'
require 'socket'
require 'thread'
require 'fileutils'
require 'securerandom'
require 'sketchup'
require File.join(File.dirname(__FILE__), 'version')

module CodexSketchupMcpPortBridge
  extend self

  HOST = '127.0.0.1'
  PORT = 17654
  MAX_BODY_BYTES = 1024 * 1024
  MAX_HEADER_LINES = 64
  MAX_HEADER_LINE_BYTES = 16 * 1024
  MAX_CLIENT_THREADS = 16
  MAX_QUEUE_DEPTH = 200
  JOB_TIMEOUT_SECONDS = 30.0
  COMPLETED_REQUEST_CACHE_SIZE = 256
  FILE_RESPONSE_CACHE_SIZE = 5_000
  FILE_QUEUE_DEFAULT_ENABLED = true
  DEFAULT_RUNTIME_DIR = begin
    local_app_data = ENV.fetch('LOCALAPPDATA', '').strip
    local_app_data.empty? ? File.join(Dir.home, '.codex-sketchup-mcp') : File.join(local_app_data, 'CodexSketchupMcp')
  end.freeze
  RUNTIME_DIR = File.expand_path(
    ENV.fetch('SKETCHUP_MCP_RUNTIME_DIR', DEFAULT_RUNTIME_DIR)
  ).freeze
  LOG_FILE = File.join(RUNTIME_DIR, 'bridge.log').freeze
  FILE_BRIDGE_DIR = File.expand_path(ENV.fetch('SKETCHUP_MCP_FILE_BRIDGE_DIR', File.join(RUNTIME_DIR, 'file-queue'))).freeze
  COMMANDS_FILE = File.join(FILE_BRIDGE_DIR, 'commands.jsonl')
  RESPONSES_FILE = File.join(FILE_BRIDGE_DIR, 'responses.jsonl')
  ACTION_CATALOG_PATH = File.join(File.dirname(__FILE__), 'action_catalog.json').freeze
  ACTION_CATALOG_DOCUMENT = JSON.parse(File.read(ACTION_CATALOG_PATH)).freeze
  ACTION_CATALOG = ACTION_CATALOG_DOCUMENT.fetch('actions').freeze
  MUTATING_ACTIONS = ACTION_CATALOG.select { |_action, spec| spec['mutating'] }.keys.freeze
  READ_ONLY_ACTIONS = ACTION_CATALOG.reject { |_action, spec| spec['mutating'] }.keys.freeze
  ENTITY_IDENTIFIER_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/
  MAX_ABSOLUTE_MM = 1_000_000.0
  MIN_GLAZING_CLEAR_MM = 50.0

  class JobTimeout < StandardError; end

  def log(message)
    FileUtils.mkdir_p(RUNTIME_DIR)
    File.open(LOG_FILE, 'a:UTF-8') do |file|
      file.puts("[#{Time.now.utc.iso8601}] #{message}")
    end
    puts "[CodexSketchupMcpPortBridge] #{message}"
  rescue StandardError
    puts "[CodexSketchupMcpPortBridge] #{message}"
  end

  def start
    stop if @running || @server
    FileUtils.mkdir_p(RUNTIME_DIR)
    @jobs = Queue.new
    @request_mutex = Mutex.new
    @pending_requests = {}
    @completed_requests = {}
    @client_mutex = Mutex.new
    @active_clients = 0
    @last_ui_drain_at = monotonic_time
    prepare_file_queue if file_queue_enabled?
    log("File queue enabled at #{FILE_BRIDGE_DIR}") if file_queue_enabled?
    @running = true
    @server = TCPServer.new(HOST, PORT)
    @server_thread = Thread.new { accept_loop }
    @timer = UI.start_timer(0.05, true) { drain_jobs; drain_file_jobs }
    log("Listening on http://#{HOST}:#{PORT}")
  rescue Errno::EADDRINUSE
    @running = false
    log("Port #{PORT} is already in use")
    raise
  rescue StandardError => e
    @running = false
    log("Start failed: #{e.class}: #{e.message}")
    log(e.backtrace.first(8).join("\n")) if e.backtrace
    raise
  end

  def stop
    return unless @running || @server || @server_thread

    @running = false
    UI.stop_timer(@timer) if defined?(@timer) && @timer
    @timer = nil
    server = @server
    server&.close
    @server = nil
    thread = @server_thread
    @server_thread = nil
    thread.join(0.5) if thread&.alive?
    thread.kill if thread&.alive?
    log('Stopped')
  rescue IOError, SystemCallError
    nil
  end

  def accept_loop
    log('Accept loop started')
    while @running
      client = @server.accept
      log('Accepted client connection')
      unless acquire_client_slot
        write_json(client, 503, { ok: false, error: 'Bridge is busy; retry shortly' })
        client.close unless client.closed?
        next
      end

      # SketchUp's embedded Ruby may accept a socket on a background thread
      # but never schedule a second Ruby thread. Process one client inline so
      # health checks and command responses remain reliable in that runtime.
      begin
        log('Handling client inline')
        handle_client(client)
      ensure
        release_client_slot
      end
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => e
    log("Server error: #{e.class}: #{e.message}")
  end

  def handle_client(socket)
    log('Reading client request')
    request = read_request(socket)
    log("Parsed client request: #{request[:method]} #{request[:path]}")

    if request[:method] == 'GET' && request[:path] == '/health'
      return write_json(socket, 200, {
        ok: true,
        service: 'codex-sketchup-mcp-port-bridge',
        version: CodexSketchupMcp::PLUGIN_VERSION,
        protocol_version: CodexSketchupMcp::PROTOCOL_VERSION,
        queue_depth: @jobs&.length || 0,
        ui_heartbeat_age_ms: ((monotonic_time - (@last_ui_drain_at || monotonic_time)) * 1000).round,
        at: Time.now.utc.iso8601
      })
    end

    unless request[:method] == 'POST' && request[:path] == '/command'
      return write_json(socket, 404, { ok: false, error: 'Not found' })
    end

    payload = JSON.parse(request[:body].to_s)
    raise ArgumentError, 'Command payload must be an object' unless payload.is_a?(Hash)

    action = payload.fetch('action')
    params = payload['params'] || {}
    raise ArgumentError, 'params must be an object' unless params.is_a?(Hash)

    request_id = normalise_request_id(payload['request_id'])
    if (completed = completed_request(request_id))
      return write_json(socket, completed[:ok] ? 200 : 400, completed)
    end

    job = enqueue_job(action, params, request_id)
    result = wait_for_job(job)
    status = result[:ok] ? 200 : 400
    write_json(socket, status, result)
  rescue JSON::ParserError => e
    write_json(socket, 400, { ok: false, error: "Invalid JSON: #{e.message}" })
  rescue JobTimeout => e
    write_json(socket, 504, { ok: false, error: e.message })
  rescue ArgumentError, KeyError => e
    write_json(socket, 400, { ok: false, error: e.message })
  rescue StandardError => e
    write_json(socket, 500, { ok: false, error: e.message })
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    request_line = socket.gets&.strip
    raise ArgumentError, 'Empty request' if request_line.nil? || request_line.empty?

    method, path, = request_line.split(' ', 3)
    raise ArgumentError, 'Malformed HTTP request line' if method.nil? || path.nil?
    headers = {}
    header_count = 0
    while (line = socket.gets)
      header_count += 1
      raise ArgumentError, 'Too many HTTP headers' if header_count > MAX_HEADER_LINES
      raise ArgumentError, 'HTTP header line is too large' if line.bytesize > MAX_HEADER_LINE_BYTES
      line = line.strip
      break if line.empty?

      key, value = line.split(':', 2)
      headers[key.downcase] = value.to_s.strip if key
    end

    raw_length = headers.fetch('content-length', '0')
    raise ArgumentError, 'Invalid Content-Length header' unless raw_length.match?(/\A\d+\z/)
    length = raw_length.to_i
    raise ArgumentError, "Request body too large: #{length} bytes" if length > MAX_BODY_BYTES

    body = length.positive? ? socket.read(length) : ''
    raise ArgumentError, 'Request body ended before Content-Length bytes were received' if length.positive? && (!body || body.bytesize != length)
    { method: method, path: path, headers: headers, body: body }
  end

  def write_json(socket, status, payload)
    body = JSON.generate(payload)
    reason = {
      200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found', 429 => 'Too Many Requests',
      500 => 'Internal Server Error', 503 => 'Service Unavailable', 504 => 'Gateway Timeout'
    }.fetch(status, 'Error')
    socket.write "HTTP/1.1 #{status} #{reason}\r\n"
    socket.write "Content-Type: application/json; charset=utf-8\r\n"
    socket.write "Content-Length: #{body.bytesize}\r\n"
    socket.write "Connection: close\r\n"
    socket.write "\r\n"
    socket.write body
  end

  def drain_jobs
    @last_ui_drain_at = monotonic_time
    loop do
      begin
        job = @jobs.pop(true)
      rescue ThreadError
        break
      end

      unless begin_job(job)
        finish_job(job, {
          ok: false,
          error: 'Command expired before SketchUp began processing it',
          request_id: job[:request_id],
          at: Time.now.utc.iso8601
        })
        next
      end

      begin
        payload = execute(job[:action], job[:params])
        result = { ok: true, payload: payload, request_id: job[:request_id], at: Time.now.utc.iso8601 }
      rescue StandardError => e
        result = {
          ok: false,
          error: e.message,
          request_id: job[:request_id],
          backtrace: e.backtrace ? e.backtrace.first(5) : [],
          at: Time.now.utc.iso8601
        }
      end
      finish_job(job, result)
    end
  end

  def drain_file_jobs
    return unless file_queue_enabled?
    return unless File.exist?(COMMANDS_FILE)

    @file_command_offset = 0 if @file_command_offset.nil? || @file_command_offset > File.size(COMMANDS_FILE)
    File.open(COMMANDS_FILE, 'r:UTF-8') do |file|
      file.seek(@file_command_offset)
      while (line = file.gets)
        line_start = @file_command_offset
        @file_command_offset = file.pos
        next if line.strip.empty?
        begin
          command = JSON.parse(line)
          raise ArgumentError, 'File command must be an object' unless command.is_a?(Hash)
          raise ArgumentError, 'File command id is required' unless command.key?('id')
          raise ArgumentError, 'File command id must not be empty' if command['id'].to_s.strip.empty?

          request_id = normalise_request_id(command['id'])
        rescue JSON::ParserError, ArgumentError => e
          log("Skipping invalid file command: #{e.message}")
          next
        end
        next if @processed_file_commands[request_id]

        # The HTTP bridge may have accepted this request just before the caller
        # fell back to JSONL. Defer until that request has finished so the same
        # id can never create a second model operation.
        if pending_request?(request_id)
          @file_command_offset = line_start
          break
        end

        result = completed_request(request_id)
        unless result
          begin
            payload = execute(command.fetch('action'), command['params'] || {})
            result = { ok: true, payload: payload, request_id: request_id, at: Time.now.utc.iso8601 }
          rescue StandardError => e
            result = { ok: false, error: e.message, request_id: request_id, at: Time.now.utc.iso8601 }
          end
          cache_completed_request(request_id, result)
        end
        response = file_response_from_result(request_id, result)
        append_json_line(RESPONSES_FILE, response)
        remember_file_response(request_id)
      end
    end
  rescue StandardError => e
    log("File bridge error: #{e.class}: #{e.message}")
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def acquire_client_slot
    @client_mutex.synchronize do
      return false if @active_clients >= MAX_CLIENT_THREADS

      @active_clients += 1
      true
    end
  end

  def release_client_slot
    @client_mutex.synchronize { @active_clients = [@active_clients - 1, 0].max }
  end

  def normalise_request_id(value)
    request_id = value.to_s.strip
    request_id = SecureRandom.uuid if request_id.empty?
    raise ArgumentError, 'request_id must be at most 128 characters' if request_id.length > 128
    raise ArgumentError, 'request_id contains unsupported characters' unless request_id.match?(/\A[a-zA-Z0-9._:-]+\z/)

    request_id
  end

  def completed_request(request_id)
    @request_mutex.synchronize { @completed_requests[request_id] }
  end

  def pending_request?(request_id)
    @request_mutex.synchronize { @pending_requests.key?(request_id) }
  end

  def cache_completed_request(request_id, result)
    @request_mutex.synchronize do
      @completed_requests[request_id] = result
      @completed_requests.shift while @completed_requests.length > COMPLETED_REQUEST_CACHE_SIZE
      @pending_requests.delete(request_id)
    end
  end

  def file_response_from_result(request_id, result)
    if result[:ok]
      { id: request_id, ok: true, payload: result[:payload], at: result[:at] || Time.now.utc.iso8601 }
    else
      { id: request_id, ok: false, payload: { error: result[:error] }, at: result[:at] || Time.now.utc.iso8601 }
    end
  end

  def enqueue_job(action, params, request_id)
    @request_mutex.synchronize do
      return @pending_requests[request_id] if @pending_requests.key?(request_id)
      raise ArgumentError, "Bridge queue is full (#{MAX_QUEUE_DEPTH} commands)" if @jobs.length >= MAX_QUEUE_DEPTH

      job = {
        action: action,
        params: params,
        request_id: request_id,
        deadline: monotonic_time + JOB_TIMEOUT_SECONDS,
        mutex: Mutex.new,
        condition: ConditionVariable.new,
        state: :queued,
        result: nil
      }
      @pending_requests[request_id] = job
      @jobs << job
      job
    end
  end

  def wait_for_job(job)
    job[:mutex].synchronize do
      while job[:result].nil?
        remaining = job[:deadline] - monotonic_time
        if remaining <= 0
          job[:state] = :cancelled if job[:state] == :queued
          raise JobTimeout, job[:state] == :started ? 'SketchUp began the command but did not finish before the deadline' : 'SketchUp did not begin the command before the deadline'
        end
        job[:condition].wait(job[:mutex], remaining)
      end
      job[:result]
    end
  end

  def begin_job(job)
    job[:mutex].synchronize do
      return false unless job[:state] == :queued
      return false if monotonic_time > job[:deadline]

      job[:state] = :started
      true
    end
  end

  def finish_job(job, result)
    job[:mutex].synchronize do
      return if job[:result]

      job[:state] = :completed
      job[:result] = result
      job[:condition].broadcast
    end
    cache_completed_request(job[:request_id], result)
  end

  def read_request_line(socket, empty_message)
    line = socket.gets
    raise ArgumentError, empty_message if line.nil?
    raise ArgumentError, 'HTTP header line is too large' if line.bytesize > MAX_HEADER_LINE_BYTES

    line
  end

  def file_queue_enabled?
    configured = ENV.fetch('SKETCHUP_MCP_ENABLE_FILE_QUEUE', FILE_QUEUE_DEFAULT_ENABLED.to_s)
    %w[1 true yes on].include?(configured.downcase)
  end

  def prepare_file_queue
    FileUtils.mkdir_p(FILE_BRIDGE_DIR)
    FileUtils.touch(COMMANDS_FILE)
    FileUtils.touch(RESPONSES_FILE)
    @file_command_offset = 0
    @processed_file_commands = load_processed_file_response_ids
  end

  def load_processed_file_response_ids
    processed = {}
    return processed unless File.exist?(RESPONSES_FILE)

    File.foreach(RESPONSES_FILE, encoding: 'UTF-8') do |line|
      response = JSON.parse(line)
      id = response['id'].to_s
      next if id.empty?

      processed[id] = true
      processed.shift while processed.length > FILE_RESPONSE_CACHE_SIZE
    rescue JSON::ParserError
      next
    end
    processed
  rescue StandardError => e
    log("Could not load file-queue responses: #{e.class}: #{e.message}")
    {}
  end

  def remember_file_response(id)
    @processed_file_commands[id] = true
    @processed_file_commands.shift while @processed_file_commands.length > FILE_RESPONSE_CACHE_SIZE
  end

  def append_json_line(path, payload)
    File.open(path, 'a:UTF-8') do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate(payload))
      file.flock(File::LOCK_UN)
    end
  end

  def execute(action, params)
    normalized_action = normalise_action_name(action)
    normalized_params = normalise_action_params(normalized_action, params)
    return dispatch_action(normalized_action, normalized_params) if READ_ONLY_ACTIONS.include?(normalized_action)

    if normalized_action == 'apply_batch'
      operation_name = normalized_params.fetch('name', 'Codex apply batch')
      return with_operation(operation_name) { apply_batch(normalized_params) }
    end

    with_operation("Codex #{normalized_action.tr('_', ' ')}") do
      dispatch_action(normalized_action, normalized_params)
    end
  end

  def dispatch_action(action, params)
    case action
    when 'create_box'
      create_box(params)
    when 'create_cylinder'
      create_cylinder(params)
    when 'create_wall'
      create_wall(params)
    when 'create_slab'
      create_slab(params)
    when 'create_roof'
      create_roof(params)
    when 'create_stair'
      create_stair(params)
    when 'create_railing'
      create_railing(params)
    when 'create_window'
      create_window(params)
    when 'create_door'
      create_door(params)
    when 'create_glazing'
      create_glazing(params)
    when 'repair_wall_joints'
      repair_wall_joints(params)
    when 'rebuild_walls'
      rebuild_walls(params)
    when 'set_material'
      set_material(params)
    when 'move_entity'
      move_entity(params)
    when 'delete_entity'
      delete_entity(params)
    when 'list_entities'
      list_entities
    when 'quality_check'
      quality_check(params)
    when 'bridge_info'
      bridge_info
    else
      raise ArgumentError, "Unknown action: #{action}"
    end
  end

  def apply_batch(params)
    commands = params.fetch('commands')
    raise ArgumentError, 'commands must be a non-empty array' unless commands.is_a?(Array) && !commands.empty?
    raise ArgumentError, 'commands must contain at most 100 actions' if commands.length > 100

    results = commands.map.with_index do |command, index|
      raise ArgumentError, "commands[#{index}] must be an object" unless command.is_a?(Hash)

      action = normalise_action_name(command.fetch('action'))
      raise ArgumentError, "commands[#{index}] may not contain apply_batch" if action == 'apply_batch'
      raise ArgumentError, "commands[#{index}] must be a mutating action" unless MUTATING_ACTIONS.include?(action)

      command_params = normalise_action_params(action, command['params'] || command[:params] || {})
      { index: index, action: action, payload: dispatch_action(action, command_params) }
    end
    { atomic: true, command_count: results.length, results: results }
  end

  def normalise_action_name(value)
    action = value.to_s
    raise ArgumentError, 'action must be a non-empty string' if action.empty?
    raise ArgumentError, "Unknown action: #{action}" unless ACTION_CATALOG.key?(action)

    action
  end

  def normalise_action_params(action, params)
    normalized = deep_stringify(params)
    raise ArgumentError, 'params must be an object' unless normalized.is_a?(Hash)

    apply_catalog_aliases(action, normalized)
    case action
    when 'create_window', 'create_door'
      normalise_legacy_opening_params(normalized)
    when 'create_roof'
      raise ArgumentError, 'create_roof does not support rise; use thickness and parapet parameters' if normalized.key?('rise')
    end

    validate_catalog_params!(action, normalized)
    normalized
  end

  def apply_catalog_aliases(action, params)
    ACTION_CATALOG.fetch(action).fetch('aliases', {}).each do |legacy, canonical|
      promote_alias_path(params, canonical, legacy)
    end
  end

  def normalise_legacy_opening_params(params)
    opening = params['opening']
    raise ArgumentError, 'opening must be an object' if opening && !opening.is_a?(Hash)
    opening ||= {}
    %w[offset width height sill].each do |key|
      next unless params.key?(key)

      if opening.key?(key) && opening[key] != params[key]
        raise ArgumentError, "opening.#{key} and legacy #{key} cannot disagree"
      end
      opening[key] = params[key] unless opening.key?(key)
      params.delete(key)
    end
    params['opening'] = opening unless opening.empty?
  end

  def promote_alias_path(params, canonical_path, legacy)
    return unless params.key?(legacy)

    exists, current = nested_value(params, canonical_path)
    if exists && current != params[legacy]
      raise ArgumentError, "#{canonical_path} and legacy #{legacy} cannot disagree"
    end
    assign_nested_value(params, canonical_path, params[legacy]) unless exists
    params.delete(legacy)
  end

  def nested_value(params, path)
    current = params
    keys = path.split('.')
    keys.each_with_index do |key, index|
      return [false, nil] unless current.is_a?(Hash) && current.key?(key)
      return [true, current[key]] if index == keys.length - 1

      current = current[key]
    end
    [false, nil]
  end

  def assign_nested_value(params, path, value)
    keys = path.split('.')
    leaf = keys.pop
    target = keys.inject(params) do |current, key|
      existing = current[key]
      raise ArgumentError, "#{key} must be an object" if existing && !existing.is_a?(Hash)

      current[key] ||= {}
    end
    target[leaf] = value
  end

  def validate_catalog_params!(action, params)
    spec = ACTION_CATALOG.fetch(action)
    missing = spec.fetch('required', []).reject { |key| params.key?(key) && !params[key].nil? }
    selector = spec.fetch('selector_any_of', [])
    missing -= selector if selector.any? { |key| params.key?(key) && !params[key].nil? }
    raise ArgumentError, "#{action} is missing required parameter(s): #{missing.join(', ')}" unless missing.empty?

    allowed = spec.fetch('required', []) + spec.fetch('common_optional', []) + selector
    unknown = params.keys - allowed
    raise ArgumentError, "#{action} received unsupported parameter(s): #{unknown.join(', ')}" unless unknown.empty?
  end

  def deep_stringify(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), result| result[key.to_s] = deep_stringify(nested) }
    when Array
      value.map { |nested| deep_stringify(nested) }
    else
      value
    end
  end

  def with_operation(name)
    model = Sketchup.active_model
    model.start_operation(name, true)
    result = yield
    model.commit_operation
    result
  rescue StandardError
    model.abort_operation if model
    raise
  end

  def create_box(params)
    width = positive_mm(params.fetch('width'), 'width')
    depth = positive_mm(params.fetch('depth'), 'depth')
    height = positive_mm(params.fetch('height'), 'height')
    x = mm(params.fetch('x', 0))
    y = mm(params.fetch('y', 0))
    z = mm(params.fetch('z', 0))

    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'codex_box')
    tag_entity(group, 'box', params['entity_uuid'])
    pts = [[0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0]]
    face = add_face!(group.entities, pts, 'Box footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
    group.transform!(Geom::Transformation.translation([x, y, z]))
    apply_color(group, params['color']) if params['color']
    entity_payload(group)
  end

  def create_cylinder(params)
    radius = positive_mm(params.fetch('radius'), 'radius')
    height = positive_mm(params.fetch('height'), 'height')
    segments = integer_param(params.fetch('segments', 48), 'segments')
    raise ArgumentError, 'segments must be between 3 and 256' unless segments.between?(3, 256)
    x = mm(params.fetch('x', 0))
    y = mm(params.fetch('y', 0))
    z = mm(params.fetch('z', 0))

    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'codex_cylinder')
    tag_entity(group, 'cylinder', params['entity_uuid'])
    circle = group.entities.add_circle([0, 0, 0], [0, 0, 1], radius, segments)
    face = add_face!(group.entities, circle, 'Cylinder footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
    group.transform!(Geom::Transformation.translation([x, y, z]))
    apply_color(group, params['color']) if params['color']
    entity_payload(group)
  end

  # Architectural primitives use one local coordinate convention and snap all
  # millimetre inputs before geometry is created. A centre-aligned wall is
  # genuinely centred on its input line: the positive-normal face is offset by
  # half its thickness and is then push/pulled through to the negative side.
  # This is important at corners because all connected wall axes share the
  # same geometric datum.
  def create_wall(params)
    start_pt = point_param(params.fetch('start'), 'start')
    end_pt = point_param(params.fetch('end'), 'end')
    thickness = positive_mm(params.fetch('thickness'), 'thickness')
    height = positive_mm(params.fetch('height'), 'height')
    base_z = mm(params.fetch('z', 0))
    layout = wall_layout(start_pt, end_pt, thickness, params.fetch('alignment', 'center'))
    length = layout.fetch(:length)

    openings = normalise_openings(params['openings'] || [], length, height)
    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'wall')
    wall_uuid = tag_entity(group, 'wall', params['entity_uuid'])
    # Do not rely on Push/Pull recognising nested edge loops as openings.
    # Instead, form the wall from the solid areas around each opening. The
    # opening is then physically empty from its exterior face to its interior
    # face, so glass is visible from either side and can never be masked by a
    # leftover wall face.
    build_wall_segments(
      group.entities,
      layout.fetch(:outer_start),
      layout.fetch(:unit),
      layout.fetch(:normal),
      thickness,
      base_z,
      length,
      height,
      openings
    )
    wall_spec = params.merge(
      'entity_uuid' => wall_uuid,
      'openings' => openings.map { |opening| opening_payload(opening) },
      'schema_version' => CodexSketchupMcp::PROTOCOL_VERSION
    )
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec', JSON.generate(wall_spec))
    apply_color(group, params['color']) if params['color']
    entity_payload(group).merge(kind: 'wall', length_mm: length.to_mm.round(1))
  end

  def create_slab(params)
    points = polygon_param(params.fetch('points'))
    thickness = positive_mm(params.fetch('thickness'), 'thickness')
    z = mm(params.fetch('z', 0))
    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'slab')
    tag_entity(group, 'slab', params['entity_uuid'])
    face = add_face!(group.entities, points.map { |p| [p.x, p.y, z] }, 'Slab outline')
    face.reverse! if face.normal.z < 0
    face.pushpull(thickness)
    apply_color(group, params['color']) if params['color']
    entity_payload(group).merge(kind: 'slab')
  end

  def create_roof(params)
    points = polygon_param(params.fetch('points'))
    thickness = positive_mm(params.fetch('thickness', 180), 'thickness')
    z = mm(params.fetch('z', 0))
    parapet = nonnegative_mm(params.fetch('parapet_height', 0), 'parapet_height')
    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'roof')
    tag_entity(group, 'roof', params['entity_uuid'])
    face = add_face!(group.entities, points.map { |p| [p.x, p.y, z] }, 'Roof outline')
    face.reverse! if face.normal.z < 0
    face.pushpull(thickness)
    if parapet.positive?
      group.entities.add_edges(points.map { |p| [p.x, p.y, z + thickness] } + [[points.first.x, points.first.y, z + thickness]])
      # A parapet is represented by an inset perimeter so it remains editable.
      parapet_thickness = positive_mm(params.fetch('parapet_thickness', 120), 'parapet_thickness')
      create_perimeter_parapet(group, points, z + thickness, parapet, parapet_thickness)
    end
    apply_color(group, params['color']) if params['color']
    entity_payload(group).merge(kind: 'roof')
  end

  def create_stair(params)
    x = mm(params.fetch('x', 0))
    y = mm(params.fetch('y', 0))
    z = mm(params.fetch('z', 0))
    width = positive_mm(params.fetch('width'), 'width')
    run = positive_mm(params.fetch('run'), 'run')
    rise = positive_mm(params.fetch('rise'), 'rise')
    steps = integer_param(params.fetch('steps'), 'steps')
    raise ArgumentError, 'steps must be between 1 and 60' unless steps.between?(1, 60)
    direction = params.fetch('direction', 'y').to_s
    raise ArgumentError, 'direction must be x or y' unless %w[x y].include?(direction)
    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'stair')
    tag_entity(group, 'stair', params['entity_uuid'])
    steps.times do |index|
      step_z = z + (rise * index)
      points = if direction == 'x'
                 [[x + (run * index), y, step_z], [x + (run * (index + 1)), y, step_z], [x + (run * (index + 1)), y + width, step_z], [x + (run * index), y + width, step_z]]
               else
                 [[x, y + (run * index), step_z], [x + width, y + (run * index), step_z], [x + width, y + (run * (index + 1)), step_z], [x, y + (run * (index + 1)), step_z]]
               end
      face = add_face!(group.entities, points, "Stair step #{index + 1}")
      face.reverse! if face.normal.z < 0
      face.pushpull(rise)
    end
    apply_color(group, params['color']) if params['color']
    entity_payload(group).merge(kind: 'stair', step_count: steps, total_rise_mm: (rise * steps).to_mm.round(1))
  end

  def create_railing(params)
    start_pt = point_param(params.fetch('start'), 'start')
    end_pt = point_param(params.fetch('end'), 'end')
    height = positive_mm(params.fetch('height'), 'height')
    post_size = positive_mm(params.fetch('post_size', 50), 'post_size')
    spacing = positive_mm(params.fetch('spacing', 1200), 'spacing')
    raise ArgumentError, 'post_size must not exceed railing height' if post_size > height
    z = mm(params.fetch('z', 0))
    vector = end_pt - start_pt
    length = vector.length
    raise ArgumentError, 'Railing start and end must be different' if length < 0.001
    count = [(length / spacing).ceil, 1].max
    unit = vector.normalize
    group = Sketchup.active_model.entities.add_group
    group.name = params.fetch('name', 'railing')
    tag_entity(group, 'railing', params['entity_uuid'])
    (0..count).each do |index|
      point = start_pt.offset(unit, [index * spacing, length].min)
      add_box_to_entities(group.entities, point.x - post_size / 2.0, point.y - post_size / 2.0, z, post_size, post_size, height)
    end
    add_box_between(group.entities, start_pt, end_pt, z + height - post_size, post_size, post_size)
    apply_color(group, params['color']) if params['color']
    entity_payload(group).merge(kind: 'railing', post_count: count + 1)
  end

  def create_window(params)
    wall = find_entity(params)
    opening = params.fetch('opening')
    rebuild_wall_with_opening(wall, opening, 'window')
  end

  def create_door(params)
    wall = find_entity(params)
    opening = params.fetch('opening')
    rebuild_wall_with_opening(wall, opening, 'door')
  end

  # Rebuild only selected Codex walls. Wall UUIDs are retained, and glazing is
  # recreated from its stored style after replacement. Joints touching a
  # replaced wall are removed and then regenerated from the current wall specs.
  def rebuild_walls(params = {})
    names = params['names']
    names = names.map(&:to_s) if names.is_a?(Array)
    selected_uuids = params['entity_uuids']
    selected_uuids = selected_uuids.map(&:to_s) if selected_uuids.is_a?(Array)
    raise ArgumentError, 'names must be an array when provided' if params.key?('names') && !names
    raise ArgumentError, 'entity_uuids must be an array when provided' if params.key?('entity_uuids') && !selected_uuids
    targets = codex_walls.filter_map do |group, spec|
      next if names && !names.include?(group.name)
      next if selected_uuids && !selected_uuids.include?(spec.fetch('entity_uuid'))

      [group, spec]
    rescue JSON::ParserError, ArgumentError
      nil
    end
    raise ArgumentError, 'No matching Codex walls were found to rebuild' if targets.empty?

    target_uuids = targets.map { |_group, spec| spec.fetch('entity_uuid') }
    rebuilt = targets.map { |group, spec| replace_wall!(group, spec).fetch(:payload) }
    repair_wall_joints('entity_uuids' => target_uuids)
    { rebuilt_wall_count: rebuilt.length, walls: rebuilt }
  end

  def replace_wall!(wall, spec)
    wall_uuid = entity_uuid_for(wall, create: true)
    glazing_styles = glazing_styles_for_wall(wall)
    remove_glazing_for_wall!(wall)
    remove_wall_joints_for_wall!(wall)
    wall.erase!

    replacement_spec = deep_stringify(spec).merge(
      'entity_uuid' => wall_uuid,
      'schema_version' => CodexSketchupMcp::PROTOCOL_VERSION
    )
    payload = create_wall(replacement_spec)
    replacement = find_entity('entity_id' => wall_uuid)
    restored = restore_glazing_for_wall!(replacement, glazing_styles)
    { payload: payload.merge(restored_glazing_count: restored), wall: replacement }
  end

  def glazing_styles_for_wall(wall)
    wall_uuid = entity_uuid_for(wall, create: true)
    wall_id = wall.persistent_id.to_s
    Sketchup.active_model.entities.grep(Sketchup::Group).filter_map do |group|
      next unless glazing_for_wall?(group, [wall_id], [wall_uuid])
      next unless group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_role') == 'glass'

      index = integer_param(group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_index'), 'stored opening_index')
      style_json = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_style')
      style = JSON.parse(style_json.to_s)
      raise ArgumentError, 'Stored glazing style must be an object' unless style.is_a?(Hash)

      {
        index: index,
        opening_id: group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_id'),
        style: style
      }
    rescue JSON::ParserError, ArgumentError => error
      log("Ignoring invalid stored glazing on #{group.persistent_id}: #{error.message}")
      nil
    end
  end

  def restore_glazing_for_wall!(wall, styles)
    return 0 if styles.empty?

    spec = wall_spec_for(wall)
    restored = 0
    styles.each do |entry|
      opening = spec.fetch('openings', []).find { |candidate| candidate['id'] == entry[:opening_id] }
      opening ||= spec.fetch('openings', [])[entry.fetch(:index)]
      next unless opening

      begin
        style = entry.fetch(:style)
        create_glazing_for_opening(
          wall,
          spec,
          opening,
          entry.fetch(:index),
          positive_mm(style.fetch('thickness', 12), 'stored glazing thickness'),
          positive_mm(style.fetch('frame_width', 55), 'stored glazing frame_width'),
          positive_mm(style.fetch('frame_depth', 45), 'stored glazing frame_depth'),
          style.fetch('color', '#7FAFC4'),
          normalise_opacity(style.fetch('opacity', 0.38)),
          style.fetch('frame_color', '#26333A')
        )
        restored += 1
      rescue StandardError => error
        log("Could not restore glazing for wall #{wall.name}: #{error.message}")
      end
    end
    restored
  end

  def remove_glazing_for_wall!(wall)
    wall_uuid = entity_uuid_for(wall, create: true)
    wall_id = wall.persistent_id.to_s
    Sketchup.active_model.entities.grep(Sketchup::Group).select do |group|
      glazing_for_wall?(group, [wall_id], [wall_uuid])
    end.each(&:erase!)
  end

  def remove_wall_joints_for_wall!(wall)
    wall_uuid = entity_uuid_for(wall, create: true)
    wall_id = wall.persistent_id.to_s
    Sketchup.active_model.entities.grep(Sketchup::Group).select do |group|
      joint_for_wall?(group, [wall_id], [wall_uuid])
    end.each(&:erase!)
  end

  # Creates actual transparent glass and a separate aluminium frame for window
  # openings. Openings alone are intentionally just holes; a visible glass
  # pane must be geometry in its own group so material alpha can be rendered.
  def create_glazing(params)
    wall = find_entity(params)
    spec = wall_spec_for(wall)
    raise ArgumentError, 'Selected entity was not created as a Codex wall' unless spec

    openings = spec.fetch('openings', []).each_with_index.map { |opening, index| [opening, index] }
    include_doors = boolean_param(params.fetch('include_doors', false), 'include_doors')
    openings.select! { |opening, _index| opening['type'].to_s == 'window' } unless include_doors
    requested_index = params['opening_index']
    if requested_index
      index = integer_param(requested_index, 'opening_index')
      raise ArgumentError, 'opening_index must be zero or greater' if index.negative?

      openings.select! { |_opening, opening_index| opening_index == index }
    end
    raise ArgumentError, 'No matching window or door opening was found for glazing' if openings.empty?

    thickness = positive_mm(params.fetch('thickness', 12), 'thickness')
    frame_width = positive_mm(params.fetch('frame_width', 55), 'frame_width')
    frame_depth = positive_mm(params.fetch('frame_depth', 45), 'frame_depth')
    glass_color = params.fetch('color', '#7FAFC4')
    glass_opacity = normalise_opacity(params.fetch('opacity', 0.38))
    frame_color = params.fetch('frame_color', '#26333A')
    openings.each do |opening, _index|
      opening_width = positive_mm(opening.fetch('width'), 'opening width')
      opening_height = positive_mm(opening.fetch('height'), 'opening height')
      visible_width = opening_width - (frame_width * 2.0)
      visible_height = opening_height - (frame_width * 2.0)
      if visible_width < MIN_GLAZING_CLEAR_MM.mm || visible_height < MIN_GLAZING_CLEAR_MM.mm
        raise ArgumentError, 'frame_width leaves less than 50 mm of visible glass; reduce it or enlarge the opening'
      end
    end
    ensure_transparency_display
    created = openings.map do |opening, index|
      create_glazing_for_opening(wall, spec, opening, index, thickness, frame_width, frame_depth, glass_color, glass_opacity, frame_color)
    end
    { wall_entity_id: entity_identifier_for(wall), wall_name: wall.name, glazing_count: created.length, glazing: created }
  end

  # Adds compact convex-hull corner infills for existing independently-created
  # walls. It deliberately does not erase or rebuild the user's walls; it only
  # fills a shared-endpoint corner once. New walls should still be authored on
  # centred axes for the cleanest result.
  def repair_wall_joints(params = {})
    tolerance = positive_mm(params.fetch('tolerance', 2), 'tolerance')
    selected_names = params['names']
    selected_names = selected_names.map(&:to_s) if selected_names.is_a?(Array)
    selected_uuids = params['entity_uuids']
    selected_uuids = selected_uuids.map(&:to_s) if selected_uuids.is_a?(Array)
    raise ArgumentError, 'names must be an array when provided' if params.key?('names') && !selected_names
    raise ArgumentError, 'entity_uuids must be an array when provided' if params.key?('entity_uuids') && !selected_uuids
    walls = codex_walls
    targets = walls.select do |group, spec|
      (!selected_names || selected_names.include?(group.name)) &&
        (!selected_uuids || selected_uuids.include?(spec.fetch('entity_uuid')))
    end
    if selected_names || selected_uuids
      raise ArgumentError, 'No matching Codex walls were found to repair' if targets.empty?
    else
      targets = walls
    end
    target_uuids = targets.map { |_group, spec| spec.fetch('entity_uuid') }

    existing_joints = Sketchup.active_model.entities.grep(Sketchup::Group).select do |group|
      group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key')
    end
    created = []
    migrated = 0
    walls.combination(2) do |left, right|
      left_group, left_spec = left
      right_group, right_spec = right
      pair_uuids = [left_spec.fetch('entity_uuid'), right_spec.fetch('entity_uuid')]
      next unless pair_uuids.any? { |uuid| target_uuids.include?(uuid) }
      next unless comparable_wall_elevations?(left_spec, right_spec, tolerance)

      shared = shared_wall_endpoint(left_spec, right_spec, tolerance)
      next unless shared
      next if collinear_wall_specs?(left_spec, right_spec)

      key = wall_joint_key(left_group, right_group)
      legacy_key = [left_group.persistent_id, right_group.persistent_id].sort.join(':')
      if (existing = existing_joints.find { |joint| [key, legacy_key].include?(joint.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key')) })
        migrated += 1 if migrate_wall_joint!(existing, left_group, right_group, key)
        next
      end

      joint = create_wall_joint_group(shared, left_group, left_spec, right_group, right_spec, key, created.length + 1)
      created << entity_payload(joint).merge(left_wall: left_group.name, right_wall: right_group.name)
    end
    { repaired_joint_count: created.length, migrated_joint_count: migrated, joints: created }
  end

  def normalise_openings(raw_openings, wall_length, wall_height)
    raise ArgumentError, 'openings must be an array' unless raw_openings.is_a?(Array)

    openings = raw_openings.map.with_index do |raw, index|
      raise ArgumentError, "opening #{index + 1} must be an object" unless raw.is_a?(Hash)
      type = raw.fetch('type', 'window').to_s
      raise ArgumentError, "opening #{index + 1} type must be window or door" unless %w[window door].include?(type)
      opening_id = raw['id'] || raw['opening_id'] || SecureRandom.uuid
      if raw['id'] && raw['opening_id'] && raw['id'].to_s != raw['opening_id'].to_s
        raise ArgumentError, "opening #{index + 1} id and opening_id cannot disagree"
      end
      opening = {
        id: normalise_identifier(opening_id, "opening #{index + 1} id"),
        type: type,
        offset: nonnegative_mm(raw.fetch('offset'), "opening #{index + 1} offset"),
        width: positive_mm(raw.fetch('width'), "opening #{index + 1} width"),
        height: positive_mm(raw.fetch('height'), "opening #{index + 1} height"),
        sill: nonnegative_mm(raw.fetch('sill', 0), "opening #{index + 1} sill")
      }
      if type == 'door' && opening[:sill] > 0.001
        raise ArgumentError, "opening #{index + 1} door sill must be zero"
      end
      raise ArgumentError, "opening #{index + 1} exceeds wall length" if opening[:offset] + opening[:width] > wall_length + 0.001
      raise ArgumentError, "opening #{index + 1} exceeds wall height" if opening[:sill] + opening[:height] > wall_height + 0.001
      opening
    end.sort_by { |opening| opening[:offset] }

    ids = {}
    previous_end = 0.0
    openings.each_with_index do |opening, index|
      raise ArgumentError, "opening #{index + 1} id is duplicated" if ids[opening[:id]]

      ids[opening[:id]] = true
      if opening[:offset] < previous_end - 0.001
        raise ArgumentError, "opening #{index + 1} overlaps the preceding opening"
      end
      previous_end = opening[:offset] + opening[:width]
    end
    openings
  end

  def build_wall_segments(entities, outer_start, unit, normal, thickness, base_z, wall_length, wall_height, openings)
    cursor = 0.0
    openings.each do |opening|
      add_wall_segment(entities, outer_start, unit, normal, thickness, base_z, cursor, opening[:offset], wall_height)
      add_wall_segment(entities, outer_start, unit, normal, thickness, base_z, opening[:offset], opening[:offset] + opening[:width], opening[:sill]) if opening[:sill].positive?
      upper_base = opening[:sill] + opening[:height]
      add_wall_segment(entities, outer_start, unit, normal, thickness, base_z + upper_base, opening[:offset], opening[:offset] + opening[:width], wall_height - upper_base) if upper_base < wall_height
      cursor = opening[:offset] + opening[:width]
    end
    add_wall_segment(entities, outer_start, unit, normal, thickness, base_z, cursor, wall_length, wall_height)
  end

  def add_wall_segment(entities, outer_start, unit, normal, thickness, base_z, from, to, height)
    return if (to - from) <= 0.001 || height <= 0.001

    centre = outer_start.offset(unit, (from + to) / 2.0).offset(normal, -thickness / 2.0)
    add_oriented_box(entities, centre, unit, normal, to - from, thickness, height, base_z)
  end

  def opening_payload(opening)
    {
      'id' => opening[:id],
      'type' => opening[:type],
      'offset' => opening[:offset].to_mm.round(1),
      'width' => opening[:width].to_mm.round(1),
      'height' => opening[:height].to_mm.round(1),
      'sill' => opening[:sill].to_mm.round(1)
    }
  end

  def rebuild_wall_with_opening(wall, raw_opening, type)
    spec = wall_spec_for(wall)
    raise ArgumentError, 'Selected entity was not created as a Codex wall' unless spec
    raise ArgumentError, 'opening must be an object' unless raw_opening.is_a?(Hash)
    spec['openings'] ||= []
    spec['openings'] << deep_stringify(raw_opening).merge('type' => type)
    spec['name'] = wall.name unless wall.name.to_s.strip.empty?
    old_persistent_id = wall.persistent_id.to_s
    wall_uuid = entity_uuid_for(wall, create: true)
    result = replace_wall!(wall, spec).fetch(:payload)
    repair_wall_joints('entity_uuids' => [wall_uuid])
    result.merge(kind: "#{type}_opening", replaced_persistent_id: old_persistent_id, name: spec['name'])
  end

  def create_glazing_for_opening(wall, spec, opening, index, thickness, frame_width, frame_depth, glass_color, glass_opacity, frame_color)
    glass = nil
    frame = nil
    start_pt = point_param(spec.fetch('start'), 'start')
    end_pt = point_param(spec.fetch('end'), 'end')
    wall_thickness = positive_mm(spec.fetch('thickness'), 'thickness')
    base_z = mm(spec.fetch('z', 0))
    layout = wall_layout(start_pt, end_pt, wall_thickness, spec.fetch('alignment', 'center'))
    unit = layout.fetch(:unit)
    normal = layout.fetch(:normal)
    midpoint = layout.fetch(:center_start).offset(unit, mm(opening.fetch('offset')) + (mm(opening.fetch('width')) / 2.0))
    sill_z = base_z + mm(opening.fetch('sill', 0))
    opening_width = positive_mm(opening.fetch('width'), 'opening width')
    opening_height = positive_mm(opening.fetch('height'), 'opening height')
    wall_uuid = entity_uuid_for(wall, create: true)
    opening_id = opening.fetch('id', index.to_s)
    tag = "#{wall_uuid}:#{opening_id}"
    glazing_style = {
      'thickness' => thickness.to_mm.round(1),
      'frame_width' => frame_width.to_mm.round(1),
      'frame_depth' => frame_depth.to_mm.round(1),
      'color' => glass_color,
      'opacity' => glass_opacity,
      'frame_color' => frame_color
    }

    previous = Sketchup.active_model.entities.grep(Sketchup::Group).select do |group|
      group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_key') == tag
    end
    previous.each(&:erase!)

    glass = Sketchup.active_model.entities.add_group
    glass.name = "#{wall.name}_Glass_#{index + 1}"
    tag_entity(glass, 'glazing_glass')
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_key', tag)
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall_uuid', wall_uuid)
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall', wall.persistent_id.to_s)
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_role', 'glass')
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_index', index)
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_id', opening_id)
    glass.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_style', JSON.generate(glazing_style))
    add_oriented_box(glass.entities, midpoint, unit, normal, opening_width - (frame_width * 2.0), thickness, opening_height - (frame_width * 2.0), sill_z + frame_width)
    apply_color(glass, glass_color, glass_opacity)

    frame = Sketchup.active_model.entities.add_group
    frame.name = "#{wall.name}_Frame_#{index + 1}"
    tag_entity(frame, 'glazing_frame')
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_key', tag)
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall_uuid', wall_uuid)
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall', wall.persistent_id.to_s)
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_role', 'frame')
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_index', index)
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'opening_id', opening_id)
    frame.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_style', JSON.generate(glazing_style))
    frame_midpoint = midpoint.offset(normal, (wall_thickness / 2.0) - (frame_depth / 2.0))
    half_width = opening_width / 2.0
    add_oriented_box(frame.entities, frame_midpoint.offset(unit, -half_width + (frame_width / 2.0)), unit, normal, frame_width, frame_depth, opening_height, sill_z)
    add_oriented_box(frame.entities, frame_midpoint.offset(unit, half_width - (frame_width / 2.0)), unit, normal, frame_width, frame_depth, opening_height, sill_z)
    add_oriented_box(frame.entities, frame_midpoint, unit, normal, opening_width, frame_depth, frame_width, sill_z)
    add_oriented_box(frame.entities, frame_midpoint, unit, normal, opening_width, frame_depth, frame_width, sill_z + opening_height - frame_width)
    apply_color(frame, frame_color)

    { opening_index: index, opening_id: opening_id, glass: entity_payload(glass), frame: entity_payload(frame) }
  rescue StandardError
    glass.erase! if glass&.valid?
    frame.erase! if frame&.valid?
    raise
  end

  def add_oriented_box(entities, centre, unit, normal, width, depth, height, z)
    return if width <= 0 || depth <= 0 || height <= 0

    half_width = width / 2.0
    half_depth = depth / 2.0
    p1 = centre.offset(unit, -half_width).offset(normal, -half_depth)
    p2 = centre.offset(unit, half_width).offset(normal, -half_depth)
    p3 = centre.offset(unit, half_width).offset(normal, half_depth)
    p4 = centre.offset(unit, -half_width).offset(normal, half_depth)
    face = add_face!(entities, [[p1.x, p1.y, z], [p2.x, p2.y, z], [p3.x, p3.y, z], [p4.x, p4.y, z]], 'Oriented box footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
  end

  def comparable_wall_elevations?(left, right, tolerance)
    (mm(left.fetch('z', 0)) - mm(right.fetch('z', 0))).abs <= tolerance &&
      (positive_mm(left.fetch('height'), 'height') - positive_mm(right.fetch('height'), 'height')).abs <= tolerance
  end

  def shared_wall_endpoint(left, right, tolerance)
    left_points = [point_param(left.fetch('start'), 'start'), point_param(left.fetch('end'), 'end')]
    right_points = [point_param(right.fetch('start'), 'start'), point_param(right.fetch('end'), 'end')]
    left_points.product(right_points).find { |a, b| a.distance(b) <= tolerance }&.first
  end

  def collinear_wall_specs?(left, right)
    left_vector = point_param(left.fetch('end'), 'end') - point_param(left.fetch('start'), 'start')
    right_vector = point_param(right.fetch('end'), 'end') - point_param(right.fetch('start'), 'start')
    (left_vector.x * right_vector.y - left_vector.y * right_vector.x).abs < 0.001
  end

  def create_wall_joint_group(shared, left_group, left_spec, right_group, right_spec, key, ordinal)
    points = wall_corner_footprint(shared, left_spec) + wall_corner_footprint(shared, right_spec)
    ordered = convex_hull(points)
    raise ArgumentError, 'Wall joint footprint needs at least three distinct points' if ordered.length < 3

    group = Sketchup.active_model.entities.add_group
    group.name = "Codex_WallJoint_#{ordinal}"
    tag_entity(group, 'wall_joint')
    base_z = mm(left_spec.fetch('z', 0))
    height = positive_mm(left_spec.fetch('height'), 'height')
    face = add_face!(group.entities, ordered.map { |point| [point.x, point.y, base_z] }, 'Wall joint footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key', key)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_left_uuid', entity_uuid_for(left_group, create: true))
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_right_uuid', entity_uuid_for(right_group, create: true))
    apply_color(group, left_spec['color'] || right_spec['color']) if left_spec['color'] || right_spec['color']
    group
  end

  def wall_corner_footprint(shared, spec)
    start_pt = point_param(spec.fetch('start'), 'start')
    end_pt = point_param(spec.fetch('end'), 'end')
    layout = wall_layout(start_pt, end_pt, positive_mm(spec.fetch('thickness'), 'thickness'), spec.fetch('alignment', 'center'))
    unit = layout.fetch(:unit)
    normal = layout.fetch(:normal)
    half = positive_mm(spec.fetch('thickness'), 'thickness') / 2.0
    extension = half
    centre_shared = shared.offset(normal, layout.fetch(:center_offset))
    [
      centre_shared.offset(unit, extension).offset(normal, half),
      centre_shared.offset(unit, extension).offset(normal, -half),
      centre_shared.offset(unit, -extension).offset(normal, -half),
      centre_shared.offset(unit, -extension).offset(normal, half)
    ]
  end

  def convex_hull(points)
    unique = points.uniq { |point| [point.x.round(6), point.y.round(6)] }
    return unique if unique.length < 3

    sorted = unique.sort_by { |point| [point.x, point.y] }
    lower = []
    sorted.each do |point|
      lower.pop while lower.length >= 2 && orientation(lower[-2], lower[-1], point) <= 0.001
      lower << point
    end
    upper = []
    sorted.reverse_each do |point|
      upper.pop while upper.length >= 2 && orientation(upper[-2], upper[-1], point) <= 0.001
      upper << point
    end
    lower[0...-1] + upper[0...-1]
  end

  def create_perimeter_parapet(group, points, z, height, thickness)
    points.each_with_index do |point, index|
      nxt = points[(index + 1) % points.length]
      vector = nxt - point
      length = vector.length
      next if length < 0.001
      unit = vector.normalize
      normal = Geom::Vector3d.new(-unit.y, unit.x, 0)
      p1 = point.offset(normal, -thickness / 2.0)
      p2 = nxt.offset(normal, -thickness / 2.0)
      add_box_between(group.entities, p1, p2, z, thickness, height)
    end
  end

  def add_box_between(entities, start_pt, end_pt, z, thickness, height)
    vector = end_pt - start_pt
    length = vector.length
    return if length < 0.001
    unit = vector.normalize
    normal = Geom::Vector3d.new(-unit.y, unit.x, 0)
    p1 = start_pt.offset(normal, thickness / 2.0)
    p2 = end_pt.offset(normal, thickness / 2.0)
    p3 = end_pt.offset(normal, -thickness / 2.0)
    p4 = start_pt.offset(normal, -thickness / 2.0)
    face = add_face!(entities, [[p1.x, p1.y, z], [p2.x, p2.y, z], [p3.x, p3.y, z], [p4.x, p4.y, z]], 'Linear box footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
  end

  def add_box_to_entities(entities, x, y, z, width, depth, height)
    face = add_face!(entities, [[x, y, z], [x + width, y, z], [x + width, y + depth, z], [x, y + depth, z]], 'Box footprint')
    face.reverse! if face.normal.z < 0
    face.pushpull(height)
  end

  def quality_check(_params = {})
    groups = Sketchup.active_model.entities.grep(Sketchup::Group)
    tiny = groups.select do |group|
      group.bounds.width < 0.1 || group.bounds.height < 0.1 || group.bounds.depth < 0.1
    end
    unnamed = groups.select { |group| group.name.to_s.strip.empty? }
    walls = []
    malformed_walls = []
    unmigrated_walls = []
    groups.each do |group|
      next unless group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec')

      begin
        spec = wall_spec_for(group, migrate: false)
        walls << [group, spec]
        unless spec['entity_uuid']
          unmigrated_walls << { persistent_id: group.persistent_id.to_s, name: group.name }
        end
      rescue JSON::ParserError, ArgumentError => error
        malformed_walls << { persistent_id: group.persistent_id.to_s, error: error.message }
      end
    end
    wall_uuids = walls.filter_map { |_group, spec| spec['entity_uuid'] }
    wall_ids = walls.map { |group, _spec| group.persistent_id.to_s }
    orphan_glazing = groups.select do |group|
      linked_uuid = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall_uuid').to_s
      linked_id = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall').to_s
      !linked_uuid.empty? && !wall_uuids.include?(linked_uuid) ||
        linked_uuid.empty? && !linked_id.empty? && !wall_ids.include?(linked_id)
    end
    orphan_joints = groups.select do |group|
      next false unless group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key')

      links = %w[wall_joint_left_uuid wall_joint_right_uuid].map do |key|
        group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, key).to_s
      end.reject(&:empty?)
      !links.empty? && links.any? { |uuid| !wall_uuids.include?(uuid) }
    end
    issue_count = tiny.length + unnamed.length + malformed_walls.length + unmigrated_walls.length + orphan_glazing.length + orphan_joints.length
    {
      status: issue_count.zero? ? 'ok' : 'warning',
      group_count: groups.length,
      managed_group_count: groups.count { |group| managed_entity?(group) },
      wall_count: walls.length,
      tiny_group_ids: tiny.map { |group| entity_identifier_for(group) },
      unnamed_group_ids: unnamed.map { |group| entity_identifier_for(group) },
      malformed_walls: malformed_walls,
      unmigrated_walls: unmigrated_walls,
      orphan_glazing_ids: orphan_glazing.map { |group| entity_identifier_for(group) },
      orphan_joint_ids: orphan_joints.map { |group| entity_identifier_for(group) }
    }
  end

  def bridge_info
    {
      service: 'codex-sketchup-mcp-port-bridge',
      version: CodexSketchupMcp::PLUGIN_VERSION,
      protocol_version: CodexSketchupMcp::PROTOCOL_VERSION,
      action_catalog_protocol_version: ACTION_CATALOG_DOCUMENT.fetch('protocol_version'),
      actions: ACTION_CATALOG.keys.sort,
      mutating_actions: MUTATING_ACTIONS.sort
    }
  end

  def set_material(params)
    entity = find_entity(params)
    color = params.fetch('color')
    opacity = normalise_opacity(params['opacity'])
    apply_color(entity, color, opacity)
    if (spec = wall_spec_for(entity))
      spec['color'] = color
      store_wall_spec!(entity, spec)
    end
    entity_payload(entity).merge(material: color, opacity: opacity)
  end

  def move_entity(params)
    entity = find_entity(params)
    dx = mm(params.fetch('dx', 0), 'dx')
    dy = mm(params.fetch('dy', 0), 'dy')
    dz = mm(params.fetch('dz', 0), 'dz')
    if (spec = wall_spec_for(entity))
      wall_uuid = entity_uuid_for(entity, create: true)
      old_persistent_id = entity.persistent_id.to_s
      result = replace_wall!(entity, translate_wall_spec(spec, dx, dy, dz)).fetch(:payload)
      repair_wall_joints('entity_uuids' => [wall_uuid])
      return result.merge(moved: true, replaced_persistent_id: old_persistent_id)
    end

    entity.transform!(Geom::Transformation.translation([dx, dy, dz]))
    entity_payload(entity).merge(moved: true)
  end

  def translate_wall_spec(spec, dx, dy, dz)
    translated = deep_stringify(spec)
    %w[start end].each do |key|
      point = translated.fetch(key)
      raise ArgumentError, "stored wall #{key} must be an array" unless point.is_a?(Array) && point.length.between?(2, 3)

      point[0] = (mm(point[0], "stored wall #{key}[0]") + dx).to_mm.round(1)
      point[1] = (mm(point[1], "stored wall #{key}[1]") + dy).to_mm.round(1)
      point[2] = (mm(point[2], "stored wall #{key}[2]") + dz).to_mm.round(1) if point.length == 3
    end
    translated['z'] = (mm(translated.fetch('z', 0), 'stored wall z') + dz).to_mm.round(1)
    translated
  end

  def delete_entity(params)
    entity = find_entity(params)
    payload = entity_payload(entity)
    if wall_spec_for(entity)
      remove_glazing_for_wall!(entity)
      remove_wall_joints_for_wall!(entity)
    end
    entity.erase!
    payload.merge(deleted: true)
  end

  def list_entities
    groups = Sketchup.active_model.entities.grep(Sketchup::Group)
    { entities: groups.map { |group| entity_payload(group) }, managed_group_count: groups.count { |group| managed_entity?(group) } }
  end

  def find_entity(params)
    id = (params['entity_id'] || params['id']).to_s.strip
    name = params['name']
    raise ArgumentError, 'entity_id or name is required' if id.empty? && name.to_s.strip.empty?

    groups = Sketchup.active_model.entities.grep(Sketchup::Group).select(&:valid?)
    matches = groups
    unless id.empty?
      matches = matches.select do |group|
        entity_uuid_for(group).to_s == id || group.persistent_id.to_s == id
      end
    end
    matches = matches.select { |group| group.name == name.to_s } unless name.nil?
    raise ArgumentError, "Entity not found: #{id.empty? ? name : id}" if matches.empty?
    raise ArgumentError, "Entity selector is ambiguous: #{id.empty? ? name : id}" if matches.length > 1

    matches.first
  end

  def tag_entity(group, kind, requested_uuid = nil)
    raise ArgumentError, 'Cannot tag an invalid SketchUp entity' unless group&.valid?

    existing_uuid = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'entity_uuid')
    uuid = requested_uuid || existing_uuid || SecureRandom.uuid
    uuid = normalise_identifier(uuid, 'entity_uuid')
    duplicates = Sketchup.active_model.entities.grep(Sketchup::Group).select do |candidate|
      candidate != group && candidate.valid? && candidate.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'entity_uuid').to_s == uuid
    end
    raise ArgumentError, "entity_uuid is already in use: #{uuid}" unless duplicates.empty?

    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'entity_uuid', uuid)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'kind', kind.to_s)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'schema_version', CodexSketchupMcp::PROTOCOL_VERSION)
    uuid
  end

  def entity_uuid_for(entity, create: false)
    value = entity.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'entity_uuid') if entity&.valid?
    return normalise_identifier(value, 'stored entity_uuid') unless value.to_s.strip.empty?
    return nil unless create

    tag_entity(entity, entity.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'kind') || 'entity')
  end

  def entity_identifier_for(entity)
    entity_uuid_for(entity) || entity.persistent_id.to_s
  end

  def managed_entity?(entity)
    !entity_uuid_for(entity).nil? || !!entity.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec')
  end

  def wall_spec_for(group, migrate: true)
    serialized = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec')
    return nil unless serialized

    spec = deep_stringify(JSON.parse(serialized.to_s))
    raise ArgumentError, 'Stored wall specification must be an object' unless spec.is_a?(Hash)
    uuid = spec['entity_uuid'] || entity_uuid_for(group)
    if migrate
      uuid ||= SecureRandom.uuid
      uuid = tag_entity(group, 'wall', uuid)
      changed = spec['entity_uuid'] != uuid || spec['schema_version'] != CodexSketchupMcp::PROTOCOL_VERSION
      spec['entity_uuid'] = uuid
      spec['schema_version'] = CodexSketchupMcp::PROTOCOL_VERSION
      store_wall_spec!(group, spec) if changed
    elsif uuid
      spec['entity_uuid'] = normalise_identifier(uuid, 'stored entity_uuid')
    end
    spec
  rescue JSON::ParserError => error
    raise ArgumentError, "Stored wall specification is invalid JSON: #{error.message}"
  end

  def store_wall_spec!(group, spec)
    normalized = deep_stringify(spec)
    raise ArgumentError, 'Stored wall specification must be an object' unless normalized.is_a?(Hash)

    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec', JSON.generate(normalized))
  end

  def codex_walls
    Sketchup.active_model.entities.grep(Sketchup::Group).filter_map do |group|
      spec = wall_spec_for(group)
      spec ? [group, spec] : nil
    rescue JSON::ParserError, ArgumentError => error
      log("Ignoring invalid Codex wall #{group.persistent_id}: #{error.message}")
      nil
    end
  end

  def glazing_for_wall?(group, target_ids, target_uuids)
    return false unless group&.valid?

    linked_uuid = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall_uuid').to_s
    linked_id = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'glazing_wall').to_s
    target_uuids.include?(linked_uuid) || target_ids.include?(linked_id)
  end

  def joint_for_wall?(group, target_ids, target_uuids)
    return false unless group&.valid?
    return false unless group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key')

    linked_uuids = %w[wall_joint_left_uuid wall_joint_right_uuid].map do |key|
      group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, key).to_s
    end
    return true if linked_uuids.any? { |uuid| target_uuids.include?(uuid) }

    legacy_key = group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key').to_s
    target_ids.any? { |id| legacy_key.split(':').include?(id) }
  end

  def wall_joint_key(left_group, right_group)
    JSON.generate([entity_uuid_for(left_group, create: true), entity_uuid_for(right_group, create: true)].sort)
  end

  def migrate_wall_joint!(group, left_group, right_group, key)
    changed = false
    changed ||= group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key') != key
    changed ||= group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_left_uuid') != entity_uuid_for(left_group, create: true)
    changed ||= group.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_right_uuid') != entity_uuid_for(right_group, create: true)
    tag_entity(group, 'wall_joint') unless entity_uuid_for(group)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_key', key)
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_left_uuid', entity_uuid_for(left_group, create: true))
    group.set_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_joint_right_uuid', entity_uuid_for(right_group, create: true))
    changed
  end

  def apply_color(entity, hex, opacity = nil)
    normalized_hex = hex.to_s.delete('#')
    normalized_opacity = normalise_opacity(opacity)
    material_name = "codex_#{normalized_hex}"
    material_name += "_opacity_#{(normalized_opacity * 100).round}" unless normalized_opacity == 1.0
    material = Sketchup.active_model.materials[material_name] ||
               Sketchup.active_model.materials.add(material_name)
    material.color = color_from_hex(hex)
    material.alpha = normalized_opacity
    entity.material = material
    entity.entities.grep(Sketchup::Face).each { |face| face.material = material }
  end

  # Material alpha has no visual effect while a model style has transparency
  # disabled. Enable it whenever real glazing is created; this is stored with
  # the active model and makes the glass read transparently in the viewport.
  def ensure_transparency_display
    Sketchup.active_model.rendering_options['DisplayTransparency'] = true
  rescue StandardError => error
    log("Could not enable transparency display: #{error.message}")
  end

  def normalise_opacity(value)
    return 1.0 if value.nil?

    opacity = Float(value)
    raise ArgumentError unless opacity.finite? && opacity.between?(0.0, 1.0)

    opacity.round(3)
  rescue ArgumentError, TypeError, FloatDomainError
    raise ArgumentError, 'opacity must be a number between 0.0 (transparent) and 1.0 (opaque)'
  end

  def color_from_hex(hex)
    value = hex.to_s.delete('#')
    raise ArgumentError, "Invalid color: #{hex}" unless value.match?(/\A[0-9a-fA-F]{6}\z/)

    Sketchup::Color.new(value[0, 2].to_i(16), value[2, 2].to_i(16), value[4, 2].to_i(16))
  end

  def entity_payload(entity)
    bounds = entity.bounds
    uuid = entity_uuid_for(entity)
    kind = entity.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'kind')
    kind ||= 'wall' if entity.get_attribute(CodexSketchupMcp::ATTRIBUTE_DICTIONARY, 'wall_spec')
    x = bounds.width.to_mm.round(2)
    y = bounds.height.to_mm.round(2)
    z = bounds.depth.to_mm.round(2)
    {
      entity_id: uuid || entity.persistent_id.to_s,
      entity_uuid: uuid,
      persistent_id: entity.persistent_id.to_s,
      managed: managed_entity?(entity),
      kind: kind,
      name: entity.name,
      bounds_mm: {
        x: x,
        y: y,
        z: z,
        width: x,
        depth: y,
        height: z
      }
    }
  end

  def add_face!(entities, points, label)
    face = entities.add_face(points)
    raise ArgumentError, "#{label} is invalid, degenerate, or self-intersecting" unless face

    face
  end

  def wall_layout(start_pt, end_pt, thickness, alignment)
    dx = end_pt.x - start_pt.x
    dy = end_pt.y - start_pt.y
    length = Math.sqrt((dx * dx) + (dy * dy))
    raise ArgumentError, 'Wall start and end must be different' if length < 0.001

    unit = Geom::Vector3d.new(dx / length, dy / length, 0)
    normal = Geom::Vector3d.new(-dy / length, dx / length, 0)
    outer_offset = case alignment.to_s
                   when 'center' then thickness / 2.0
                   when 'inside' then thickness
                   when 'outside' then 0.0
                   else
                     raise ArgumentError, "alignment must be center, inside, or outside (got #{alignment})"
                   end
    center_offset = outer_offset - (thickness / 2.0)
    {
      length: length,
      unit: unit,
      normal: normal,
      outer_start: start_pt.offset(normal, outer_offset),
      center_start: start_pt.offset(normal, center_offset),
      center_offset: center_offset
    }
  end

  def point_param(value, label)
    raise ArgumentError, "#{label} must be [x, y] or [x, y, z] in millimetres" unless value.is_a?(Array) && value.length.between?(2, 3)

    Geom::Point3d.new(mm(value[0], "#{label}[0]"), mm(value[1], "#{label}[1]"), mm(value[2] || 0, "#{label}[2]"))
  end

  def polygon_param(value)
    raise ArgumentError, 'points must contain at least three [x, y] coordinates' unless value.is_a?(Array) && value.length >= 3

    points = value.map.with_index { |point, index| point_param(point, "points[#{index}]") }
    points.pop if same_xy?(points.first, points.last)
    raise ArgumentError, 'points must contain at least three distinct coordinates' if points.length < 3
    points.each_with_index do |point, index|
      raise ArgumentError, 'points contains a repeated adjacent coordinate' if same_xy?(point, points[(index + 1) % points.length])
    end
    unique_points = points.uniq { |point| [point.x.round(6), point.y.round(6)] }
    raise ArgumentError, 'points must contain at least three distinct coordinates' if unique_points.length < 3
    raise ArgumentError, 'points must enclose a non-zero area' if signed_polygon_area(points).abs < 0.001
    validate_polygon_segments!(points)
    points
  end

  def same_xy?(left, right)
    (left.x - right.x).abs < 0.001 && (left.y - right.y).abs < 0.001
  end

  def signed_polygon_area(points)
    points.each_with_index.sum do |point, index|
      next_point = points[(index + 1) % points.length]
      (point.x * next_point.y) - (next_point.x * point.y)
    end / 2.0
  end

  def validate_polygon_segments!(points)
    count = points.length
    count.times do |left_index|
      left_end = (left_index + 1) % count
      (left_index + 1...count).each do |right_index|
        right_end = (right_index + 1) % count
        next if left_index == right_index || left_index == right_end || left_end == right_index || left_end == right_end
        next unless segments_intersect?(points[left_index], points[left_end], points[right_index], points[right_end])

        raise ArgumentError, 'points polygon is self-intersecting'
      end
    end
  end

  def segments_intersect?(a, b, c, d)
    first = orientation(a, b, c)
    second = orientation(a, b, d)
    third = orientation(c, d, a)
    fourth = orientation(c, d, b)
    return true if first.abs < 0.001 && point_on_segment?(a, b, c)
    return true if second.abs < 0.001 && point_on_segment?(a, b, d)
    return true if third.abs < 0.001 && point_on_segment?(c, d, a)
    return true if fourth.abs < 0.001 && point_on_segment?(c, d, b)

    (first.positive? != second.positive?) && (third.positive? != fourth.positive?)
  end

  def orientation(a, b, c)
    ((b.x - a.x) * (c.y - a.y)) - ((b.y - a.y) * (c.x - a.x))
  end

  def point_on_segment?(a, b, point)
    point.x.between?([a.x, b.x].min - 0.001, [a.x, b.x].max + 0.001) &&
      point.y.between?([a.y, b.y].min - 0.001, [a.y, b.y].max + 0.001)
  end

  def positive_mm(value, label)
    result = mm(value, label)
    raise ArgumentError, "#{label} must be greater than zero" unless result.positive?

    result
  end

  def nonnegative_mm(value, label)
    result = mm(value, label)
    raise ArgumentError, "#{label} must be zero or greater" if result.negative?

    result
  end

  def integer_param(value, label)
    numeric = finite_number(value, label)
    raise ArgumentError, "#{label} must be an integer" unless (numeric - numeric.round).abs < 1.0e-9

    numeric.to_i
  end

  def boolean_param(value, label)
    return value if value == true || value == false

    raise ArgumentError, "#{label} must be true or false"
  end

  def mm(value, label = 'value')
    numeric = finite_number(value, label)
    raise ArgumentError, "#{label} must be between -#{MAX_ABSOLUTE_MM.to_i} and #{MAX_ABSOLUTE_MM.to_i} millimetres" if numeric.abs > MAX_ABSOLUTE_MM

    numeric.round(1).mm
  end

  def finite_number(value, label)
    numeric = Float(value)
    raise ArgumentError, "#{label} must be a finite number" unless numeric.finite?

    numeric
  rescue ArgumentError, TypeError, FloatDomainError
    raise ArgumentError, "#{label} must be a finite number"
  end

  def normalise_identifier(value, label)
    identifier = value.to_s.strip
    raise ArgumentError, "#{label} must be a non-empty identifier" if identifier.empty?
    raise ArgumentError, "#{label} contains unsupported characters" unless identifier.match?(ENTITY_IDENTIFIER_PATTERN)

    identifier
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Plugins').add_submenu('Codex SketchUp MCP Port Bridge')
    menu.add_item('Start localhost server') { start }
    menu.add_item('Stop localhost server') { stop }
    file_loaded(__FILE__)
  end

  begin
    start
  rescue StandardError => e
    log("Autostart failed: #{e.class}: #{e.message}")
  end
end
