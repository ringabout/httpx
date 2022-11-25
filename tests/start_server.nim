import options, asyncdispatch, httpclient

import ../src/httpx

proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.send("Hi World!")
    of "/content":
      req.send("Hi there!")
    else:
      req.send(Http404)
  elif req.httpMethod == some(HttpPost):
    case req.path.get()
    of "/":
      req.send("Successful POST! Data=" & $req.body.get().len)
    else:
      req.send(Http404)
let settings = initSettings(numThreads = 1)
run(onRequest, settings)
