module OData
  class DurationType < PrimitiveType
    def valid_value?(value)
      String === value
    end

    def coerce(value)
      value.to_s
    end

    def name
      "Edm.Duration"
    end
  end
end
