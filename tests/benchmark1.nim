import std/[options, json, asyncdispatch]

import ../src/httpx

proc unsafeSleepAsync(ms: int): Future[void] =
  ## Async sleep proc used for testing.
  ## Unsafe to use because it can cause file descriptor exhaustion.
  ## Unlike normal 

  let res = newFuture[void]("unsafeTestSleep")
  addTimer(ms, true, proc (fd: AsyncFD): bool = res.complete())
  return res

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

      when httpxUseStreams:
        # await req.respond(Http200, "Hello, World!", headers)
        # return

        echo "GOT REQ"

        var len = 0
        var contentLen = if req.contentLength.isSome:
          req.contentLength.unsafeGet().int
        else:
          int.high

        if req.requestBodyStream.isSome:
          let stream = req.requestBodyStream.unsafeGet()

          try:
            while true:
              # Test slow body reading
              # For the last 10 chunks, it sleeps between reading to simulate slow stream ingestion
              if len > contentLen - (httpxClientBufSize * 10):
                echo "Sleep"
                await unsafeSleepAsync(250)

              echo "ABOUT TO READ"
              let chunkRes = await stream.read()
              if chunkRes.isNone:
                break

              let chunk = chunkRes.unsafeGet()

              echo "Got data with length: ", chunk.len
              len += chunk.len
            
            echo "Finished stream. Got bytes: ", len
          except ClientClosedError:
            echo "Client closed prematurely; could not read stream"
            return

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
