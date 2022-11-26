import options, asyncdispatch, httpclient
import strutils
import ../src/httpx

proc onRequest*(req: Request) {.async.} =
  assert "form-data" notin req.path.get() # See issue13 test
  case req.httpMethod.get()
  of HttpGet:
    case req.path.get()
    of "/":
      req.send("Hi World!")
    of "/content":
      req.send("Hi there!")
    of "/chunked":
      req.send(Http200, "A\r\nHelloWorld\r\n0\r\n\r\n", none int, "Transfer-Encoding: chunked")
    else:
      req.send(Http404)
  of HttpPost:
    case req.path.get()
    of "/":
      req.send("Successful POST! Data=" & $req.body.get().len)
    of "/issues/13":
      req.send(req.path.get())
    else:
      req.send(Http404)
  else: discard

export httpx
