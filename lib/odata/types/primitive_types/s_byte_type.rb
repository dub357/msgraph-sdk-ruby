module OData
  class SByteType < PrimitiveType
    def valid_value?(value)
      Integer === value &&
        value <= 2**7 &&
        value > -(2**7)
    end

    def coerce(value)
      val = value.respond_to?(:to_i) ? value.to_i : value
      raise TypeError, "Cannot convert #{value.inspect} into an SByte" unless valid_value?(val)
      val
    end

    def name
      "Edm.SBtye"
    end
  end
end
