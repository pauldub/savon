# frozen_string_literal: true

require 'gyoku'

module Savon
  class QualifiedMessage
    def initialize(types, used_namespaces, type_namespaces, target_namespace, key_converter)
      @types           = types
      @used_namespaces = used_namespaces
      @type_namespaces = type_namespaces
      @target_namespace = target_namespace
      @key_converter = key_converter
    end

    def to_hash(hash, path, parent_namespace = nil)
      return hash unless hash

      if hash.is_a?(Array)
        return hash.map do |value|
          to_hash(value, path, parent_namespace)
        end
      end

      return { content!: hash.to_s } unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), newhash|
        case key
        when :order!
          newhash[key] = add_namespaces_to_values(value, path)
        when :attributes!, :content!
          newhash[key] = to_hash(value, path)
        else
          if key.to_s =~ /!$/
            newhash[key] = value
          else
            translated_key = translate_tag(key)
            newkey = add_namespaces_to_values(key, path).first
            newpath = path + [translated_key]

            # Do not add namespace prefix to tags directly below the message that are also in the target namespace.
            if @target_namespace == @type_namespaces[newpath] && parent_namespace.nil?
              newhash[translated_key] = to_hash(value, @types[newpath] ? [@types[newpath]] : newpath, @type_namespaces[newpath])
            # If the tag namespace differs from its parent, add the xmlns attribute targeting the new namespace
            elsif parent_namespace != @type_namespaces[newpath]
              newhash[newkey] = { "@xmlns:#{@used_namespaces[newpath]}".to_sym => @type_namespaces[newpath], content!: to_hash(value, @types[newpath] ? [@types[newpath]] : newpath, @type_namespaces[newpath]) }
            # Otherwise only use the namespace identifier
            else
              newhash[newkey] = to_hash(value, @types[newpath] ? [@types[newpath]] : newpath, @type_namespaces[newpath])
            end
          end
        end
        newhash
      end
    end

    private

    def translate_tag(key)
      Gyoku.xml_tag(key, key_converter: @key_converter).to_s
    end

    def add_namespaces_to_values(values, path)
      Array(values).collect do |value|
        translated_value = translate_tag(value)
        namespace_path   = path + [translated_value]
        namespace        = @used_namespaces[namespace_path]
        namespace.blank? ? value : "#{namespace}:#{translated_value}"
      end
    end
  end
end
