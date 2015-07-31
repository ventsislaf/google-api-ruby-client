# Copyright 2015 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Copyright 2015 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'hurley'
require 'google/apis/core/multipart'
require 'google/apis/core/http_command'
require 'google/apis/core/upload'
require 'google/apis/core/download'
require 'addressable/uri'

module Google
  module Apis
    module Core
      # Wrapper request for batching multiple calls in a single server request
      class BatchCommand < HttpCommand
        BATCH_BOUNDARY = 'RubyApiBatchRequest'.freeze
        MULTIPART_MIXED = 'multipart/mixed'

        # @param [symbol] method
        #   HTTP method
        # @param [String,Addressable::URI, Addressable::Template] url
        #   HTTP URL or template
        def initialize(method, url)
          super(method, url)
          @calls = []
        end

        ##
        # Add a new call to the batch request.
        #
        # @param [Google::Apis::Core::HttpCommand] call API Request to add
        # @yield [result, err] Result & error when response available
        # @return [Google::Apis::Core::BatchCommand] self
        def add(call, &block)
          ensure_valid_command(call)
          @calls << [call, block]
          self
        end

        protected

        ##
        # Deconstruct the batch response and process the individual results
        #
        # @param [String] content_type
        #  Content type of body
        # @param [String, #read] body
        #  Response body
        # @return [Object]
        #   Response object
        def decode_response_body(content_type, body)
          m = /.*boundary=(.+)/.match(content_type)
          if m
            parts = split_parts(body, m[1])
            deserializer = CallDeserializer.new
            parts.each_index do |index|
              call, callback = @calls[index]
              begin
                result = call.process_response(*deserializer.to_http_response(parts[index])) unless call.nil?
                success(result, &callback)
              rescue => e
                error(e, &callback)
              end
            end
          end
          nil
        end

        def split_parts(body, boundary)
          parts = body.split(/\r?\n?--#{Regexp.escape(boundary)}/)
          parts[1...-1]
        end

        # Encode the batch request
        # @return [void]
        # @raise [Google::Apis::BatchError] if batch is empty
        def prepare!
          fail BatchError, 'Cannot make an empty batch request' if @calls.empty?

          serializer = CallSerializer.new
          multipart = Multipart.new(boundary: BATCH_BOUNDARY, content_type: MULTIPART_MIXED)
          @calls.each do |(call, _)|
            io = serializer.to_upload_io(call)
            multipart.add_upload(io)
          end
          self.body = multipart.assemble

          header[:content_type] = multipart.content_type
          header[:content_length] = "#{body.length}"
          super
        end

        def ensure_valid_command(command)
          if command.is_a?(Google::Apis::Core::BaseUploadCommand) || command.is_a?(Google::Apis::Core::DownloadCommand)
            fail Google::Apis::ClientError, 'Can not include media requests in batch'
          end
          fail Google::Apis::ClientError, 'Invalid command object' unless command.is_a?(HttpCommand)
        end
      end

      # Wrapper request for batching multiple uploads in a single server request
      class BatchUploadCommand < BatchCommand
        def ensure_valid_command(command)
          fail Google::Apis::ClientError, 'Can only include upload commands in batch' \
            unless command.is_a?(Google::Apis::Core::BaseUploadCommand)
        end

        def prepare!
          header['X-Goog-Upload-Protocol'] = 'batch'
          super
        end
      end

      # Serializes a command for embedding in a multipart batch request
      # @private
      class CallSerializer
        HTTP_CONTENT_TYPE = 'application/http'

        ##
        # Serialize a single batched call for assembling the multipart message
        #
        # @param [Google::Apis::Core::HttpCommand] call
        #   the call to serialize.
        # @return [Hurley::UploadIO]
        #   the serialized request
        def to_upload_io(call)
          call.prepare!
          parts = []
          parts << build_head(call)
          parts << build_body(call) unless call.body.nil?
          length = parts.inject(0) { |a, e| a + e.length }
          Hurley::UploadIO.new(Hurley::CompositeReadIO.new(length, *parts),
                               HTTP_CONTENT_TYPE,
                               'ruby-api-request')
        end

        protected

        def build_head(call)
          request_head = "#{call.method.to_s.upcase} #{Addressable::URI.parse(call.url).request_uri} HTTP/1.1"
          call.header.each do |key, value|
            request_head << sprintf("\r\n%s: %s", key, value)
          end
          request_head << sprintf("\r\nHost: %s", call.url.host)
          request_head << "\r\n\r\n"
          StringIO.new(request_head)
        end

        def build_body(call)
          return nil if call.body.nil?
          return call.body if call.body.respond_to?(:read)
          StringIO.new(call.body)
        end
      end

      # Deconstructs a raw HTTP response part
      # @private
      class CallDeserializer
        # Convert a single batched response into a BatchedCallResponse object.
        #
        # @param [String] call_response
        #   the response to parse.
        # @return [Array<(Fixnum, Hurley::Header, String)>]
        #   Status, header, and response body.
        def to_http_response(call_response)
          _, outer_body = split_header_and_body(call_response)
          status_line, payload = outer_body.split(/\n/, 2)
          _, status = status_line.split(' ', 3)

          header, body = split_header_and_body(payload)
          [status.to_i, header, body]
        end

        protected

        # Auxiliary method to split the header from the body in an HTTP response.
        #
        # @param [String] response
        #   the response to parse.
        # @return [Array<(Hurley::Header, String)>]
        #   the header and the body, separately.
        def split_header_and_body(response)
          header = Hurley::Header.new
          payload = response.lstrip
          while payload
            line, payload = payload.split(/\n/, 2)
            line.sub!(/\s+\z/, '')
            break if line.empty?
            match = /\A([^:]+):\s*/.match(line)
            fail BatchError, sprintf('Invalid header line in response: %s', line) if match.nil?
            header[match[1]] = match.post_match
          end
          [header, payload]
        end
      end
    end
  end
end