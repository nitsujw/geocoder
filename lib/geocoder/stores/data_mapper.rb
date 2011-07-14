require 'geocoder/stores/base'

module Geocoder::Store
  module DataMapper
    include Base

    def self.included(base)
      base.extend ClassMethods
      base.class_eval do

        def self.geocoded
          all("#{geocoder_options[:latitude]}".to_sym.not => nil, "#{geocoder_options[:longitude]}".to_sym.not => nil)
        end

        def self.not_geocoded
          all("#{geocoder_options[:latitude]}".to_sym => nil, "#{geocoder_options[:longitude]}".to_sym => nil)
        end

        def self.near(location, *args)
          latitude, longitude = Geocoder::Calculations.extract_coordinates(location)
          if latitude and longitude
            near_scope_options(latitude, longitude, *args)
          else
            {}
          end
        end

      end
    end

    ##
    # Coordinates [lat,lon] of the object.
    # This method always returns coordinates in lat,lon order,
    # even though internally they are stored in the opposite order.
    #
    #def to_coordinates
    #  coords = send(self.class.geocoder_options[:coordinates])
    #  coords.is_a?(Array) ? coords.reverse : []
    #end

    module ClassMethods

      private # ----------------------------------------------------------------

      def near_scope_options(latitude, longitude, radius = 20, options = {})
        radius *= Geocoder::Calculations.km_in_mi if options[:units] == :km
        if repository(:default).adapter.options["adapter"].match /sqlite/i
          approx_near_scope_options(latitude, longitude, radius, options)
        else
          full_near_scope_options(latitude, longitude, radius, options)
        end
      end

      def full_near_scope_options(latitude, longitude, radius, options)
        lat_attr = geocoder_options[:latitude]
        lon_attr = geocoder_options[:longitude]
        options[:bearing] = :linear unless options.include?(:bearing)
        bearing = case options[:bearing]
        when :linear
          "CAST(" +
            "DEGREES(ATAN2( " +
              "RADIANS(#{lon_attr} - #{longitude}), " +
              "RADIANS(#{lat_attr} - #{latitude})" +
            ")) + 360 " +
          "AS decimal) % 360"
        when :spherical
          "CAST(" +
            "DEGREES(ATAN2( " +
              "SIN(RADIANS(#{lon_attr} - #{longitude})) * " +
              "COS(RADIANS(#{lat_attr})), (" +
                "COS(RADIANS(#{latitude})) * SIN(RADIANS(#{lat_attr}))" +
              ") - (" +
                "SIN(RADIANS(#{latitude})) * COS(RADIANS(#{lat_attr})) * " +
                "COS(RADIANS(#{lon_attr} - #{longitude}))" +
              ")" +
            ")) + 360 " +
          "AS decimal) % 360"
        end
        earth = Geocoder::Calculations.earth_radius(options[:units] || :mi)
        distance = "#{earth} * 2 * ASIN(SQRT(" +
          "POWER(SIN((#{latitude} - #{lat_attr}) * PI() / 180 / 2), 2) + " +
          "COS(#{latitude} * PI() / 180) * COS(#{lat_attr} * PI() / 180) * " +
          "POWER(SIN((#{longitude} - #{lon_attr}) * PI() / 180 / 2), 2) ))"
        options[:order] ||= "#{distance} ASC"
        sql_hash = default_near_scope_options(latitude, longitude, radius, options).merge(
          :select => "#{options[:select] || '*'}, " +
            "#{distance} AS distance" +
            (bearing ? ", #{bearing} AS bearing" : ""),
          :having => "#{distance} <= #{radius}"
        )
        construct_datamapper_sql(sql_hash)
      end

      def approx_near_scope_options(latitude, longitude, radius, options)
        lat_attr = geocoder_options[:latitude]
        lon_attr = geocoder_options[:longitude]
        options[:bearing] = :linear unless options.include?(:bearing)
        if options[:bearing]
          bearing = "CASE " +
            "WHEN (#{lat_attr} >= #{latitude} AND #{lon_attr} >= #{longitude}) THEN 45.0 " +
            "WHEN (#{lat_attr} < #{latitude} AND #{lon_attr} >= #{longitude}) THEN 135.0 " +
            "WHEN (#{lat_attr} < #{latitude} AND #{lon_attr} < #{longitude}) THEN 225.0 " +
            "WHEN (#{lat_attr} >= #{latitude} AND #{lon_attr} < #{longitude}) THEN 315.0 " +
          "END"
        else
          bearing = false
        end

        dx = Geocoder::Calculations.longitude_degree_distance(30, options[:units] || :mi)
        dy = Geocoder::Calculations.latitude_degree_distance(options[:units] || :mi)

        # sin of 45 degrees = average x or y component of vector
        factor = Math.sin(Math::PI / 4)

        distance = "(#{dy} * ABS(#{lat_attr} - #{latitude}) * #{factor}) + " +
          "(#{dx} * ABS(#{lon_attr} - #{longitude}) * #{factor})"
        sql_hash = default_near_scope_options(latitude, longitude, radius, options).merge(
          :select => "#{options[:select] || '*'}, " +
            "#{distance} AS distance" +
            (bearing ? ", #{bearing} AS bearing" : ""),
          :order => distance
        )
        construct_datamapper_sql(sql_hash)
        
      end
      
      def construct_datamapper_sql(options)
        sql = "SELECT #{options[:select]} "
        sql << "FROM #{self.storage_name} "
        sql << "WHERE (#{options[:conditions].first}) "
        sql << "ORDER BY #{options[:order]} "
        convert_to_original_class(sql)
      end
      
      def convert_to_original_class(sql)
        structs = repository(:default).adapter.select sql
        ids = structs.inject([]) do |array,struct|
          array << struct.id
        end
        self.all(:id => ids)
      end
      def default_near_scope_options(latitude, longitude, radius, options)
        lat_attr = geocoder_options[:latitude]
        lon_attr = geocoder_options[:longitude]
        b = Geocoder::Calculations.bounding_box([latitude, longitude], radius, options)
        conditions = \
          ["#{lat_attr} BETWEEN #{b[0]} AND #{b[2]} AND #{lon_attr} BETWEEN #{b[1]} AND #{b[3]}"]
        if obj = options[:exclude]
          conditions[0] << " AND #{self.name.to_s.downcase}.id != ?"
          conditions << obj.id
        end
        {
          #:group => properties.map{ |c| "#{c.model.to_s.downcase}.#{c.name}" }.join(','),
          :order => options[:order],
          :limit => options[:limit],
          :offset => options[:offset],
          :conditions => conditions
        }
      end

    end

    ##
    # Look up coordinates and assign to +latitude+ and +longitude+ attributes
    # (or other as specified in +geocoded_by+). Returns coordinates (array).
    #
    def geocode
      do_lookup(false) do |o,rs|
        r = rs.first
        unless r.latitude.nil? or r.longitude.nil?
          o.send :attribute_set, self.class.geocoder_options[:latitude],  r.latitude
          o.send :attribute_set, self.class.geocoder_options[:longitude], r.longitude
        end
        r.coordinates
      end
    end

    ##
    # Look up address and assign to +address+ attribute (or other as specified
    # in +reverse_geocoded_by+). Returns address (string).
    #
    def reverse_geocode
      do_lookup(true) do |o,rs|
        r = rs.first
        unless r.address.nil?
          o.send :attribute_set, self.class.geocoder_options[:fetched_address], r.address
        end
        r.address
      end
    end
  end
end
