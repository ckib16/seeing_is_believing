# WARNING: DO NOT REQUIRE THIS FILE, IT WILL FUCK YOU UP!!!!!!

# READ THIS IF YOU WANT TO USE YOUR OWN MATRIX FILE:
# https://github.com/JoshCheek/seeing_is_believing/issues/24
#
# (or if you want to understand why we do the pipe dance)

require_relative 'version'
require_relative 'event_stream/producer'

event_stream = STDOUT.dup  # duped Ruby object with the real file descriptor
$SiB = SeeingIsBelieving::EventStream::Producer.new(event_stream)

stdout = STDOUT # keep our own ref, b/c user could mess w/ constants and globals
read_stdout, write_stdout = IO.pipe
stdout.reopen(write_stdout)

stderr = STDERR
read_stderr, write_stderr = IO.pipe
stderr.reopen(write_stderr)

at_exit do
  _, blackhole = IO.pipe
  stdout.reopen(blackhole)
  stderr.reopen(blackhole)

  write_stdout.close unless write_stdout.closed?
  $SiB.record_stdout read_stdout.read

  write_stderr.close unless write_stderr.closed?
  $SiB.record_stderr read_stderr.read

  $SiB.record_exception nil, $! if $!
  $SiB.finish!
end
