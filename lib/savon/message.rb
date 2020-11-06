# frozen_string_literal: true

require 'savon/qualified_message'
require 'gyoku'

module Savon
  class Message
    def initialize(message_tag, namespace_identifier, types, used_namespaces, type_namespaces, target_namespace, message, element_form_default, key_converter, unwrap)
      @message_tag = message_tag
      @namespace_identifier = namespace_identifier
      @types = types
      @used_namespaces = used_namespaces
      @type_namespaces = type_namespaces
      @target_namespace = target_namespace

      @message = message
      @element_form_default = element_form_default
      @key_converter = key_converter
      @unwrap = unwrap
    end

    def to_s
      return @message.to_s unless @message.is_a? Hash

      if @element_form_default == :qualified
        @message = QualifiedMessage.new(@types, @used_namespaces, @type_namespaces, @target_namespace, @key_converter).to_hash(@message, [@message_tag.to_s])
      end

      gyoku_options = {
        element_form_default: @element_form_default,
        key_converter: @key_converter,
        unwrap: @unwrap
      }

      if @element_form_default != :qualified
        gyoku_options[:namespace] = @namespace_identifier
      end

      Gyoku.xml(@message, gyoku_options)
    end
  end
end
