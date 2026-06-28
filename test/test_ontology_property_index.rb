require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class TestOntologyPropertyIndex < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'bin', 'ncbo_ontology_property_index')

  def test_all_ontologies_aborts_before_clear_when_property_search_client_is_nil
    result = run_property_index('nil')

    refute result[:status].success?, result[:output]
    assert_match(/Property index preflight failed/, result[:output])
    assert_match(/Goo\.search_connection\(:property\) returned nil/, result[:output])
    assert_match(/No property index data was cleared or indexed/, result[:output])
    refute(
      result[:clear_called],
      'indexClear(:property) must not be called when the property client is nil'
    )
  end

  def test_all_ontologies_aborts_before_clear_when_property_search_core_is_unreachable
    result = run_property_index('unreachable')

    refute result[:status].success?, result[:output]
    assert_match(/Property index preflight failed/, result[:output])
    assert_match(/unable to query the property Solr core/, result[:output])
    assert_match(/Connection refused/, result[:output])
    assert_match(/No property index data was cleared or indexed/, result[:output])
    refute(
      result[:clear_called],
      'indexClear(:property) must not be called when the property core is unreachable'
    )
  end

  def test_all_ontologies_keeps_clear_path_when_property_search_preflight_succeeds
    result = run_property_index('healthy')

    assert result[:status].success?, result[:output]
    assert(
      result[:clear_called],
      'indexClear(:property) should still be called after a healthy preflight'
    )
    assert_match(/Completed processing property index for all ontologies/, result[:output])
  end

  private

  def run_property_index(property_search_stub)
    Dir.mktmpdir do |dir|
      prepare_stubbed_tree(dir)
      marker = File.join(dir, 'clear_called')
      env = {
        'PROPERTY_SEARCH_STUB' => property_search_stub,
        'PROPERTY_INDEX_CLEAR_MARKER' => marker
      }
      command = [
        RbConfig.ruby,
        File.join(dir, 'bin', 'ncbo_ontology_property_index'),
        '-a',
        '-c', 'http://localhost:8983/solr/prop_search_core1',
        '-z', 'false'
      ]

      stdout, stderr, status = Open3.capture3(
        env, *command, stdin_data: "yes\n", chdir: dir
      )
      {
        output: stdout + stderr,
        status: status,
        clear_called: File.exist?(marker)
      }
    end
  end

  def prepare_stubbed_tree(dir)
    FileUtils.mkdir_p(File.join(dir, 'bin'))
    FileUtils.mkdir_p(File.join(dir, 'config'))
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    FileUtils.cp(SCRIPT, File.join(dir, 'bin', 'ncbo_ontology_property_index'))
    File.write(File.join(dir, 'config', 'config.rb'), "# test stub\n")
    File.write(File.join(dir, 'lib', 'ncbo_cron.rb'), stubbed_ncbo_cron)
  end

  def stubbed_ncbo_cron
    <<~'RUBY'
      require 'logger'

      module Goo
        def self.configure
          yield self
        end

        def self.add_search_backend(_name, service:)
          @property_search_url = service
        end

        def self.search_connection(_name)
          case ENV.fetch('PROPERTY_SEARCH_STUB')
          when 'nil'
            nil
          when 'unreachable'
            UnreachablePropertySearchClient.new
          else
            HealthyPropertySearchClient.new
          end
        end

        class UnreachablePropertySearchClient
          def get(*)
            raise Errno::ECONNREFUSED, 'Connection refused - connect(2) for 127.0.0.1:8983'
          end
        end

        class HealthyPropertySearchClient
          def get(*)
            { 'responseHeader' => { 'status' => 0 } }
          end
        end
      end

      module LinkedData
        def self.settings
          @settings ||= Settings.new
        end

        class Settings
          attr_accessor :enable_notifications, :goo_host, :property_search_server_url

          def initialize
            @goo_host = 'localhost'
            @property_search_server_url = 'http://localhost:8983/solr/prop_search_core1'
          end
        end

        module Models
          class Ontology
            def self.all
              []
            end
          end

          class Class
            def self.indexClear(connection_name)
              File.write(ENV.fetch('PROPERTY_INDEX_CLEAR_MARKER'), connection_name.to_s)
            end

            def self.indexCommit(*)
            end

            def self.indexOptimize(*)
            end
          end
        end
      end

      module NcboCron
        def self.settings
          @settings ||= Settings.new
        end

        class Settings
          attr_accessor :property_search_index_all_url

          def initialize
            @property_search_index_all_url = 'http://localhost:8983/solr/prop_search_core2'
          end
        end
      end
    RUBY
  end
end
