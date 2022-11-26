discard """
  cmd:      "nim c -r --styleCheck:hint --panics:on $options $file"
  matrix:   "--gc:refc"
  targets:  "c"
  action:   "run"
  exitcode: 0
  timeout:  60.0
"""
import httpclient, asyncdispatch, nativesockets
import strformat, os, httpcore
import uri

import ../start_server

proc expect(resp: Response, code: HttpCode, body: string) =
  doAssert resp.code == code, $resp.code
  doAssert resp.body == body, body

var serverThread: Thread[void]

createThread(serverThread, proc () = run(onRequest))

block:
  let
    client = newHttpClient()
    address = "127.0.0.1"
    port = Port(8080)
    root = parseUri(fmt"http://{address}:{port}")
  sleep 100 # Give server some time to start

  # "can get /"
  block:
    const expectedBody = "Hi there!"
    let resp = client.get(root / "content")
    resp.expect(Http200, expectedBody)
    doAssert resp.headers["Content-Length"] == $expectedBody.len

  # Simple POST
  block:
    client
      .post(root, body="hello")
      .expect(Http200, "Successful POST! Data=5")

  # Can POST body have http method names in it
  block issue13:
    const body = """PUT-----------------------------232440040922467123362217795696
Content-Disposition: form-data; name="request-type"

PUT
-----------------------------232440040922467123362217795696--"""
    let headers = newHttpHeaders {
      "Content-Type": "multipart/form-data; boundary=---------------------------180081423920632275152985699863",

    }
    client
      .request(root / "issues/13", HttpPost, body = body, headers = headers)
      .expect(Http200, "/issues/13")

  block allowNoContentLength:
    let resp = client.request(root / "chunked")
    resp.expect(Http200, "HelloWorld")
    doAssert not resp.headers.hasKey("Content-Length")

  echo "done"
  quit 0
