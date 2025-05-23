# frozen_string_literal: true

require 'excon'
require 'json'
require 'jsonpath'
require 'net/http'

module K8s
  # Excon-based HTTP transport handling request/response body JSON encoding
  class Transport
    include Logging

    quiet! # do not log warnings by default

    # Excon middlewares for requests
    EXCON_MIDDLEWARES = [
      # XXX: necessary? redirected requests omit authz headers?
      Excon::Middleware::RedirectFollower
    ] + Excon.defaults[:middlewares]

    # Default request headers
    REQUEST_HEADERS = {
      'Accept' => 'application/json'
    }.freeze

    # Min version of Kube API for which delete options need to be sent as request body
    DELETE_OPTS_BODY_VERSION_MIN = Gem::Version.new('1.11')

    # Construct transport from kubeconfig
    #
    # @param config [K8s::Config]
    # @param server [String] override cluster.server from config
    # @param overrides @see #initialize
    # @return [K8s::Transport]
    def self.config(config, server: nil, **overrides)
      options = {}

      server ||= config.cluster.server

      if config.cluster.insecure_skip_tls_verify
        logger.debug "Using config with .cluster.insecure_skip_tls_verify"

        options[:ssl_verify_peer] = false
      end

      if path = config.cluster.certificate_authority
        logger.debug "Using config with .cluster.certificate_authority"

        options[:ssl_ca_file] = path
      end

      if data = config.cluster.certificate_authority_data
        logger.debug "Using config with .cluster.certificate_authority_data"

        ssl_cert_store = options[:ssl_cert_store] = OpenSSL::X509::Store.new
        ssl_cert_store.add_cert(OpenSSL::X509::Certificate.new(Base64.decode64(data)))
      end

      if (cert = config.user.client_certificate) && (key = config.user.client_key)
        logger.debug "Using config with .user.client_certificate/client_key"

        options[:client_cert] = cert
        options[:client_key] = key
      end

      if (cert_data = config.user.client_certificate_data) && (key_data = config.user.client_key_data)
        logger.debug "Using config with .user.client_certificate_data/client_key_data"

        options[:client_cert_data] = Base64.decode64(cert_data)
        options[:client_key_data] = Base64.decode64(key_data)
      end

      if token = config.user.token
        logger.debug "Using config with .user.token=..."

        options[:auth_token] = token
      elsif config.user.auth_provider && auth_provider = config.user.auth_provider.config
        logger.debug "Using config with .user.auth-provider.name=#{config.user.auth_provider.name}"
        options[:auth_token] = token_from_auth_provider(auth_provider)
      elsif exec_conf = config.user.exec
        logger.debug "Using config with .user.exec.command=#{exec_conf.command}"
        options[:auth_token] = token_from_exec(exec_conf)
      elsif config.user.username && config.user.password
        logger.debug "Using config with .user.password=..."

        options[:auth_username] = config.user.username
        options[:auth_password] = config.user.password
      end

      logger.info "Using config with server=#{server}"

      new(server, **options, **overrides)
    end

    # @param auth_provider [K8s::Config::UserAuthProvider]
    # @return [String]
    def self.token_from_auth_provider(auth_provider)
      if auth_provider['id-token']
        auth_provider['id-token']
      else
        auth_data = `#{auth_provider['cmd-path']} #{auth_provider['cmd-args']}`.strip
        if auth_provider['token-key']
          json_path = JsonPath.new(auth_provider['token-key'][1...-1])
          json_path.first(auth_data)
        else
          auth_data
        end
      end
    end

    # @param exec_conf [K8s::Config::UserExec]
    # @return [String]
    def self.token_from_exec(exec_conf)
      cmd = [exec_conf.command]
      cmd += exec_conf.args if exec_conf.args
      orig_env = ENV.to_h
      if envs = exec_conf.env
        envs.each do |env|
          ENV[env['name']] = env['value']
        end
      end
      auth_json = `#{cmd.join(' ')}`.strip
      ENV.replace(orig_env)

      JSON.parse(auth_json).dig('status', 'token')
    end

    # In-cluster config within a kube pod, using the kubernetes service envs and serviceaccount secrets
    #
    # @param options [Hash] see #new
    # @return [K8s::Transport]
    # @raise [K8s::Error::Config] when the environment variables KUBERNETES_SEVICE_HOST and KUBERNETES_SERVICE_PORT_HTTPS are not set
    # @raise [Errno::ENOENT,Errno::EACCES] when /var/run/secrets/kubernetes.io/serviceaccount/ca.crt or /var/run/secrets/kubernetes.io/serviceaccount/token can not be read
    def self.in_cluster_config(**options)
      host = ENV['KUBERNETES_SERVICE_HOST'].to_s
      raise(K8s::Error::Configuration, "in_cluster_config failed: KUBERNETES_SERVICE_HOST environment not set") if host.empty?

      port = ENV['KUBERNETES_SERVICE_PORT_HTTPS'].to_s
      raise(K8s::Error::Configuration, "in_cluster_config failed: KUBERNETES_SERVICE_PORT_HTTPS environment not set") if port.empty?

      host_with_ipv6_brackets_if_needed = host.include?("::") ? "[#{host}]" : host

      new(
        "https://#{host_with_ipv6_brackets_if_needed}:#{port}",
        ssl_verify_peer: options.key?(:ssl_verify_peer) ? options.delete(:ssl_verify_peer) : true,
        ssl_ca_file: options.delete(:ssl_ca_file) || File.join((ENV['TELEPRESENCE_ROOT'] || '/'), 'var/run/secrets/kubernetes.io/serviceaccount/ca.crt'),
        auth_token: options.delete(:auth_token) || File.read(File.join((ENV['TELEPRESENCE_ROOT'] || '/'), 'var/run/secrets/kubernetes.io/serviceaccount/token')),
        **options
      )
    end

    attr_reader :server, :options, :path_prefix

    # @param server [String] URL with protocol://host:port (paths are preserved as well)
    # @param auth_token [String] optional Authorization: Bearer token
    # @param auth_username [String] optional Basic authentication username
    # @param auth_password [String] optional Basic authentication password
    # @param options [Hash] @see Excon.new
    def initialize(server, auth_token: nil, auth_username: nil, auth_password: nil, **options)
      uri = URI.parse(server)
      @server = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      @path_prefix = File.join('/', uri.path, '/') # add leading and/or trailing slashes
      @auth_token = auth_token
      @auth_username = auth_username
      @auth_password = auth_password
      @options = options

      logger! progname: @server
    end

    # @return [Excon::Connection]
    def excon
      @excon ||= build_excon
    end

    # @return [Excon::Connection]
    def build_excon
      Excon.new(
        @server,
        persistent: true,
        middlewares: EXCON_MIDDLEWARES,
        headers: REQUEST_HEADERS,
        **@options
      )
    end

    # @param parts [Array<String>] join path parts together to build the full URL
    # @return [String]
    def path(*parts)
      joined_parts = File.join(*parts)
      joined_parts.start_with?(path_prefix) ? joined_parts : File.join(path_prefix, joined_parts)
    end

    # @param request_object [Object] include request body using to_json
    # @param content_type [String] request body content-type
    # @param options [Hash] @see Excon#request
    # @return [Hash]
    def request_options(request_object: nil, content_type: 'application/json', **options)
      options[:headers] ||= {}

      if @auth_token
        options[:headers]['Authorization'] = "Bearer #{@auth_token}"
      elsif @auth_username && @auth_password
        options[:headers]['Authorization'] = "Basic #{Base64.strict_encode64("#{@auth_username}:#{@auth_password}")}"
      end

      if request_object
        options[:headers]['Content-Type'] = content_type
        options[:body] = request_object.to_json
      end

      options
    end

    # @param options [Hash] as passed to Excon#request
    # @return [String]
    def format_request(options)
      method = options[:method]
      path = options[:path]
      body = nil

      if options[:query]
        path += Excon::Utils.query_string(options)
      end

      if obj = options[:request_object]
        body = "<#{obj.class.name}>"
      end

      [method, path, body].compact.join " "
    end

    # @param response [Hash] as returned by Excon#request
    # @param request_options [Hash] as passed to Excon#request
    # @param response_class [Class] coerce into response body using #new
    # @raise [K8s::Error]
    # @raise [Excon::Error] TODO: wrap
    # @return [response_class, Hash]
    def parse_response(response, request_options, response_class: nil)
      method = request_options[:method]
      path = request_options[:path]
      content_type = response.headers['Content-Type']&.split(';', 2)&.first

      case content_type
      when 'application/json'
        response_data = Yajl::Parser.parse(response.body)

      when 'text/plain'
        response_data = response.body # XXX: broken if status 2xx
      else
        raise K8s::Error::API.new(method, path, response.status, "Invalid response Content-Type: #{response.headers['Content-Type'].inspect}")
      end

      if response.status.between? 200, 299
        return response_data if content_type == 'text/plain'

        unless response_data.is_a? Hash
          raise K8s::Error::API.new(method, path, response.status, "Invalid JSON response: #{response_data.inspect}")
        end

        return response_data unless response_class

        response_class.new(response_data)
      else
        error_class = K8s::Error::HTTP_STATUS_ERRORS[response.status] || K8s::Error::API

        if response_data.is_a?(Hash) && response_data['kind'] == 'Status'
          status = K8s::API::MetaV1::Status.new(response_data)

          raise error_class.new(method, path, response.status, response.reason_phrase, status)
        elsif response_data
          raise error_class.new(method, path, response.status, "#{response.reason_phrase}: #{response_data}")
        else
          raise error_class.new(method, path, response.status, response.reason_phrase)
        end
      end
    end

    # @param response_class [Class] coerce into response class using #new
    # @param options [Hash] @see Excon#request
    # @return [response_class, Hash]
    def request(response_class: nil, **options)
      if options[:method] == 'DELETE' && need_delete_body?
        options[:request_object] = options.delete(:query)
      end

      excon_options = request_options(**options)

      # Set up proper streaming configuration for streaming endpoints
      if options[:response_block]
        # For streaming responses, ensure we use unbuffered reads
        excon_options[:response_block] = options[:response_block]
        excon_options[:middlewares] = EXCON_MIDDLEWARES
        excon_options[:persistent] = false # Don't use persistent connection for streaming
        excon_options[:read_timeout] = options[:read_timeout] || 60 # Default timeout for streaming
      end

      start = Time.now

      # Use a fresh connection for streaming requests to avoid any buffering issues
      excon_client = options[:response_block] ? build_excon : excon

      response = excon_client.request(**excon_options)
      t = Time.now - start

      obj = options[:response_block] ? {} : parse_response(response, options, response_class: response_class)
    rescue K8s::Error::API => e
      logger.warn { "#{format_request(options)} => HTTP #{e.code} #{e.reason} in #{format('%<time>.3f', time: t)}s" }
      logger.debug { "Request: #{excon_options[:body]}" } if excon_options[:body]
      logger.debug { "Response: #{response.body}" } if response&.body
      raise
    else
      logger.info { "#{format_request(options)} => HTTP #{response.status}: <#{obj.class}> in #{format('%<time>.3f', time: t)}s" }
      logger.debug { "Request: #{excon_options[:body]}" } if excon_options[:body]
      logger.debug { "Response: #{response.body}" } if response&.body && !options[:response_block]
      obj
    end

    # @param options [Array<Hash>] @see #request
    # @param skip_missing [Boolean] return nil for HTTP 404 responses
    # @param skip_forbidden [Boolean] return nil for HTTP 403 responses
    # @param retry_errors [Boolean] retry with non-pipelined request for HTTP 503 responses
    # @param common_options [Hash] @see #request, merged with the per-request options
    # @return [Array<response_class, Hash, NilClass>]
    def requests(*options, skip_missing: false, skip_forbidden: false, retry_errors: true, **common_options)
      return [] if options.empty? # excon chokes

      start = Time.now
      responses = excon.requests(
        options.map{ |opts| request_options(**common_options.merge(opts)) }
      )
      t = Time.now - start

      objects = responses.zip(options).map{ |response, request_options|
        response_class = request_options[:response_class] || common_options[:response_class]

        begin
          parse_response(response, request_options,
                         response_class: response_class)
        rescue K8s::Error::NotFound
          raise unless skip_missing

          nil
        rescue K8s::Error::Forbidden
          raise unless skip_forbidden

          nil
        rescue K8s::Error::ServiceUnavailable => e
          raise unless retry_errors

          logger.warn { "Retry #{format_request(request_options)} => HTTP #{e.code} #{e.reason} in #{format('%<time>.3f', time: t)}s" }

          # only retry the failed request, not the entire pipeline
          request(response_class: response_class, **common_options.merge(request_options))
        end
      }
    rescue K8s::Error => e
      logger.warn { "[#{options.map{ |o| format_request(o) }.join ', '}] => HTTP #{e.code} #{e.reason} in #{format('%<time>.3f', time: t)}s" }
      raise
    else
      logger.info { "[#{options.map{ |o| format_request(o) }.join ', '}] => HTTP [#{responses.map(&:status).join ', '}] in #{format('%<time>.3f', time: t)}s" }
      objects
    end

    # @return [K8s::API::Version]
    def version
      @version ||= get(
        '/version',
        response_class: K8s::API::Version
      )
    end

    # @return [Boolean] true if delete options should be sent as bode of the DELETE request
    def need_delete_body?
      @need_delete_body ||= Gem::Version.new(version.gitVersion.match(/^v*((\d|\.)*)/)[1]) < DELETE_OPTS_BODY_VERSION_MIN
    end

    # @param path [Array<String>] @see #path
    # @param options [Hash] @see #request
    # @return [Array<response_class, Hash, NilClass>]
    def get(*path, **options)
      options = options.merge({ method: 'GET', path: self.path(*path) })
      request(**options)
    end

    # @param paths [Array<String>]
    # @param options [Hash] @see #request
    # @return [Array<response_class, Hash, NilClass>]
    def gets(*paths, **options)
      requests(
        *paths.map do |path|
          {
            method: 'GET',
            path: self.path(path)
          }
        end,
        **options
      )
    end

    # Returns a websocket connection using part of the current transport configuration.
    # Will use same host and port returned by #server.
    # @param resource_path [String]
    # @param query [Hash]
    # @return [Faye::WebSocket::Client]
    def build_ws_conn(resource_path, query = {})
      private_key_file = nil
      cert_chain_file = nil

      on_open_callbacks = []

      if options[:client_cert] && options[:client_key]
        private_key_file = options[:client_key]
        cert_chain_file = options[:client_cert]
      elsif options[:client_cert_data] && options[:client_key_data]
        temp_file_path_from_data = lambda do |data|
          temp_file = Tempfile.new
          temp_file.write(data)
          temp_file.close
          on_open_callbacks << -> { temp_file.unlink }
          temp_file.path
        end
        private_key_file = temp_file_path_from_data.call(options[:client_key_data])
        cert_chain_file = temp_file_path_from_data.call(options[:client_cert_data])
      end

      url = server.gsub("http", "ws") +
            resource_path +
            Excon::Utils.query_string(query: query)

      ws = Faye::WebSocket::Client.new(
        url,
        [],
        headers: request_options[:headers],
        tls: {
          verify_peer: !!options[:ssl_verify_peer],
          private_key_file: private_key_file,
          cert_chain_file: cert_chain_file
        }
      )

      ws.on(:open) { on_open_callbacks.each(&:call) }
      ws
    end
  end
end
