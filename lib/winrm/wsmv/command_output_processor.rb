# -*- encoding: utf-8 -*-
#
# Copyright 2016 Shawn Neal <sneal@sneal.net>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative 'soap'
require_relative 'header'
require_relative 'command_output_decoder'
require_relative '../output'

module WinRM
  module WSMV
    # Class to handle getting all the output of a command until it completes
    class CommandOutputProcessor
      include WinRM::WSMV::SOAP
      include WinRM::WSMV::Header

      # Creates a new command output processor
      # @param connection_opts [ConnectionOpts] The WinRM connection options
      # @param transport [HttpTransport] The WinRM SOAP transport
      # @param out_opts [Hash] Additional output options
      def initialize(connection_opts, transport, logger, out_opts = {})
        @connection_opts = connection_opts
        @transport = transport
        @out_opts = out_opts
        @logger = logger
        @output_decoder = CommandOutputDecoder.new
      end

      attr_reader :logger

      # Gets the command output from the remote shell
      # @param shell_id [UUID] The remote shell id running the command
      # @param command_id [UUID] The command id to get output for
      # @param block Optional callback for any output
      def command_output(shell_id, command_id, &block)
        output = WinRM::Output.new
        logger.debug("[WinRM] Retrieving output for command id: #{command_id}")
        message_output(command_output_message(shell_id, command_id)) do |stream, doc|
          handled_out = handle_stream(stream, output, doc)
          yield handled_out if handled_out && block
        end
        output[:exitcode] ||= 0
        output
      end

      def message_output(wsmv_message, wait_for_done_state = false, &block)
        resp_doc = nil
        until command_done?(resp_doc, wait_for_done_state)
          logger.debug("[WinRM] Waiting for output...")
          resp_doc = send_get_output_message(wsmv_message.build)
          logger.debug("[WinRM] Processing output")
          read_streams(resp_doc) do |stream|
            yield stream, resp_doc
          end
        end
      end

      protected

      def handle_stream(stream, output, resp_doc)
        decoded_text = @output_decoder.decode(stream[:text])
        return unless decoded_text

        out = { stream[:type] => decoded_text }
        output[:data] << out
        output[:exitcode] ||= exit_code(resp_doc)
        [out[:stdout], out[:stderr]]
      end

      def command_output_message(shell_id, command_id)
        cmd_out_opts = {
          shell_id: shell_id,
          command_id: command_id
        }.merge(@out_opts)
        WinRM::WSMV::CommandOutput.new(@connection_opts, cmd_out_opts)
      end

      def send_get_output_message(message)
        @transport.send_request(message)
      rescue WinRMWSManFault => e
        # If no output is available before the wsman:OperationTimeout expires,
        # the server MUST return a WSManFault with the Code attribute equal to
        # 2150858793. When the client receives this fault, it SHOULD issue
        # another Receive request.
        # http://msdn.microsoft.com/en-us/library/cc251676.aspx
        raise unless e.fault_code == '2150858793'

        logger.debug('[WinRM] retrying receive request after timeout')
        retry
      end

      def exit_code(resp_doc)
        REXML::XPath.first(resp_doc, "//#{NS_WIN_SHELL}:ExitCode").text.to_i
      end

      def command_done?(resp_doc, wait_for_done_state)
        return false unless resp_doc
        return true unless wait_for_done_state

        REXML::XPath.match(
          resp_doc,
          "//*[@State='http://schemas.microsoft.com/wbem/wsman/1/windows/shell/" \
          "CommandState/Done']").any?
      end

      def read_streams(response_document)
        REXML::XPath.match(response_document, "//#{NS_WIN_SHELL}:Stream").each do |stream|
          next if stream.text.nil? || stream.text.empty?
          yield type: stream.attributes['Name'].to_sym, text: stream.text
        end
      end
    end
  end
end
