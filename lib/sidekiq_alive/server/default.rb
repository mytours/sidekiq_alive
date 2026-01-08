# frozen_string_literal: true

require_relative "http_server"
require_relative "base"

module SidekiqAlive
  module Server
    class Default < HttpServer
      extend Base

      class << self
        def run!
          logger.info("[SidekiqAlive] Starting default healthcheck server on #{host}:#{port}")
          @server_pid = ::Process.fork do
            @server = new(port, host, path)
            # stop is wrapped in a thread because gserver calls synchrnonize which raises an error when in trap context
            configure_shutdown_signal { Thread.new { @server.stop } }
            configure_quiet_signal { @server.quiet! }

            @server.start
            @server.join
          end
          configure_shutdown
          logger.info("[SidekiqAlive] Web server started in subprocess with pid #{@server_pid}")

          self
        end
      end

      def initialize(port, host, path, logger = SidekiqAlive.logger)
        super(self, port, host, logger)

        @path = path
      end

      def request_handler(req, res)
        if req.path != path
          res.status = 404
          res.body = "Not found"
          return logger.warn("[SidekiqAlive] Path '#{req.path}' not found")
        end

        if quiet?
          res.status = 200
          res.body = "Server is shutting down"
          return logger.debug("[SidekiqAlive] Server in quiet mode, skipping alive key lookup!")
        end

        if slow_job_processing?
          res.status = 503
          res.body = "Service Unavailable"
          return logger.debug("[SidekiqAlive] Slow job processing, skipping alive key lookup!")
        end

        if SidekiqAlive.alive?
          res.status = 200
          res.body = "Alive!"
          return logger.debug("[SidekiqAlive] Found alive key!")
        end

        response = "Can't find the alive key"
        res.status = 404
        res.body = response
        logger.error("[SidekiqAlive] #{response}")
      rescue StandardError => e
        response = "Internal Server Error"
        res.status = 500
        res.body = response
        logger.error("[SidekiqAlive] #{response} looking for alive key. Error: #{e.message}")
      end

      def quiet!
        @quiet = Time.now
      end

      private

      attr_reader :path

      def quiet?
        @quiet && (Time.now - @quiet) < SidekiqAlive.config.quiet_timeout
      end

      def slow_job_processing?
        limit = 3600 # 1 hour

        processes = Sidekiq::ProcessSet.new
        hostname = ENV.fetch("HOSTNAME")
        current_process = processes.find { |p| p["hostname"] == hostname }

        return false if current_process.blank?

        identity = current_process["identity"]

        workers = Sidekiq::Workers.new
        workers.each do |process_id, thread_id, work|
          next unless process_id == identity

          if (Time.now - work.run_at) >= limit
            payload = JSON.parse(work.payload)
            logger.info("[SidekiqAlive] Job running for more than an hour: #{payload["class"]} - #{payload["args"]}")

            return true
          end
        end

        false
      end
    end
  end
end
