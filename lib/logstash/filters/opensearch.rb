# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"
require_relative "opensearch/client"
require "logstash/json"
require "logstash/util/safe_uri"
java_import "java.util.concurrent.ConcurrentHashMap"


class LogStash::Filters::OpenSearch < LogStash::Filters::Base
  config_name "opensearch"

  DEFAULT_HOST = ::LogStash::Util::SafeURI.new("//localhost:9200")

  # List of opensearch hosts to use for querying.
  config :hosts, :validate => :array, :default => [ DEFAULT_HOST ]

  # Comma-delimited list of index names to search; use `_all` or empty string to perform the operation on all indices.
  # Field substitution (e.g. `index-name-%{date_field}`) is available
  config :index, :validate => :string, :default => ""

  # OpenSearch query string. Read the OpenSearch query string documentation.
  # for more info at: https://www.elastic.co/guide/en/opensearch/reference/master/query-dsl-query-string-query.html#query-string-syntax
  config :query, :validate => :string

  # File path to opensearch query in DSL format. Read the OpenSearch query documentation
  # for more info at: https://www.elastic.co/guide/en/opensearch/reference/current/query-dsl.html
  config :query_template, :validate => :string

  # Comma-delimited list of `<field>:<direction>` pairs that define the sort order
  config :sort, :validate => :string, :default => "@timestamp:desc"

  # Array of fields to copy from old event (found via opensearch) into new event
  config :fields, :validate => :array, :default => {}

  # Hash of docinfo fields to copy from old event (found via opensearch) into new event
  config :docinfo_fields, :validate => :hash, :default => {}

  # Hash of aggregation names to copy from opensearch response into Logstash event fields
  config :aggregation_fields, :validate => :hash, :default => {}

  # Basic Auth - username
  config :user, :validate => :string

  # Basic Auth - password
  config :password, :validate => :password

  # Cloud ID, from the Elastic Cloud web console. If set `hosts` should not be used.
  #
  # For more info, check out the https://www.elastic.co/guide/en/logstash/current/connecting-to-cloud.html#_cloud_id[Logstash-to-Cloud documentation]
  config :cloud_id, :validate => :string

  # Cloud authentication string ("<username>:<password>" format) is an alternative for the `user`/`password` configuration.
  #
  # For more info, check out the https://www.elastic.co/guide/en/logstash/current/connecting-to-cloud.html#_cloud_auth[Logstash-to-Cloud documentation]
  config :cloud_auth, :validate => :password

  # Authenticate using OpenSearch API key.
  # format is id:api_key (as returned by https://www.elastic.co/guide/en/opensearch/reference/current/security-api-create-api-key.html[Create API key])
  config :api_key, :validate => :password

  # SSL
  config :ssl, :validate => :boolean, :default => false

  # SSL Certificate Authority file
  config :ca_file, :validate => :path

  # Whether results should be sorted or not
  config :enable_sort, :validate => :boolean, :default => true

  # How many results to return
  config :result_size, :validate => :number, :default => 1

  # Tags the event on failure to look up geo information. This can be used in later analysis.
  config :tag_on_failure, :validate => :array, :default => ["_opensearch_lookup_failure"]

  attr_reader :clients_pool

  def register
    @clients_pool = java.util.concurrent.ConcurrentHashMap.new

    #Load query if it exists
    if @query_template
      if File.zero?(@query_template)
        raise "template is empty"
      end
      file = File.open(@query_template, 'r')
      @query_dsl = file.read
    end

    validate_authentication
    fill_user_password_from_cloud_auth
    fill_hosts_from_cloud_id

    @hosts = Array(@hosts).map { |host| host.to_s } # for ES client URI#to_s

    test_connection!
  end # def register

  def filter(event)
    matched = false
    begin
      params = {:index => event.sprintf(@index) }

      if @query_dsl
        query = LogStash::Json.load(event.sprintf(@query_dsl))
        params[:body] = query
      else
        query = event.sprintf(@query)
        params[:q] = query
        params[:size] = result_size
        params[:sort] =  @sort if @enable_sort
        unless fields.empty?
          params[:_source] = fields.keys
        end
      end

      @logger.debug("Querying opensearch for lookup", :params => params)

      results = get_client.search(params)
      raise "OpenSearch query error: #{results["_shards"]["failures"]}" if results["_shards"].include? "failures"

      event.set("[@metadata][total_hits]", extract_total_from_hits(results['hits']))

      resultsHits = results["hits"]["hits"]
      if !resultsHits.nil? && !resultsHits.empty?
        matched = true
        @fields.each do |old_key, new_key|
          old_key_path = extract_path(old_key)
          set = resultsHits.map do |doc|
            extract_value(doc["_source"], old_key_path)
          end
          event.set(new_key, set.count > 1 ? set : set.first)
        end
        @docinfo_fields.each do |old_key, new_key|
          old_key_path = extract_path(old_key)
          set = resultsHits.map do |doc|
            extract_value(doc, old_key_path)
          end
          event.set(new_key, set.count > 1 ? set : set.first)
        end
      end

      resultsAggs = results["aggregations"]
      if !resultsAggs.nil? && !resultsAggs.empty?
        matched = true
        @aggregation_fields.each do |agg_name, ls_field|
          event.set(ls_field, resultsAggs[agg_name])
        end
      end

    rescue => e
      if @logger.trace?
        @logger.warn("Failed to query opensearch for previous event", :index => @index, :query => query, :event => event.to_hash, :error => e.message, :backtrace => e.backtrace)
      elsif @logger.debug?
        @logger.warn("Failed to query opensearch for previous event", :index => @index, :error => e.message, :backtrace => e.backtrace)
      else
        @logger.warn("Failed to query opensearch for previous event", :index => @index, :error => e.message)
      end
      @tag_on_failure.each{|tag| event.tag(tag)}
    else
      filter_matched(event) if matched
    end
  end # def filter

  private

  def client_options
    {
      :user => @user,
      :password => @password,
      :api_key => @api_key,
      :ssl => @ssl,
      :ca_file => @ca_file,
    }
  end

  def new_client
    # NOTE: could pass cloud-id/cloud-auth to client but than we would need to be stricter on ES version requirement
    # and also LS parsing might differ from ES client's parsing so for consistency we do not pass cloud options ...
    LogStash::Filters::OpenSearchClient.new(@logger, @hosts, client_options)
  end

  def get_client
    @clients_pool.computeIfAbsent(Thread.current, lambda { |x| new_client })
  end

  # get an array of path elements from a path reference
  def extract_path(path_reference)
    return [path_reference] unless path_reference.start_with?('[') && path_reference.end_with?(']')

    path_reference[1...-1].split('][')
  end

  # given a Hash and an array of path fragments, returns the value at the path
  # @param source [Hash{String=>Object}]
  # @param path [Array{String}]
  # @return [Object]
  def extract_value(source, path)
    path.reduce(source) do |memo, old_key_fragment|
      break unless memo.include?(old_key_fragment)
      memo[old_key_fragment]
    end
  end

  # Given a "hits" object from an OpenSearch response, return the total number of hits in
  # the result set.
  # @param hits [Hash{String=>Object}]
  # @return [Integer]
  def extract_total_from_hits(hits)
    total = hits['total']

    # OpenSearch 7.x produces an object containing `value` and `relation` in order
    # to enable unambiguous reporting when the total is only a lower bound; if we get
    # an object back, return its `value`.
    return total['value'] if total.kind_of?(Hash)

    total
  end

  def hosts_default?(hosts)
    # NOTE: would be nice if pipeline allowed us a clean way to detect a config default :
    hosts.is_a?(Array) && hosts.size == 1 && hosts.first.equal?(DEFAULT_HOST)
  end

  def validate_authentication
    authn_options = 0
    authn_options += 1 if @cloud_auth
    authn_options += 1 if (@api_key && @api_key.value)
    authn_options += 1 if (@user || (@password && @password.value))

    if authn_options > 1
      raise LogStash::ConfigurationError, 'Multiple authentication options are specified, please only use one of user/password, cloud_auth or api_key'
    end

    if @api_key && @api_key.value && @ssl != true
      raise(LogStash::ConfigurationError, "Using api_key authentication requires SSL/TLS secured communication using the `ssl => true` option")
    end
  end

  def fill_user_password_from_cloud_auth
    return unless @cloud_auth

    @user, @password = parse_user_password_from_cloud_auth(@cloud_auth)
    params['user'], params['password'] = @user, @password
  end

  def fill_hosts_from_cloud_id
    return unless @cloud_id

    if @hosts && !hosts_default?(@hosts)
      raise LogStash::ConfigurationError, 'Both cloud_id and hosts specified, please only use one of those.'
    end
    @hosts = parse_host_uri_from_cloud_id(@cloud_id)
  end

  def parse_host_uri_from_cloud_id(cloud_id)
    begin # might not be available on older LS
      require 'logstash/util/cloud_setting_id'
    rescue LoadError
      raise LogStash::ConfigurationError, 'The cloud_id setting is not supported by your version of Logstash, ' +
          'please upgrade your installation (or set hosts instead).'
    end

    begin
      cloud_id = LogStash::Util::CloudSettingId.new(cloud_id) # already does append ':{port}' to host
    rescue ArgumentError => e
      raise LogStash::ConfigurationError, e.message.to_s.sub(/Cloud Id/i, 'cloud_id')
    end
    cloud_uri = "#{cloud_id.opensearch_scheme}://#{cloud_id.opensearch_host}"
    LogStash::Util::SafeURI.new(cloud_uri)
  end

  def parse_user_password_from_cloud_auth(cloud_auth)
    begin # might not be available on older LS
      require 'logstash/util/cloud_setting_auth'
    rescue LoadError
      raise LogStash::ConfigurationError, 'The cloud_auth setting is not supported by your version of Logstash, ' +
          'please upgrade your installation (or set user/password instead).'
    end

    cloud_auth = cloud_auth.value if cloud_auth.is_a?(LogStash::Util::Password)
    begin
      cloud_auth = LogStash::Util::CloudSettingAuth.new(cloud_auth)
    rescue ArgumentError => e
      raise LogStash::ConfigurationError, e.message.to_s.sub(/Cloud Auth/i, 'cloud_auth')
    end
    [ cloud_auth.username, cloud_auth.password ]
  end

  def test_connection!
    get_client.client.ping
  end
end #class LogStash::Filters::OpenSearch
