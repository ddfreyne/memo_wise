# frozen_string_literal: true

require "memo_wise/internal_api"
require "memo_wise/version"

# MemoWise is the wise choice for memoization in Ruby.
#
# - **Q:** What is *memoization*?
# - **A:** [via Wikipedia](https://en.wikipedia.org/wiki/Memoization):
#
#          [Memoization is] an optimization technique used primarily to speed up
#          computer programs by storing the results of expensive function
#          calls and returning the cached result when the same inputs occur
#          again.
#
# To start using MemoWise in a class or module:
#
#   1. Add `prepend MemoWise` to the top of the class or module
#   2. Call {.memo_wise} to implement memoization for a given method
#
# **See Also:**
#
#   - {.memo_wise} for API and usage examples.
#   - {file:README.md} for general project information.
#
module MemoWise # rubocop:disable Metrics/ModuleLength
  # Constructor to set up memoization state before
  # [calling the original](https://medium.com/@jeremy_96642/ruby-method-auditing-using-module-prepend-4f4e69aacd95)
  # constructor.
  #
  # - **Q:** Why is [Module#prepend](https://ruby-doc.org/core-3.0.0/Module.html#method-i-prepend)
  #          important here
  #          ([more info](https://medium.com/@leo_hetsch/ruby-modules-include-vs-prepend-vs-extend-f09837a5b073))?
  # - **A:** To set up *mutable state* inside the instance, even if the original
  #          constructor will then call
  #          [Object#freeze](https://ruby-doc.org/core-3.0.0/Object.html#method-i-freeze).
  #
  # This approach supports memoization on frozen (immutable) objects -- for
  # example, classes created by the
  # [Values](https://github.com/tcrayford/Values)
  # [gem](https://rubygems.org/gems/values).
  #
  # To support syntax differences with keyword and positional arguments starting
  # with ruby 2.7, we have to set up the initializer with some slightly
  # different syntax for the different versions.  This variance in syntax is not
  # included in coverage reports since the branch chosen will never differ
  # within a single ruby version.  This means it is impossible for us to get
  # 100% coverage of this line within a single CI run.
  #
  # See
  # [this article](https://www.ruby-lang.org/en/news/2019/12/12/separation-of-positional-and-keyword-arguments-in-ruby-3-0/)
  # for more information.
  #
  # :nocov:
  all_args = RUBY_VERSION < "2.7" ? "*" : "..."
  # :nocov:
  class_eval <<-END_OF_METHOD, __FILE__, __LINE__ + 1
    # On Ruby 2.7 or greater:
    #
    # def initialize(...)
    #   MemoWise::InternalAPI.create_memo_wise_state!(self)
    #   super
    # end
    #
    # On Ruby 2.6 or lower:
    #
    # def initialize(*)
    #   MemoWise::InternalAPI.create_memo_wise_state!(self)
    #   super
    # end

    def initialize(#{all_args})
      MemoWise::InternalAPI.create_memo_wise_state!(self)
      super
    end
  END_OF_METHOD

  # @private
  #
  # Private setup method, called automatically by `prepend MemoWise` in a class.
  #
  # @param target [Class]
  #   The `Class` into to prepend the MemoWise methods e.g. `memo_wise`
  #
  # @see https://ruby-doc.org/core-3.0.0/Module.html#method-i-prepended
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #   end
  #
  def self.prepended(target) # rubocop:disable Metrics/PerceivedComplexity
    class << target
      # Allocator to set up memoization state before
      # [calling the original](https://medium.com/@jeremy_96642/ruby-method-auditing-using-module-prepend-4f4e69aacd95)
      # allocator.
      #
      # This is necessary in addition to the `#initialize` method definition
      # above because
      # [`Class#allocate`](https://ruby-doc.org/core-3.0.0/Class.html#method-i-allocate)
      # bypasses `#initialize`, and when it's used (e.g.,
      # [in ActiveRecord](https://github.com/rails/rails/blob/a395c3a6af1e079740e7a28994d77c8baadd2a9d/activerecord/lib/active_record/persistence.rb#L411))
      # we still need to be able to access MemoWise's instance variable. Despite
      # Ruby documentation indicating otherwise, `Class#new` does not call
      # `Class#allocate`, so we need to override both.
      #
      def allocate
        MemoWise::InternalAPI.create_memo_wise_state!(super)
      end

      # NOTE: See YARD docs for {.memo_wise} directly below this method!
      def memo_wise(method_name_or_hash) # rubocop:disable Metrics/PerceivedComplexity
        klass = self
        case method_name_or_hash
        when Symbol
          method_name = method_name_or_hash

          if klass.singleton_class?
            MemoWise::InternalAPI.create_memo_wise_state!(
              MemoWise::InternalAPI.original_class_from_singleton(klass)
            )
          end
        when Hash
          unless method_name_or_hash.keys == [:self]
            raise ArgumentError,
                  "`:self` is the only key allowed in memo_wise"
          end

          method_name = method_name_or_hash[:self]

          MemoWise::InternalAPI.create_memo_wise_state!(self)

          # In Ruby, "class methods" are implemented as normal instance methods
          # on the "singleton class" of a given Class object, found via
          # {Class#singleton_class}.
          # See: https://medium.com/@leo_hetsch/demystifying-singleton-classes-in-ruby-caf3fa4c9d91
          klass = klass.singleton_class
        end

        unless method_name.is_a?(Symbol)
          raise ArgumentError, "#{method_name.inspect} must be a Symbol"
        end

        api = MemoWise::InternalAPI.new(klass)
        visibility = api.method_visibility(method_name)
        original_memo_wised_name =
          MemoWise::InternalAPI.original_memo_wised_name(method_name)
        method = klass.instance_method(method_name)

        klass.send(:alias_method, original_memo_wised_name, method_name)
        klass.send(:private, original_memo_wised_name)

        # Zero-arg methods can use simpler/more performant logic because the
        # hash key is just the method name.
        if method.arity.zero?
          klass.module_eval <<-END_OF_METHOD, __FILE__, __LINE__ + 1
            # def foo
            #   @_memo_wise.fetch(:foo) do
            #     @_memo_wise[:foo] = _memo_wise_original_foo
            #   end
            # end

            def #{method_name}
              @_memo_wise.fetch(:#{method_name}) do
                @_memo_wise[:#{method_name}] = #{original_memo_wised_name}
              end
            end
          END_OF_METHOD
        else
          if MemoWise::InternalAPI.has_only_required_args?(method)
            args_str = method.parameters.map do |type, name|
              "#{name}#{':' if type == :keyreq}"
            end.join(", ")
            args_str = "(#{args_str})"
            call_str = method.parameters.map do |type, name|
              type == :req ? name : "#{name}: #{name}"
            end.join(", ")
            call_str = "(#{call_str})"
            fetch_key = method.parameters.map(&:last)
            fetch_key = if fetch_key.size > 1
                          "[#{fetch_key.join(', ')}].freeze"
                        else
                          fetch_key.first.to_s
                        end
          else
            # If our method has arguments, we need to separate out our handling
            # of normal args vs. keyword args due to the changes in Ruby 3.
            # See: <link>
            # By only including logic for *args, **kwargs when they are used in
            # the method, we can avoid allocating unnecessary arrays and hashes.
            has_arg = MemoWise::InternalAPI.has_arg?(method)

            if has_arg && MemoWise::InternalAPI.has_kwarg?(method)
              args_str = "(*args, **kwargs)"
              fetch_key = "[args, kwargs].freeze"
            elsif has_arg
              args_str = "(*args)"
              fetch_key = "args"
            else
              args_str = "(**kwargs)"
              fetch_key = "kwargs"
            end
          end

          # Note that we don't need to freeze args before using it as a hash key
          # because Ruby always copies argument arrays when splatted.
          klass.module_eval <<-END_OF_METHOD, __FILE__, __LINE__ + 1
            # def foo(*args, **kwargs)
            #   hash = @_memo_wise.fetch(:foo) do
            #     @_memo_wise[:foo] = {}
            #   end
            #   hash.fetch([args, kwargs].freeze) do
            #     hash[[args, kwargs].freeze] = _memo_wise_original_foo(*args, **kwargs)
            #   end
            # end

            def #{method_name}#{args_str}
              hash = @_memo_wise.fetch(:#{method_name}) do
                @_memo_wise[:#{method_name}] = {}
              end
              hash.fetch(#{fetch_key}) do
                hash[#{fetch_key}] = #{original_memo_wised_name}#{call_str || args_str}
              end
            end
          END_OF_METHOD
        end

        klass.send(visibility, method_name)
      end
    end

    unless target.singleton_class?
      # Create class methods to implement .preset_memo_wise and .reset_memo_wise
      %i[preset_memo_wise reset_memo_wise].each do |method_name|
        # Like calling 'module_function', but original method stays public
        target.define_singleton_method(
          method_name,
          MemoWise.instance_method(method_name)
        )
      end

      # Override [Module#instance_method](https://ruby-doc.org/core-3.0.0/Module.html#method-i-instance_method)
      # to proxy the original `UnboundMethod#parameters` results. We want the
      # parameters to reflect the original method in order to support callers
      # who want to use Ruby reflection to process the method parameters,
      # because our overridden `#initialize` method, and in some cases the
      # generated memoized methods, will have a generic set of parameters
      # (`...` or `*args, **kwargs`), making reflection on method parameters
      # useless without this.
      def target.instance_method(symbol)
        # TODO: Extract this method naming pattern
        original_memo_wised_name = :"_memo_wise_original_#{symbol}"

        super.tap do |curr_method|
          # Start with calling the original `instance_method` on `symbol`,
          # which returns an `UnboundMethod`.
          #   IF it was replaced by MemoWise,
          #   THEN find the original method's parameters, and modify current
          #        `UnboundMethod#parameters` to return them.
          if symbol == :initialize
            # For `#initialize` - because `prepend MemoWise` overrides the same
            # method in the module ancestors, use `UnboundMethod#super_method`
            # to find the original method.
            orig_method = curr_method.super_method
            orig_params = orig_method.parameters
            curr_method.define_singleton_method(:parameters) { orig_params }
          elsif private_method_defined?(original_memo_wised_name)
            # For any memoized method - because the original method was renamed,
            # call the original `instance_method` again to find the renamed
            # original method.
            orig_method = super(original_memo_wised_name)
            orig_params = orig_method.parameters
            curr_method.define_singleton_method(:parameters) { orig_params }
          end
        end
      end
    end
  end

  ##
  # @!method self.memo_wise(method_name)
  #   Implements memoization for the given method name.
  #
  #   - **Q:** What does it mean to "implement memoization"?
  #   - **A:** To wrap the original method such that, for any given set of
  #            arguments, the original method will be called at most *once*. The
  #            result of that call will be stored on the object. All future
  #            calls to the same method with the same set of arguments will then
  #            return that saved result.
  #
  #   Methods which implicitly or explicitly take block arguments cannot be
  #   memoized.
  #
  #   @param method_name [Symbol]
  #     Name of method for which to implement memoization.
  #
  #   @return [void]
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def method_to_memoize(x)
  #         @method_called_times = (@method_called_times || 0) + 1
  #       end
  #       memo_wise :method_to_memoize
  #     end
  #
  #     ex = Example.new
  #
  #     ex.method_to_memoize("a") #=> 1
  #     ex.method_to_memoize("a") #=> 1
  #
  #     ex.method_to_memoize("b") #=> 2
  #     ex.method_to_memoize("b") #=> 2
  ##

  ##
  # @!method self.preset_memo_wise(method_name, *args, **kwargs)
  #   Implementation of {#preset_memo_wise} for class methods.
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def self.method_called_times
  #         @method_called_times
  #       end
  #
  #       def self.method_to_preset
  #         @method_called_times = (@method_called_times || 0) + 1
  #         "A"
  #       end
  #       memo_wise self: :method_to_preset
  #     end
  #
  #     Example.preset_memo_wise(:method_to_preset) { "B" }
  #
  #     Example.method_to_preset #=> "B"
  #
  #     Example.method_called_times #=> nil
  ##

  # rubocop:disable Layout/LineLength
  ##
  # @!method self.reset_memo_wise(method_name = nil, *args, **kwargs)
  #   Implementation of {#reset_memo_wise} for class methods.
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def self.method_to_reset(x)
  #         @method_called_times = (@method_called_times || 0) + 1
  #       end
  #       memo_wise self: :method_to_reset
  #     end
  #
  #     Example.method_to_reset("a") #=> 1
  #     Example.method_to_reset("a") #=> 1
  #     Example.method_to_reset("b") #=> 2
  #     Example.method_to_reset("b") #=> 2
  #
  #     Example.reset_memo_wise(:method_to_reset, "a") # reset "method + args" mode
  #
  #     Example.method_to_reset("a") #=> 3
  #     Example.method_to_reset("a") #=> 3
  #     Example.method_to_reset("b") #=> 2
  #     Example.method_to_reset("b") #=> 2
  #
  #     Example.reset_memo_wise(:method_to_reset) # reset "method" (any args) mode
  #
  #     Example.method_to_reset("a") #=> 4
  #     Example.method_to_reset("b") #=> 5
  #
  #     Example.reset_memo_wise # reset "all methods" mode
  ##
  # rubocop:enable Layout/LineLength

  # Presets the memoized result for the given method to the result of the given
  # block.
  #
  # This method is for situations where the caller *already* has the result of
  # an expensive method call, and wants to preset that result as memoized for
  # future calls. In other words, the memoized method will be called *zero*
  # times rather than once.
  #
  # NOTE: Currently, no attempt is made to validate that the given arguments are
  # valid for the given method.
  #
  # @param method_name [Symbol]
  #   Name of a method previously set up with `#memo_wise`.
  #
  # @param args [Array]
  #   (Optional) If the method takes positional args, these are the values of
  #   position args for which the given block's result will be preset as the
  #   memoized result.
  #
  # @param kwargs [Hash]
  #   (Optional) If the method takes keyword args, these are the keys and values
  #   of keyword args for which the given block's result will be preset as the
  #   memoized result.
  #
  # @yieldreturn [Object]
  #   The result of the given block will be preset as memoized for future calls
  #   to the given method.
  #
  # @return [void]
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #     attr_reader :method_called_times
  #
  #     def method_to_preset
  #       @method_called_times = (@method_called_times || 0) + 1
  #       "A"
  #     end
  #     memo_wise :method_to_preset
  #   end
  #
  #   ex = Example.new
  #
  #   ex.preset_memo_wise(:method_to_preset) { "B" }
  #
  #   ex.method_to_preset #=> "B"
  #
  #   ex.method_called_times #=> nil
  #
  def preset_memo_wise(method_name, *args, **kwargs)
    unless block_given?
      raise ArgumentError,
            "Pass a block as the value to preset for #{method_name}, #{args}"
    end

    api = MemoWise::InternalAPI.new(self)
    api.validate_memo_wised!(method_name)

    if method(method_name).arity.zero?
      @_memo_wise[method_name] = yield
    else
      hash = @_memo_wise.fetch(method_name) do
        @_memo_wise[method_name] = {}
      end
      hash[api.fetch_key(method_name, *args, **kwargs)] = yield
    end
  end

  # Resets memoized results of a given method, or all methods.
  #
  # There are three _reset modes_ depending on how this method is called:
  #
  # **method + args** mode (most specific)
  #
  # - If given `method_name` and *either* `args` *or* `kwargs` *or* both:
  # - Resets *only* the memoized result of calling `method_name` with those
  #   particular arguments.
  #
  # **method** (any args) mode
  #
  # - If given `method_name` and *neither* `args` *nor* `kwargs`:
  # - Resets *all* memoized results of calling `method_name` with any arguments.
  #
  # **all methods** mode (most general)
  #
  # - If *not* given `method_name`:
  # - Resets all memoized results of calling *all methods*.
  #
  # @param method_name [Symbol, nil]
  #   (Optional) Name of a method previously set up with `#memo_wise`. If not
  #   given, will reset *all* memoized results for *all* methods.
  #
  # @param args [Array]
  #   (Optional) If the method takes positional args, these are the values of
  #   position args for which the memoized result will be reset.
  #
  # @param kwargs [Hash]
  #   (Optional) If the method takes keyword args, these are the keys and values
  #   of keyword args for which the memoized result will be reset.
  #
  # @return [void]
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #
  #     def method_to_reset(x)
  #       @method_called_times = (@method_called_times || 0) + 1
  #     end
  #     memo_wise :method_to_reset
  #   end
  #
  #   ex = Example.new
  #
  #   ex.method_to_reset("a") #=> 1
  #   ex.method_to_reset("a") #=> 1
  #   ex.method_to_reset("b") #=> 2
  #   ex.method_to_reset("b") #=> 2
  #
  #   ex.reset_memo_wise(:method_to_reset, "a") # reset "method + args" mode
  #
  #   ex.method_to_reset("a") #=> 3
  #   ex.method_to_reset("a") #=> 3
  #   ex.method_to_reset("b") #=> 2
  #   ex.method_to_reset("b") #=> 2
  #
  #   ex.reset_memo_wise(:method_to_reset) # reset "method" (any args) mode
  #
  #   ex.method_to_reset("a") #=> 4
  #   ex.method_to_reset("b") #=> 5
  #
  #   ex.reset_memo_wise # reset "all methods" mode
  #
  def reset_memo_wise(method_name = nil, *args, **kwargs)
    if method_name.nil?
      unless args.empty?
        raise ArgumentError, "Provided args when method_name = nil"
      end

      unless kwargs.empty?
        raise ArgumentError, "Provided kwargs when method_name = nil"
      end

      return @_memo_wise.clear
    end

    unless method_name.is_a?(Symbol)
      raise ArgumentError, "#{method_name.inspect} must be a Symbol"
    end

    unless respond_to?(method_name, true)
      raise ArgumentError, "#{method_name} is not a defined method"
    end

    api = MemoWise::InternalAPI.new(self)
    api.validate_memo_wised!(method_name)

    if args.empty? && kwargs.empty?
      @_memo_wise.delete(method_name)
    else
      @_memo_wise[method_name]&.
        delete(api.fetch_key(method_name, *args, **kwargs))
    end
  end
end
