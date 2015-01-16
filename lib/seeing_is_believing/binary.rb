require 'seeing_is_believing'
require 'seeing_is_believing/binary/config'
require 'seeing_is_believing/binary/engine'

class SeeingIsBelieving
  module Binary
    SUCCESS_STATUS              = 0
    DISPLAYABLE_ERROR_STATUS    = 1 # e.g. user code raises an exception (we can display this in the output)
    NONDISPLAYABLE_ERROR_STATUS = 2 # e.g. SiB was invoked incorrectly

    def self.call(argv, stdin, stdout, stderr)
      config = Config.new.parse_args(argv, stderr).finalize(stdin, File)
      engine = Engine.new config

      if config.print_help?
        stdout.puts config.help_screen
        return SUCCESS_STATUS
      end

      if config.print_version?
        stdout.puts SeeingIsBelieving::VERSION
        return SUCCESS_STATUS
      end

      if config.errors.any?
        stderr.puts *config.errors, *config.deprecations
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if config.print_cleaned?
        stdout.print engine.cleaned_body
        return SUCCESS_STATUS
      end

      if engine.syntax_error?
        stderr.puts engine.syntax_error_message
        return NONDISPLAYABLE_ERROR_STATUS
      end

      engine.evaluate!

      if engine.timed_out?
        stderr.puts "Timeout Error after #{config.timeout_seconds} seconds!"
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if config.result_as_json?
        require 'json'
        stdout.puts JSON.dump(engine.results.as_json)
        return SUCCESS_STATUS
      end

      if config.debug?
        config.debugger.context("OUTPUT") { engine.annotated_body }
      else
        stdout.print engine.annotated_body
      end

      if config.inherit_exitstatus?
        engine.results.exitstatus
      elsif engine.results.exitstatus.zero?
        SUCCESS_STATUS
      else
        DISPLAYABLE_ERROR_STATUS
      end
    end
  end
end
