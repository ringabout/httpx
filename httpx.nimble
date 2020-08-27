# Package

version       = "0.1.0"
author        = "Zeshen Xing"
description   = "A super-fast epoll-backed and parallel HTTP server."
license       = "MIT"

srcDir = "src"

# Dependencies


requires "nim >= 1.2.0"
requires "ioselectors >= 0.1.0"


task helloworld, "Compiles and executes the hello world server.":
  exec "nim c -d:release -r tests/helloworld"

task dispatcher, "Compiles and executes the dispatcher test server.":
  exec "nim c -d:release -r tests/dispatcher"

task tests, "Runs the test suite.":
  exec "testament all"
