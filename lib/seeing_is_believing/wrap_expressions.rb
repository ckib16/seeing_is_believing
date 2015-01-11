require 'seeing_is_believing/code'

# comprehensive list of syntaxes that can come up
# https://github.com/whitequark/parser/blob/master/doc/AST_FORMAT.md
class SeeingIsBelieving
  class WrapExpressions

    def self.call(program, wrappings)
      new(program, wrappings).call
    end

    def initialize(program, wrappings)
      self.before_all  = wrappings.fetch :before_all,  -> { '' }
      self.after_all   = wrappings.fetch :after_all,   -> { '' }
      self.before_each = wrappings.fetch :before_each, -> * { '' }
      self.after_each  = wrappings.fetch :after_each,  -> * { '' }
      self.wrappings   = {}
      self.code        = Code.new(program, 'program-without-annotations')
      code.syntax.valid? || raise(::SyntaxError, code.syntax.error_message)
    end

    def call
      @called ||= begin
        wrap_recursive code.root

        rewriter.insert_before root_range, before_all.call

        wrappings.each do |line_num, (range, last_col, meta)|
          rewriter.insert_before range, before_each.call(line_num)
          if meta == :total_fucking_failure
            rewriter.replace range,  '.....TOTAL FUCKING FAILURE!.....'
          end
          rewriter.insert_after range, after_each.call(line_num)
        end

        rewriter.insert_after root_range, after_all_text
        rewriter.process
      end
    end

    private

    attr_accessor :before_all, :after_all, :before_each, :after_each
    attr_accessor :code, :wrappings

    def buffer()          code.buffer            end
    def rewriter()        code.rewriter          end
    def void_value?(ast)  code.void_value?(ast)  end

    def root_range
      code.root.location.expression
    end

    def after_all_text
      after_all_text         = after_all.call
      data_segment_code      = "__END__\n"
      code_after_end_of_file = buffer.source[root_range.end_pos, data_segment_code.size]
      ends_in_data_segment   = code_after_end_of_file.chomp == data_segment_code.chomp
      if ends_in_data_segment
        "#{after_all_text}\n"
      else
        after_all_text
      end
    end

    def add_to_wrappings(range_or_ast, meta=nil)
      range = range_or_ast
      if range.kind_of? ::AST::Node
        location = range_or_ast.location
        # __ENCODING__ becomes:  (const (const nil :Encoding) :UTF_8)
        # Where the inner const doesn't have a location because it doesn't correspond to a real token.
        # There is not currently a way to turn this off, but it would be nice to have one like __LINE__ does
        # https://github.com/whitequark/parser/blob/e2249d7051b1adb6979139928e14a81bc62f566e/lib/parser/builders/default.rb#L333-343
        return unless location.respond_to? :expression
        range = location.expression
      end
      line, col = buffer.decompose_position range.end_pos
      _, prev_col, _ = wrappings[line]
      wrappings[line] = (!wrappings[line] || prev_col < col ? [range, col, meta] : wrappings[line] )
    end

    def add_children(ast, omit_first = false)
      (omit_first ? ast.children.drop(1) : ast.children)
        .each { |child| wrap_recursive child }
    end

    # todo: is this actually add_wrappings
    #       and add_wrappings is actually add_wrapping?
    def wrap_recursive(ast)
      return wrappings unless ast.kind_of? ::AST::Node
      case ast.type
      when :args, :redo, :retry, :alias, :undef, :splat, :match_current_line
        # no op
      when :defs
        add_to_wrappings ast
        add_children ast, true
      when :rescue, :ensure, :return, :break, :next
        add_children ast
      when :if
        if ast.location.kind_of? Parser::Source::Map::Ternary
          add_to_wrappings ast unless ast.children.any? { |child| void_value? child }
          add_children ast
        else
          keyword = ast.location.keyword.source
          if (keyword == 'if' || keyword == 'unless') && ast.children.none? { |child| void_value? child }
            add_to_wrappings ast
          end
          add_children ast
        end
      when :when, :pair, :class, :module, :sclass
        wrap_recursive ast.children.last
      when :resbody
        exception_type, variable_name, body = ast.children
        wrap_recursive body
      when :array
        add_to_wrappings ast
        the_begin = ast.location.begin
        add_children ast if the_begin && the_begin.source !~ /\A%/
      when :block
        add_to_wrappings ast

        # a {} comes in as
        #   (block
        #     (send nil :a)
        #     (args) nil)
        #
        # a.b {} comes in as
        #   (block
        #     (send
        #       (send nil :a) :b)
        #     (args) nil)
        #
        # we don't want to wrap the send itself, otherwise could come in as <a>{}
        # but we do want ot wrap its first child so that we can get <<a>\n.b{}>
        #
        # I can't think of anything other than a :send that could be the first child
        # but I'll check for it anyway.
        the_send = ast.children[0]
        wrap_recursive the_send.children.first if the_send.type == :send
        add_children ast, true
      when :masgn
        # we must look at RHS because [1,<<A] and 1,<<A are both allowed
        #
        # in the first case, we must take the end_pos of the array,
        # or we'll insert the after_each in the wrong location
        #
        # in the second, there is an implicit Array wrapped around it, with the wrong end_pos,
        # so we must take the end_pos of the last arg
        array = ast.children.last
        if array.type != :array # e.g. `a, b = c`
          add_to_wrappings ast
          add_children ast, true
        elsif array.location.expression.source.start_with? '['
          add_to_wrappings ast
          add_children ast, true
        else
          begin_pos = ast.location.expression.begin_pos
          end_pos   = array.children.last.location.expression.end_pos
          range     = code.range_for(begin_pos, end_pos)
          add_to_wrappings range
          add_children ast.children.last
        end
      when :lvasgn,   # a   = 1
           :ivasgn,   # @a  = 1
           :gvasgn,   # $a  = 1
           :cvasgn,   # @@a = 1
           :casgn,    # A   = 1
           :or_asgn,  # a ||= b
           :and_asgn, # a &&= b
           :op_asgn   # a += b, a -= b, a *= b, etc

        # a=b gets wrapped <a=b>
        # but we don't wrap the lvar in `for a in range`
        if ast.children.last.kind_of? ::AST::Node
          begin_pos = ast.location.expression.begin_pos
          end_pos   = ast.children.last.location.expression.end_pos
          range     = code.range_for(begin_pos, end_pos)
          add_to_wrappings range
          add_children ast, true
        end
      when :send
        range = ast.location.expression
        target, message, * = ast.children
        meta = (:total_fucking_failure if message == :__TOTAL_FUCKING_FAILURE__)
        add_to_wrappings ast, meta
        add_children ast
      when :begin
        if ast.location.expression.source.start_with?("(") && # e.g. `(1)` we want `<(1)>`
          !void_value?(ast)                                   # e.g. `(return 1)` we want `(return <1>)`
          add_to_wrappings ast
        end
        add_children ast
      when :str, :dstr, :xstr, :regexp
        add_to_wrappings ast

      when :hash
        # method arguments might not have braces around them
        # in these cases, we want to record the value, not the hash
        add_to_wrappings ast, meta if ast.location.begin
        add_children ast

      else
        add_to_wrappings ast
        add_children ast
      end
    end
  end
end
