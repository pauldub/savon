# frozen_string_literal: true

require 'savon/header'
require 'savon/message'
require 'nokogiri'
require 'builder'
require 'gyoku'

module Savon
  class Builder
    attr_reader :multipart

    SCHEMA_TYPES = {
    }.freeze

    SOAP_NAMESPACE = {
      1 => 'http://schemas.xmlsoap.org/soap/envelope/',
      2 => 'http://www.w3.org/2003/05/soap-envelope'
    }.freeze

    WSA_NAMESPACE = 'http://www.w3.org/2005/08/addressing'

    def initialize(operation_name, wsdl, globals, locals)
      @operation_name = operation_name

      @wsdl      = wsdl
      @globals   = globals
      @locals    = locals
      @signature = @locals[:wsse_signature] || @globals[:wsse_signature]

      @types = convert_type_definitions_to_hash
      @used_namespaces = convert_type_namespaces_to_hash
    end

    def internal_namespaces
      @internal_namespaces ||= {}
    end

    def pretty
      Nokogiri.XML(to_s).to_xml(indent: 2)
    end

    def build_document
      xml_result = build_xml

      # if we have a signature sign the document
      if @signature
        @signature.document = xml_result

        2.times do
          @header = nil
          @signature.document = build_xml
        end

        xml_result = @signature.document
      end

      # if there are attachments for the request, we should build a multipart message according to
      # https://www.w3.org/TR/SOAP-attachments
      if @locals[:attachments]
        build_multipart_message(xml_result)
      else
        xml_result
      end
    end

    def header_attributes
      @globals[:use_wsa_headers] ? { 'xmlns:wsa' => WSA_NAMESPACE } : {}
    end

    def body_attributes
      @body_attributes ||= @signature.nil? ? {} : @signature.body_attributes
    end

    def to_s
      return @locals[:xml] if @locals.include? :xml

      build_document
    end

    private

    def convert_type_definitions_to_hash
      @wsdl.type_definitions.each_with_object({}) do |(path, type), memo|
        memo[path] = type
      end
    end

    def convert_type_namespaces_to_hash
      namespaces = @wsdl.type_namespaces.each_with_object({}) do |(path, uri), memo|
        key, value = use_namespace(path, uri)
        memo[key] = value
      end
      # Add the target namespace so it can be used if it is redefined by an imported xsd
      namespaces[[message_tag.to_s]] = namespace_identifier
      namespaces
    end

    def use_namespace(path, uri)
      @internal_namespace_count ||= 0

      unless identifier = internal_namespace_by_uri(uri)
        identifier = "ins#{@internal_namespace_count}"
        @internal_namespaces["xmlns:#{identifier}"] = uri
        @internal_namespace_count += 1
      end

      [path, identifier]
    end

    def namespaces_with_globals
      namespaces.merge @globals[:namespaces]
    end

    def namespaces
      @namespaces ||= begin
        namespaces = SCHEMA_TYPES.dup

        # check namespace_identifier
        namespaces["xmlns#{namespace_identifier.nil? ? '' : ":#{namespace_identifier}"}"] =
          target_namespace

        # check env_namespace
        namespaces["xmlns#{env_namespace && env_namespace != '' ? ":#{env_namespace}" : ''}"] =
          SOAP_NAMESPACE[@globals[:soap_version]]

        namespaces
      end
    end

    def target_namespace
      @globals[:namespace] || @wsdl.namespace
    end

    def env_namespace
      @env_namespace ||= @globals[:env_namespace] || :env
    end

    def header
      @header ||= Header.new(@globals, @locals)
    end

    def namespaced_message_tag
      tag_name = message_tag
      if @wsdl.document? && @wsdl.soap_input(@operation_name.to_sym).is_a?(Hash)
        return [tag_name]
      end

      internal_namespace = @used_namespaces[[tag_name.to_s]]
      if namespace_identifier.nil?
        [tag_name, message_attributes]
      elsif internal_namespace
        [internal_namespace, tag_name, message_attributes.merge(
          "xmlns:#{internal_namespace}" => internal_namespaces["xmlns:#{internal_namespace}"] || target_namespace
        )]
      else
        [namespace_identifier, tag_name, message_attributes.merge(
          "xmlns:#{namespace_identifier}" => target_namespace
        )]
      end
    end

    def serialized_message_tag
      [:wsdl, @wsdl.soap_input(@operation_name.to_sym).keys.first, {}]
    end

    def serialized_messages
      messages = ''
      message_tag = serialized_message_tag[1]
      @wsdl.soap_input(@operation_name.to_sym)[message_tag].each_pair do |message, type|
        break if @locals[:message].nil?

        message_locals = @locals[:message][message.snakecase.to_sym]
        message_content = Message.new(message_tag, namespace_identifier, @types, @used_namespaces, Hash[@wsdl.type_namespaces], target_namespace, message_locals, :unqualified, @globals[:convert_request_keys_to], @globals[:unwrap], @wsdl).to_s
        messages << "<#{message} xsi:type=\"#{type.join(':')}\">#{message_content}</#{message}>"
      end
      messages
    end

    def message_tag
      wsdl_tag_name = @wsdl.document? && @wsdl.soap_input(@operation_name.to_sym)

      message_tag = wsdl_tag_name.keys.first if wsdl_tag_name.is_a?(Hash)
      message_tag ||= @locals[:message_tag]
      message_tag ||= wsdl_tag_name
      message_tag ||= Gyoku.xml_tag(@operation_name, key_converter: @globals[:convert_request_keys_to])

      message_tag.to_sym
    end

    def message_attributes
      @locals[:attributes] || {}
    end

    def body_message
      if @wsdl.document? && @wsdl.soap_input(@operation_name.to_sym).is_a?(Hash)
        serialized_messages
      else
        message.to_s
      end
    end

    def message
      element_form_default = @globals[:element_form_default] || @wsdl.element_form_default
      # TODO: clean this up! [dh, 2012-12-17]
      Message.new(message_tag, namespace_identifier, @types, @used_namespaces, Hash[@wsdl.type_namespaces], target_namespace, @locals[:message],
                  element_form_default, @globals[:convert_request_keys_to], @globals[:unwrap])
    end

    def namespace_identifier
      if @globals.include? :namespace_identifier
        return @globals[:namespace_identifier]
      end
      return @namespace_identifier if @namespace_identifier

      operation = @wsdl.operations[@operation_name] if @wsdl.document?
      namespace_identifier = operation[:namespace_identifier] if operation
      namespace_identifier ||= 'wsdl'

      @namespace_identifier = namespace_identifier.to_sym
    end

    def internal_namespace_by_uri(uri)
      internal_namespaces.each do |candidate_identifier, candidate_uri|
        return candidate_identifier.gsub(/^xmlns:/, '') if candidate_uri == uri
      end
      nil
    end

    def builder
      builder = ::Builder::XmlMarkup.new
      builder.instruct!(:xml, encoding: @globals[:encoding])
      builder
    end

    def tag(xml, name, namespaces = {}, &block)
      if env_namespace && env_namespace != ''
        xml.tag! env_namespace, name, namespaces, &block
      else
        xml.tag! name, namespaces, &block
      end
    end

    def build_xml
      tag(builder, :Envelope, namespaces_with_globals) do |xml|
        unless header.empty?
          tag(xml, :Header, header_attributes) { xml << header.to_s }
        end
        tag(xml, :Body, body_attributes) do
          if @globals[:no_message_tag]
            xml << message.to_s
          else
            xml.tag!(*namespaced_message_tag) { xml << body_message }
          end
        end
      end
    end

    def build_multipart_message(message_xml)
      multipart_message = init_multipart_message(message_xml)
      add_attachments_to_multipart_message(multipart_message)

      multipart_message.ready_to_send!

      # the mail.body.encoded algorithm reorders the parts, default order is [ "text/plain", "text/enriched", "text/html" ]
      # should redefine the sort order, because the soap request xml should be the first
      multipart_message.body.set_sort_order ['text/xml']

      multipart_message.body.encoded(multipart_message.content_transfer_encoding)
    end

    def init_multipart_message(message_xml)
      multipart_message = Mail.new
      xml_part = Mail::Part.new do
        content_type 'text/xml'
        body message_xml
        # in Content-Type the start parameter is recommended (RFC 2387)
        content_id '<soap-request-body@soap>'
      end
      multipart_message.add_part xml_part

      # request.headers["Content-Type"] = "multipart/related; boundary=\"#{multipart_message.body.boundary}\"; type=\"text/xml\"; start=\"#{xml_part.content_id}\""
      @multipart = {
        multipart_boundary: multipart_message.body.boundary,
        start: xml_part.content_id
      }

      multipart_message
    end

    def add_attachments_to_multipart_message(multipart_message)
      if @locals[:attachments].is_a? Hash
        # hash example: { 'att1' => '/path/to/att1', 'att2' => '/path/to/att2' }
        @locals[:attachments].each do |identifier, attachment|
          add_attachment_to_multipart_message(multipart_message, attachment, identifier)
        end
      elsif @locals[:attachments].is_a? Array
        # array example: [ '/path/to/att1', '/path/to/att2' ]
        # array example: [ { filename: 'att1.xml', content: '<x/>' }, { filename: 'att2.xml', content: '<y/>' } ]
        @locals[:attachments].each do |attachment|
          add_attachment_to_multipart_message(multipart_message, attachment, attachment.is_a?(String) ? File.basename(attachment) : attachment[:filename])
        end
      end
    end

    def add_attachment_to_multipart_message(multipart_message, attachment, identifier)
      multipart_message.add_file attachment.clone
      multipart_message.parts.last.content_id = multipart_message.parts.last.content_location = identifier.to_s
    end
  end
end
