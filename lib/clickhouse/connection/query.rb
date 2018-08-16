require "clickhouse/connection/query/table"
require "clickhouse/connection/query/result_set"
require "clickhouse/connection/query/result_row"

module Clickhouse
  class Connection
    module Query

      def execute(query, body = nil)
        body = post(query, body)
        body.empty? ? true : body
      end

      def query(query)
        query = Utils.extract_format(query)[0]
        query += " FORMAT JSONCompact"
        parse_data get(query)
      end

      def databases
        query("SHOW DATABASES").flatten
      end

      def tables
        query("SHOW TABLES").flatten
      end

      def create_table(name, &block)
        execute(Clickhouse::Connection::Query::Table.new(name, &block).to_sql)
      end

      def describe_table(name)
        query("DESCRIBE TABLE #{name}").to_a
      end

      def rename_table(*args)
        names = (args[0].is_a?(Hash) ? args[0].to_a : [args]).flatten
        raise Clickhouse::InvalidQueryError, "Odd number of table names" unless (names.size % 2) == 0
        names = Hash[*names].collect{|(from, to)| "#{from} TO #{to}"}
        execute("RENAME TABLE #{names.join(", ")}")
      end

      def drop_table(name)
        execute("DROP TABLE #{name}")
      end

      def insert_rows(table, csv: nil, names: nil, rows: nil, &block)
        if csv
          insert_csv table, csv
        else
          rows ||= [].tap(&block)
          if (hashes = rows.first.is_a?(Hash))
            names ||= rows.first.keys
          end
          insert_values table, names, hashes ? rows.map { |row| row.values_at(*names) } : rows
        end
      end

      def select_rows(options)
        query to_select_query(options)
      end

      def select_row(options)
        select_rows(options)[0]
      end

      def select_values(options)
        select_rows(options).collect{|row| row[0]}
      end

      def select_value(options)
        values = select_values(options)
        values[0] if values
      end

      def count(options)
        options = options.merge(:select => "COUNT(*)")
        select_value(options).to_i
      end

      def to_select_query(options)
        to_select_options(options).collect do |(key, value)|
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          statement = [key.to_s.upcase]
          statement << "BY" if %W(GROUP ORDER).include?(statement[0])
          statement << to_segment(key, value)
          statement.join(" ")

        end.compact.join("\n").force_encoding("UTF-8")
      end

    private

      # @see https://clickhouse.yandex/docs/en/query_language/insert_into/
      def insert_values(table, names, rows)
        execute(
          "INSERT INTO #{table}#{" (#{names.join(', ')})" if names} VALUES",
          rows.map do |values|
            "(#{values.map(&INSERT_VALUE_FORMATTER).join(', ')})"
          end.join(', '),
        )
      end

      # @see https://clickhouse.yandex/docs/en/interfaces/formats/#values
      INSERT_VALUE_FORMATTER = lambda do |value|
        case value
        when nil then 'NULL'
        when Numeric then value.to_s
        when Array then "[#{value.map(&INSERT_VALUE_FORMATTER).join(', ')}]"
        else "'#{value.to_s.gsub(/['\\]/, '\\\\\0')}'"
        end
      end

      def insert_csv(table, csv)
        execute("INSERT INTO #{table} FORMAT CSVWithNames", csv)
      end

      def inspect_value(value)
        value.nil? ? "NULL" : value.inspect.gsub(/(^"|"$)/, "'").gsub("\\\"", "\"")
      end

      def to_select_options(options)
        keys = [:select, :from, :where, :group, :having, :order, :limit, :offset]

        options = Hash[keys.zip(options.values_at(*keys))]
        options[:select] ||= "*"
        options[:limit] ||= 0 if options[:offset]
        options[:limit] = options.values_at(:offset, :limit).compact.join(", ") if options[:limit]
        options.delete(:offset)

        options
      end

      def to_segment(type, value)
        case type
        when :select
          [value].flatten.join(", ")
        when :where, :having
          value.is_a?(Hash) ? to_condition_statements(value) : value
        else
          value
        end
      end

      def to_condition_statements(value)
        value.collect do |attr, val|
          if val == :empty
            "empty(#{attr})"
          elsif val.is_a?(Range)
            [
              "#{attr} >= #{inspect_value(val.first)}",
              "#{attr} <= #{inspect_value(val.last)}"
            ]
          elsif val.is_a?(Array)
            "#{attr} IN (#{val.collect{|x| inspect_value(x)}.join(", ")})"
          elsif val.to_s.match(/^`.*`$/)
            "#{attr} #{val.gsub(/(^`|`$)/, "")}"
          else
            "#{attr} = #{inspect_value(val)}"
          end
        end.flatten.join(" AND ")
      end

      def parse_data(data)
        names = data["meta"].collect{|column| column["name"]}
        types = data["meta"].collect{|column| column["type"]}
        ResultSet.new data["data"], names, types
      end

    end
  end
end
