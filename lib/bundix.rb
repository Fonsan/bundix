require 'bundler'
require 'json'
require 'open-uri'
require 'open3'
require 'pp'
require 'erb'

require 'bundix/version'
require 'bundix/source'
require 'bundix/prefetcher'
require 'bundix/nixer'

class Bundix
  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_BUILD = 'nix-build'
  NIX_HASH = 'nix-hash'
  NIX_SHELL = 'nix-shell'

  FETCHURL_FORCE = File.expand_path('../bundix/fetchurl-force.nix', __FILE__)
  FETCHURL_FORCE_CHECK = lambda do |_, out|
    out =~ /success! failing outer nix build.../
  end

  SHA256_32 = %r(^[a-z0-9]{52}$)
  SHA256_16 = %r(^[a-f0-9]{64}$)

  attr_reader :cache, :lock, :deps, :lockfile, :gemset

  def initialize(options)
    @deps, @lockfile, @gemset = options.values_at(:deps, :lockfile, :gemset)
  end

  def convert
    @cache = parse_gemset
    @lock = parse_lockfile


    # reverse so git comes last
    lock.specs.reverse_each.with_object({}) do |spec, gems|
      gem = find_cached_spec(spec) || convert_spec(spec)
      gems.merge!(gem)

      if deps && spec.dependencies.any?
        gems[spec.name]['dependencies'] = spec.dependencies.map(&:name) - ['bundler']
      end
    end
  end

  def platforms(spec)

  end

  def convert_spec(spec)
    {spec.name => {
      version: spec.version.to_s,
      source: Source.new(spec, Prefetcher.pick).convert
    }}
    #}.merge(platforms(spec)).merge(groups(spec)) }
  rescue => ex
    warn "Skipping #{spec.name}: #{ex}"
    puts ex.backtrace
    {spec.name => {}}
  end

  def find_cached_spec(spec)
    name, cached = cache.find{|k, v|
      next unless k == spec.name
      next unless cached_source = v['source']

      case spec_source = spec.source
      when Bundler::Source::Git
        next unless cached_source['type'] == 'git'
        next unless cached_rev = cached_source['rev']
        next unless spec_rev = spec_source.options['revision']
        spec_rev == cached_rev
      when Bundler::Source::Rubygems
        next unless cached_source['type'] == 'gem'
        v['version'] == spec.version.to_s
      end
    }

    {name => cached} if cached
  end


  def parse_gemset
    path = File.expand_path(gemset)
    return {} unless File.file?(path)
    json = Bundix.sh(
      NIX_INSTANTIATE, '--eval', '-E', "builtins.toJSON(import #{path})")
    JSON.parse(json.strip.gsub(/\\"/, '"')[1..-2])
  end

  def parse_lockfile
    Bundler::LockfileParser.new(File.read(lockfile))
  end

  def self.sh(*args, &block)
    out, status = Open3.capture2e(*args)
    unless block_given? ? block.call(status, out) : status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      fail "command execution failed: #{args.inspect} -> #{status}\n#{out}"
    end
    out
  end
end
