import std/[options, json, asyncdispatch]

import ../src/httpx

proc onRequest(req: Request): Future[void] {.async.} =
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
      await req.respond(Http200, "Hello, World!", headers)
      return
    else:
      req.send(Http200, "Hello, World!", headers)
      return
  of "/bodysize":
    when httpxUseStreams:
      if req.httpMethod == some(HttpGet):
        await req.respond(Http200, "<form enctype=\"multipart/form-data\" action=\"\" method=\"POST\"><input name=\"stuff\" type=\"file\"/><input type=\"submit\"/></form>")
        return

      var len = 0

      # Only try to read the body if the request has a body
      if req.requestBodyStream.isSome:
        let stream = req.requestBodyStream.unsafeGet()

        try:
          while true:
            # Read the chunk
            let chunkRes = await stream.read()

            # If it's None, then the body has been read fully
            if chunkRes.isNone:
              break

            # Since we didn't break, that means this is a readable chunk
            let chunk = chunkRes.unsafeGet()
            len += chunk.len
        except ClientClosedError:
          echo "Client closed prematurely: ", getCurrentExceptionMsg()
          return

      # Return the request body length
      await req.respond(Http200, $len)
    else:
      let len = if req.body.isSome:
        req.body.unsafeGet().len
      else:
        0

      req.send(Http200, $len)
  else:
    when httpxUseStreams:
      await req.respond(Http404)
    else:
      req.send(Http404)

run(onRequest)
