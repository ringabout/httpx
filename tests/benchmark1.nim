import options, json

import ../src/httpx
import asyncdispatch

proc onRequest(req: Request): Future[void] =
  #if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})
      req.send(Http200, data)
    of "/hello":
      let data = $req.body.get().len
      const headers = "Content-Type: text/plain"
      proc doThing() {.async.} =
        await sleepAsync(1000)
        echo "Late"
      asyncCheck doThing()
      #poll(0)
      echo "GOT REQUEST"
      req.send(Http200, data, headers)
    else:
      req.send(Http404)

run(onRequest)