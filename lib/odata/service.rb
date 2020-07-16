module OData
  class Service
    attr_reader :base_url
    attr_reader :metadata
    attr_writer :auth_callback

    def initialize(options = {}, &block)
      @api_version   = {
        'api-version': options[:api_version]
      } if options[:api_version]
      @auth_callback = options[:auth_callback] || block
      @base_url      = options[:base_url]
      @metadata_file = options[:metadata_file]
      @type_name_map = {}
      @metadata      = fetch_metadata
      populate_types_from_metadata
    end
    
    def release_metadata
      @metadata = nil
    end

    def inspect
      "#<#{self.class} #{base_url}>"
    end

    def get(path, *select_properties)
      camel_case_select_properties = select_properties.map do |prop|
        OData.convert_to_camel_case(prop)
      end

      if ! camel_case_select_properties.empty?
        encoded_select_properties = URI.encode_www_form(
          '$select' => camel_case_select_properties.join(',')
        )
        path = "#{path}?#{encoded_select_properties}"
      end

      response = request(
        method: :get,
        uri: "#{base_url}#{path}"
      )
      {type: get_type_for_odata_response(response), attributes: response}
    end

    def delete(path)
      request(
        method: :delete,
        uri: "#{base_url}#{path}"
      )
    end

    def post(path, data)
      request(
        method: :post,
        uri: "#{base_url}#{path}",
        data: data
      )
    end

    def patch(path, data)
      request(
        method: :patch,
        uri: "#{base_url}#{path}",
        data: data
      )
    end

    def request(options = {})
      uri = options[:uri]

      if @api_version then
        parsed_uri = URI(uri)
        params = URI.decode_www_form(parsed_uri.query || '')
                    .concat(@api_version.to_a)
        parsed_uri.query = URI.encode_www_form params
        uri = parsed_uri.to_s
      end

      req = Request.new(options[:method], uri, options[:data])
      @auth_callback.call(req) if @auth_callback
      req.perform
    end

    def namespaces
      @namespaces ||= begin
        nspaces = []
        metadata.xpath("//Schema").map do |schema|
          nspaces << {namespace: schema["Namespace"], alias: schema["Alias"]}
        end
        nspaces
      end
    end
    
    def complex_types
      @complex_types ||= metadata.xpath("//ComplexType").map do |complex_type|
        schema_node = complex_type.parent
        raise MicrosoftGraph::NonNullableError("No schema node for #{complex_type}") if schema_node.nil? || schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        base_type = schema_type(schema_node, complex_type["BaseType"])
        @type_name_map["#{namespace}.#{complex_type["Name"]}"] = ComplexType.new(
          name:                  "#{namespace}.#{complex_type["Name"]}",
          base_type:             base_type,
          service:               self,
        )
      end
    end
    
    def entity_types
      @entity_types ||= metadata.xpath("//EntityType").map do |entity|
        schema_node = entity.parent
        raise MicrosoftGraph::NonNullableError("No schema node for #{entity}") if schema_node.nil? || schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        base_type = schema_type(schema_node, entity["BaseType"])
        options = {
          name:                  "#{namespace}.#{entity["Name"]}",
          abstract:              entity["Abstract"] == "true",
          base_type:             base_type,
          open_type:             entity["OpenType"] == "true",
          has_stream:            entity["HasStream"] == "true",
          service:               self,
        }
        @type_name_map["#{namespace}.#{entity["Name"]}"] = EntityType.new(options)
      end
    end

    def enum_types
      @enum_types ||= metadata.xpath("//EnumType").map do |type|
        schema_node = type.parent
        raise "no schema node #{schema_node.name}" if schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        members = type.xpath("./Member").map do |m, i|
          value = m['Value'] && m['Value'].to_i || i
          {
            name:  m["Name"],
            value: value,
          }
        end
        @type_name_map["#{namespace}.#{type["Name"]}"] = EnumType.new({name: "#{namespace}.#{type["Name"]}", members: members})
      end
    end

    def actions
      metadata.xpath("//Action").map do |action|
        build_operation(action)
      end
    end

    def functions
      metadata.xpath("//Function").map do |function|
        build_operation(function)
      end
    end

    def populate_primitive_types
      @type_name_map.merge!(
        "Edm.Binary"         => OData::BinaryType.new,
        "Edm.Date"           => OData::DateType.new,
        "Edm.Double"         => OData::DoubleType.new,
        "Edm.Guid"           => OData::GuidType.new,
        "Edm.Int16"          => OData::Int16Type.new,
        "Edm.Int32"          => OData::Int32Type.new,
        "Edm.Int64"          => OData::Int64Type.new,
        "Edm.Stream"         => OData::StreamType.new,
        "Edm.String"         => OData::StringType.new,
        "Edm.Boolean"        => OData::BooleanType.new,
        "Edm.DateTimeOffset" => OData::DateTimeOffsetType.new,
        "Edm.Duration"       => OData::DurationType.new,
        "Edm.TimeOfDay"      => OData::TimeOfDayType.new,
        "Edm.Byte"           => OData::ByteType.new,
        "Edm.SByte"          => OData::SByteType.new,
        "Edm.Decimal"        => OData::DecimalType.new,
        "Edm.Single"         => OData::SingleType.new,
      )
    end

    def singletons
      @singletons ||= metadata.xpath("//Singleton").map do |singleton|
        schema_node = singleton.parent.parent
        raise MicrosoftGraph::NonNullableError("No schema node for #{singleton}") if schema_node.nil? || schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        type = schema_type(schema_node, singleton["Type"])
        Singleton.new(
          name:    singleton["Name"],
          type:    type,
          service: self
        )
      end
    end

    def entity_sets
      @entity_sets ||= metadata.xpath("//EntitySet").map do |entity_set|
        EntitySet.new(
          name:        entity_set["Name"],
          member_type: entity_set["EntityType"],
          service:     self
        )
      end
    end

    def get_type_for_odata_response(parsed_response)
      if odata_type_string = parsed_response["@odata.type"]
        get_type_by_name(type_name_from_odata_type_field(odata_type_string))
      elsif context = parsed_response["@odata.context"]
        singular, segments = segments_from_odata_context_field(context)
        first_entity_type = get_type_by_name("Collection(#{entity_set_by_name(segments.shift).member_type})")
        entity_type = segments.reduce(first_entity_type) do |last_entity_type, segment|
          if last_entity_type.is_a?(CollectionType)
            last_entity_type.member_type.navigation_property_by_name(segment).type
          else
            last_entity_type
          end
        end
        singular && entity_type.respond_to?(:member_type) ? entity_type.member_type : entity_type
      end
    end

    def get_type_by_name(type_name)
      @type_name_map[type_name] || build_collection(type_name)
    end

    def entity_set_by_name(name)
      entity_sets.find { |entity_set| entity_set.name == name }
    end

    def properties_for_type(type_name)
      raw_type_name = remove_namespace(type_name)
      type_definition = metadata.xpath("//EntityType[@Name='#{raw_type_name}']|//ComplexType[@Name='#{raw_type_name}']")
      type_definition.xpath("./Property").map do |property|
        schema_node = property.parent.parent
        raise MicrosoftGraph::NonNullableError("No schema node for #{property}") if schema_node.nil? || schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        type = schema_type(schema_node, property["Type"])
        options = {
          name:      property["Name"],
          nullable:  property["Nullable"] != "false",
          type:      get_type_by_name(type),
        }
        OData::Property.new(options)
      end
    end

    def navigation_properties_for_type(type_name)
      raw_type_name = remove_namespace(type_name)
      type_definition = metadata.xpath("//EntityType[@Name='#{raw_type_name}']|//ComplexType[@Name='#{raw_type_name}']")
      type_definition.xpath("./NavigationProperty").map do |property|
        schema_node = property.parent.parent
        raise MicrosoftGraph::NonNullableError("No schema node for #{property}") if schema_node.nil? || schema_node.name != "Schema"
        namespace = schema_node["Namespace"]
        type = schema_type(schema_node, property["Type"])
        options = {
          name:            property["Name"],
          nullable:        property["Nullable"] != "false",
          type:            get_type_by_name(type),
          contains_target: property["ContainsTarget"],
          partner:         property["Partner"],
        }
        OData::NavigationProperty.new(options)
      end
    end

    private

    def type_name_from_odata_type_field(odata_type_field)
      odata_type_field.sub("#", '')
    end

    def segments_from_odata_context_field(odata_context_field)
      segments = odata_context_field.split("$metadata#").last.split("/").map { |s| s.split("(").first }
      segments.pop if singular = segments.last == "$entity"
      [singular, segments]
    end

    def populate_types_from_metadata      
      enum_types
      populate_primitive_types
      complex_types
      entity_types
    end

    def fetch_metadata
      response = if @metadata_file
        File.read(@metadata_file)
      else # From a URL
        uri = URI("#{base_url}$metadata?detailed=true")
        Net::HTTP
          .new(uri.hostname, uri.port)
          .tap { |h| h.use_ssl = uri.scheme == "https" }
          .get(uri).body
      end
      ::Nokogiri::XML(response).remove_namespaces!
    end

    def build_collection(collection_name)
      raise TypeError.new("#{collection_name} is not a collection type") unless collection_name.start_with?("Collection(")
      member_type_name = collection_name.gsub(/Collection\(([^)]+)\)/, "\\1")
      CollectionType.new(name: collection_name, member_type: @type_name_map[member_type_name])
    end

    def build_operation(operation_xml)
      schema_node = operation_xml.parent
      raise MicrosoftGraph::NonNullableError("No schema node for #{operation_xml}") if schema_node.nil? || schema_node.name != "Schema"
      namespace = schema_node["Namespace"]
      binding_type = if operation_xml["IsBound"] == "true"
        binding_param = operation_xml.xpath("./Parameter[@Name='bindingParameter']|./Parameter[@Name='bindingparameter']").first
        if binding_param.present? 
          type = schema_type(schema_node, binding_param["Type"])
          get_type_by_name(type)
        else 
          nil
        end
      end
      entity_set_type = if operation_xml["EntitySetType"]
        entity_set_by_name(operation_xml["EntitySetType"])
      end
      parameters = operation_xml.xpath("./Parameter").inject([]) do |result, parameter|
        unless parameter["Name"] == 'bindingParameter'
          type = schema_type(schema_node, parameter["Type"])
          result.push({
            name:     parameter["Name"],
            type:     get_type_by_name(type),
            nullable: parameter["Nullable"],
          })
        end
        result
      end
      return_type = if return_type_node = operation_xml.xpath("./ReturnType").first
        type = schema_type(schema_node, return_type_node["Type"])
        get_type_by_name(type)
      end

      options = {
          name:            operation_xml["Name"],
          entity_set_type: entity_set_type,
          binding_type:    binding_type,
          parameters:      parameters,
          return_type:     return_type
        }
      Operation.new(options)
    end

    def remove_namespace(name)
      name.gsub(/\w+\./, "")
    end
    
    def schema_type(schema_node, type_name)
      if type_name.present? && schema_node.present?
        namespace = schema_node["Namespace"]
        namespace_alias = schema_node["Alias"]     
        if namespace_alias.present? && (type_name.start_with?(namespace_alias) || type_name.start_with?("Collection(#{namespace_alias}."))
          return type_name.gsub("#{namespace_alias}.", "#{namespace}.") 
        end
        namespaces.each do |nspace|
          namespace = nspace[:namespace]
          namespace_alias = nspace[:alias]
          if namespace_alias.present? && (type_name.start_with?(namespace_alias) || type_name.start_with?("Collection(#{namespace_alias}."))
            return type_name.gsub("#{namespace_alias}.", "#{namespace}.") 
          end
        end
      end
      type_name
    end
  end
end
