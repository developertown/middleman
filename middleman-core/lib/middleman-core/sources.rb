require 'middleman-core/contracts'
require 'backports/2.0.0/enumerable/lazy'

module Middleman
  # The standard "record" that contains information about a file on disk.
  SourceFile = Struct.new :relative_path, :full_path, :directory, :types

  # Sources handle multiple on-disk collections of files which make up
  # a Middleman project. They are separated by `type` which can then be
  # queried. For example, the `source` type represents all content that
  # the sitemap uses to build a project. The `data` type represents YAML
  # data. The `locales` type represents localization YAML, and so on.
  class Sources
    extend Forwardable
    include Contracts

    Matcher = Or[Regexp, RespondTo[:call]]

    # A reference to the current app.
    Contract IsA['Middleman::Application']
    attr_reader :app

    # Duck-typed definition of a valid source watcher
    HANDLER = RespondTo[:on_change]

    # Config
    Contract Hash
    attr_reader :options

    # Reference to the global logger.
    def_delegator :@app, :logger

    # Built-in types
    # :source, :data, :locales, :reload

    # Create a new collection of sources.
    #
    # @param [Middleman::Application] app The parent app.
    # @param [Hash] options Global options.
    # @param [Array] watchers Default watchers.
    Contract IsA['Middleman::Application'], Maybe[Hash], Maybe[Array] => Any
    def initialize(app, options={}, watchers=[])
      @app = app
      @watchers = watchers
      @sorted_watchers = @watchers.dup.freeze

      @options = options

      # Set of procs wanting to be notified of changes
      @on_change_callbacks = []

      # Global ignores
      @ignores = {}

      # Whether we're "running", which means we're in a stable
      # watch state after all initialization and config.
      @running = false

      @update_count = 0
      @last_update_count = -1

      # When the app is about to shut down, stop our watchers.
      @app.before_shutdown(&method(:stop!))
    end

    # Add a proc to ignore paths with either a regex or block.
    #
    # @param [Symbol] name A name for the ignore.
    # @param [Symbol] type The type of content to apply the ignore to.
    # @param [Regexp] regex Ignore by path regex.
    # @param [Proc] block Ignore by block evaluation.
    # @return [void]
    Contract Symbol, Symbol, Or[Regexp, Proc] => Any
    def ignore(name, type, regex=nil, &block)
      @ignores[name] = { type: type, validator: (block_given? ? block : regex) }

      bump_count
      find_new_files! if @running
    end

    # Whether this path is ignored.
    #
    # @param [Middleman::SourceFile] file The file to check.
    # @return [Boolean]
    Contract SourceFile => Bool
    def globally_ignored?(file)
      @ignores.values.any? do |descriptor|
        ((descriptor[:type] == :all) || file[:types].include?(descriptor[:type])) &&
          matches?(descriptor[:validator], file)
      end
    end

    # Connect a new watcher. Can either be a type with options, which will
    # create a `SourceWatcher` or you can pass in an instantiated class which
    # responds to #changed and #deleted
    #
    # @param [Symbol, #changed, #deleted] type_or_handler The handler.
    # @param [Hash] options The watcher options.
    # @return [#changed, #deleted]
    Contract Or[Symbol, HANDLER], Maybe[Hash] => HANDLER
    def watch(type_or_handler, options={})
      handler = if type_or_handler.is_a? Symbol
        SourceWatcher.new(self, type_or_handler, options.delete(:path), options)
      else
        type_or_handler
      end

      @watchers << handler

      # The index trick is used so that the sort is stable - watchers with the same priority
      # will always be ordered in the same order as they were registered.
      n = 0
      @sorted_watchers = @watchers.sort_by do |w|
        priority = w.options.fetch(:priority, 50)
        n += 1
        [priority, n]
      end.reverse.freeze

      handler.on_change(&method(:did_change))

      if @running
        handler.poll_once!
        handler.listen!
      end

      handler
    end

    # A list of registered watchers
    Contract ArrayOf[HANDLER]
    def watchers
      @sorted_watchers
    end

    # Disconnect a specific watcher.
    #
    # @param [SourceWatcher] watcher The watcher to remove.
    # @return [void]
    Contract RespondTo[:on_change] => Any
    def unwatch(watcher)
      @watchers.delete(watcher)

      watcher.unwatch

      bump_count
    end

    # Filter the collection of watchers by a type.
    #
    # @param [Symbol] type The watcher type.
    # @return [Middleman::Sources]
    Contract Symbol => ::Middleman::Sources
    def by_type(type)
      self.class.new @app, @options, watchers.select { |d| d.type == type }
    end

    # Get all files for this collection of watchers.
    #
    # @return [Array<Middleman::SourceFile>]
    Contract ArrayOf[SourceFile]
    def files
      watchers.flat_map(&:files).uniq { |f| f[:relative_path] }
    end

    # Find a file given a type and path.
    #
    # @param [Symbol] type The file "type".
    # @param [String] path The file path.
    # @param [Boolean] glob If the path contains wildcard or glob characters.
    # @return [Middleman::SourceFile, nil]
    Contract Symbol, String, Maybe[Bool] => Maybe[SourceFile]
    def find(type, path, glob=false)
      watchers
        .lazy
        .select { |d| d.type == type }
        .map { |d| d.find(path, glob) }
        .reject(&:nil?)
        .first
    end

    # Check if a file for a given type exists.
    #
    # @param [Symbol] type The file "type".
    # @param [String] path The file path relative to it's source root.
    # @return [Boolean]
    Contract Symbol, String => Bool
    def exists?(type, path)
      watchers
        .lazy
        .select { |d| d.type == type }
        .any? { |d| d.exists?(path) }
    end

    # Check if a file for a given type exists.
    #
    # @param [Symbol] type The file "type".
    # @param [String] path The file path relative to it's source root.
    # @return [Boolean]
    Contract SetOf[Symbol], String => Maybe[HANDLER]
    def watcher_for_path(types, path)
      watchers
        .select { |d| types.include?(d.type) }
        .find { |d| d.exists?(path) }
    end

    # Manually poll all watchers for new content.
    #
    # @return [void]
    Contract Any
    def find_new_files!
      return unless @update_count != @last_update_count

      @last_update_count = @update_count
      watchers.each(&:poll_once!)
    end

    # Start up all listeners.
    #
    # @return [void]
    Contract Any
    def start!
      watchers.each(&:listen!)
      @running = true
    end

    # Stop the watchers.
    #
    # @return [void]
    Contract Any
    def stop!
      watchers.each(&:stop_listener!)
      @running = false
    end

    # A callback requires a type and the proc to execute.
    CallbackDescriptor = Struct.new :type, :proc

    # Add callback to be run on file change or deletion
    #
    # @param [Symbol] type The change type.
    # @return [Set<CallbackDescriptor>]
    Contract Symbol, Proc => ArrayOf[CallbackDescriptor]
    def on_change(type, &block)
      @on_change_callbacks << CallbackDescriptor.new(type, block)
      @on_change_callbacks
    end

    # Backwards compatible change handler.
    #
    # @param [nil,Regexp] matcher A Regexp to match the change path against
    Contract Maybe[Matcher] => Any
    def changed(matcher=nil, &block)
      on_change :source do |updated, _removed|
        updated
          .select { |f| matcher.nil? ? true : matches?(matcher, f) }
          .each { |f| block.call(f[:relative_path]) }
      end
    end

    # Backwards compatible delete handler.
    #
    # @param [nil,Regexp] matcher A Regexp to match the change path against
    Contract Maybe[Matcher] => Any
    def deleted(matcher=nil, &block)
      on_change :source do |_updated, removed|
        removed
          .select { |f| matcher.nil? ? true : matches?(matcher, f) }
          .each { |f| block.call(f[:relative_path]) }
      end
    end

    # Backwards compatible ignored check.
    #
    # @param [Pathname,String] path The path to check.
    Contract Or[Pathname, String] => Bool
    def ignored?(path)
      descriptor = find(:source, path)
      !descriptor || globally_ignored?(descriptor)
    end

    protected

    # Whether a validator matches a file.
    #
    # @param [Regexp, #call] validator The match validator.
    # @param [Middleman::SourceFile] file The file to check.
    # @return [Boolean]
    Contract Matcher, SourceFile => Bool
    def matches?(validator, file)
      path = file[:relative_path]
      if validator.is_a? Regexp
        !!validator.match(path.to_s)
      else
        !!validator.call(path, @app)
      end
    end

    # Increment the internal counter for changes.
    #
    # @return [void]
    Contract Any
    def bump_count
      @update_count += 1
    end

    # Notify callbacks that a file changed
    #
    # @param [Middleman::SourceFile] file The file that changed
    # @return [void]
    Contract ArrayOf[SourceFile], ArrayOf[SourceFile], HANDLER => Any
    def did_change(updated_files, removed_files, watcher)
      valid_updated = updated_files.select do |file|
        watcher_for_path(file[:types], file[:relative_path].to_s) == watcher
      end

      valid_removed = removed_files.select do |file|
        watcher_for_path(file[:types], file[:relative_path].to_s).nil?
      end

      return if valid_updated.empty? && valid_removed.empty?

      bump_count
      run_callbacks(@on_change_callbacks, valid_updated, valid_removed)
    end

    # Notify callbacks for a file given a set of callbacks
    #
    # @param [Set] callback_descriptors The registered callbacks.
    # @param [Array<Middleman::SourceFile>] files The files that were changed.
    # @return [void]
    Contract ArrayOf[CallbackDescriptor], ArrayOf[SourceFile], ArrayOf[SourceFile] => Any
    def run_callbacks(callback_descriptors, updated_files, removed_files)
      callback_descriptors.each do |callback|
        if callback[:type] == :all
          callback[:proc].call(updated_files, removed_files)
        else
          valid_updated = updated_files.select { |f| f[:types].include?(callback[:type]) }
          valid_removed = removed_files.select { |f| f[:types].include?(callback[:type]) }

          callback[:proc].call(valid_updated, valid_removed) unless valid_updated.empty? && valid_removed.empty?
        end
      end
    end
  end
end

# And, require the actual default implementation for a watcher.
require 'middleman-core/sources/source_watcher.rb'
