require 'time'

module OData
  class TimeOfDayType < PrimitiveType
    def valid_value?(value)
      Time === value
    end

    def coerce(value)
      begin
        if Time === value
          value
        else
          Date.parse(value.to_s)
        end
      rescue ArgumentError
        raise TypeError.new("Cannot convert #{value.inspect} into a time")
      end
    end

    def name
      "Edm.TimeOfDay"
    end
  end
end
