module OData
  class DecimalType < PrimitiveType
    def valid_value?(value)
      Numeric === value
    end

    def coerce(value)
      raise TypeError.new("Cannot convert #{value.inspect} into a float") unless value.respond_to? :to_f
      value.to_f
    end

    def name
      "Edm.Decimal"
    end
  end
end
