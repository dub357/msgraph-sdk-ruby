module OData
  class SingleType < PrimitiveType
    def valid_value?(value)
      String === value
    end

    def coerce(value)
      value
    end

    def name
      "Edm.Single"
    end
  end
end
