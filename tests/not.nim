import options, asyncdispatch, httpclient, asyncfile

import ../src/httpx

proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    let file = openAsync("helloworld.nim")
    let value = await file.read(10)
    echo value
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

run(onRequest)