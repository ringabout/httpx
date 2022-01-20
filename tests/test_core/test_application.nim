discard """
  cmd:      "nim c -r --styleCheck:hint --panics:on $options $file"
  matrix:   "--gc:refc"
  targets:  "c"
  action:   "run"
  exitcode: 0
  timeout:  60.0
"""
import httpclient, asyncdispatch, nativesockets
import strformat, os, osproc, terminal, strutils


var process: Process
when defined(windows):
  if not fileExists("tests/start_server.exe"):
    let code = execCmd("nim c --hints:off --verbosity=0 tests/start_server.nim")
    if code != 0:
      raise newException(IOError, "can't compile tests/start_server.nim")
  process = startProcess(expandFileName("tests/start_server.exe"))
else:
  if not fileExists("tests/start_server"):
    let code = execCmd("nim c --hints:off -d:usestd tests/start_server.nim")
    if code != 0:
      raise newException(IOError, "can't compile tests/start_server.nim")
  process = startProcess(expandFileName("tests/start_server"))

proc start() {.async.} =
  let address = "http://127.0.0.1:8080/content"
  for i in 0 .. 20:
    var client = newAsyncHttpClient()
    styledEcho(fgBlue, "Getting ", address)
    let fut = client.get(address)
    yield fut or sleepAsync(4000)
    if not fut.finished:
      styledEcho(fgYellow, "Timed out")
    elif not fut.failed:
      styledEcho(fgGreen, "Server started!")
      return
    else: echo fut.error.msg
    client.close()


waitFor start()


block:
  let
    client = newAsyncHttpClient()
    address = "127.0.0.1"
    port = Port(8080)


  # "can get /"
  block:
    let
      route = "/content"
      response = waitFor client.get(fmt"http://{address}:{port}{route}")

    doAssert response.code == Http200, $response.code
    doAssert (waitFor response.body) == "Hi there!"


  # Simple POST
  block:
    let
      route = "/"
      response = waitFor client.post(fmt"http://{address}:{port}{route}", body="hello")
    
    doAssert response.code == Http200
    doAssert (waitFor response.body) == "Successful POST! Data=5"

  echo "done"
