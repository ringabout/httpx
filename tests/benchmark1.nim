import std/[options, json, asyncstreams, asyncdispatch]

import ../src/httpx

proc onRequest(req: Request): Future[void] {.async.} =
  if true or req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})
      req.send(Http200, data)
    of "/plaintext":
      const headers = "Content-Type: text/plain"

      # TODO REMOVE THIS
      req.send(Http200, "Hello, World!", headers)
      return

      # var len = 0

      # if req.requestBodyStream.isSome:
      #   let stream = req.requestBodyStream.unsafeGet()

      #   while true:
      #     let (hasChunk, chunk) = await stream.read()
      #     if not hasChunk:
      #       break

      #     echo "Got data with length: " & $chunk.len
      #     len += chunk.len
        
      #   echo "Finished stream"

      # req.send(Http200, $len, headers)
    else:
      req.send(Http404)

run(onRequest)
