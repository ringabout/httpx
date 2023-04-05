import std/[options, json, asyncdispatch]

import ../src/httpx

proc onRequest(req: Request): Future[void] {.async.} =
  if true or req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})

      when httpxUseStreams:
        await req.respond(Http200, data)
      else:
        req.send(Http200, data)
    of "/plaintext":
      const headers = "Content-Type: text/plain"

      echo "GOT REQ"

      when httpxUseStreams:
        # await req.respond(Http200, "Hello, World!", headers)
        # return

        var len = 0

        if req.requestBodyStream.isSome:
          let stream = req.requestBodyStream.unsafeGet()

          while true:
            echo "ABOUT TO READ"
            let chunkRes = await stream.read()
            if chunkRes.isNone:
              break

            let chunk = chunkRes.unsafeGet()

            echo "Got data with length: ", chunk.len
            len += chunk.len
          
          echo "Finished stream"

        await req.respond(Http200, $len, headers)
      else:
        # TODO REMOVE THIS
        req.send(Http200, "Hello, World!", headers)
        return
    else:
      when httpxUseStreams:
        await req.respond(Http404)
      else:
        req.send(Http404)

run(onRequest)
