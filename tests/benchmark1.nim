import options, json

import ../src/httpx
import asyncdispatch

proc onRequest(req: Request): Future[void] =
  if true or req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})
      req.send(Http200, data)
    of "/plaintext":
      let data = $req.body.get().len
      #const data = "Hello, World!"
      const headers = "Content-Type: text/plain"
      req.send(Http200, data, headers)
    else:
      req.send(Http404)

run(onRequest)
