#         MIT License
# Copyright (c) 2020 Dominik Picheta
#
# Copyright 2020 Zeshen Xing
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# TODO Create configurable constant for max headers size (default to 8KiB)

import net, nativesockets, os, httpcore, asyncdispatch, strutils
import options, logging, times, heapqueue, std/monotimes
import std/sugar

import deques

import ioselectors

import httpx/parser

const useWinVersion   = defined(windows) or defined(nimdoc)
const usePosixVersion = defined(posix) and not defined(nimdoc)

when useWinVersion:
  import sets
else:
  import posix
  from osproc import countProcessors

export httpcore

const httpxUseStreams* {.booldefine.} = true
  ## Whether to expose stream APIs using FutureStream instead of buffering requests and responses internally.
  ## Defaults to true.

const httpxMaxStreamQueueLength* {.intdefine.} = 4
  ## The maximum number of buffers to queue in request body streams.
  ## Defaults to 4.
  ## 
  ## To calculate the maximum request body queue size in bytes, multiply this value with the value of httpxClientBufSize.
  ## 
  ## Note that this has no effect on response body streams, as user-defined handlers are in charge of writing to them, and therefore cannot be directly governed by this constant.

when httpxMaxStreamQueueLength < 1:
  {.fatal: "Max stream queue length must be at least 1".}

const httpxDefaultServerName* = "Nim-HTTPX"
  ## The default server name sent in the Server header in responses.
  ## A custom name can be set by defining httpxServerName at compile time.

const serverInfo {.strdefine.}: string = httpxDefaultServerName
  ## Alias to httpxServerName, use that instead

const httpxServerName* {.strdefine.} =
  when serverInfo != httpxDefaultServerName:
    {.warning: "Setting the server name with serverInfo is deprecated. You should use httpxServerName instead.".}
    serverInfo
  else:
    httpxDefaultServerName
  ## The server name sent in the Server header in responses.
  ## If not defined, the value of httpxDefaultServerName will be used.
  ## If the value is empty, no Server header will be sent.

const httpxClientBufDefaultSize* = 256
  ## The default size of the client read buffer.
  ## A custom size can be set by defining httpxClientBufSize.

const httpxClientBufSize* {.intdefine.} = httpxClientBufDefaultSize
  ## The size of the client read buffer.
  ## Defaults to httpxClientBufDefaultSize.

# Ensure client buffer size meets the minimum, and warn on unrealistically tiny values
when httpxClientBufSize < 3:
  {.fatal: "Client buffer size must be at least 3, and ideally at least 256.".}
elif httpxClientBufSize < httpxClientBufDefaultSize:
  {.warning: "You should set your client read buffer size to at least 256 bytes. Smaller buffers will harm performance.".}

const httpxSendServerDate* {.booldefine.} = true
  ## Whether to send the current server date along with requests.
  ## Defaults to true.

when httpxUseStreams:
  import httpx/streams

type
  FdKind = enum
    Server, Client, Dispatcher

  Data = object
    fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
                   ## - Client specific data.
                   ## A queue of data that needs to be sent when the FD becomes writeable.
    
    when not httpxUseStreams:
      sendQueue: string
        ## The response send queue string.
        ## When httpxUseStreams is true, you will need to use responseStream instead.
    
      bytesSent: int
        ## The number of characters in `sendQueue` that have been sent already.
        ## This is used as a cursor for writing to client sockets.

    data: string
      ## Big chunk of data read from client during request
    
    headersFinished: bool
      ## Determines whether `data` contains "\c\l\c\l"
    
    headersFinishPos: int
      ## Determines position of the end of "\c\l\c\l"

    ip: string
      ## The address that a `client` connected from

    reqFut: Future[void]
      ## Future for onRequest handler (may be nil).

    requestID: uint
      ## Identifier for current request. Mainly for better detection of cross-talk.

    contentLength: Option[BiggestUInt]
      ## The request's content length, or none if it has no body or headers haven't been read yet

    when httpxUseStreams:
      createdRequest: bool
        ## Whether a request for the data has been created

      requestBodyStream: AsyncStream[string]
        ## The request body stream
      
      responseStream: AsyncStream[string]
        ## The response data stream.
        ## Different from a body stream because the response headers are also written to this stream.
      
      isBodyFinished: bool
        ## Whether the request body was read entirely
      
      bodyBytesRead: BiggestUInt
        ## The number of bytes from the request body that have been read

type
  Request* = object
    ## An HTTP request

    selector: Selector[Data]
      ## The internal selector used to communicate with the client socket

    client*: SocketHandle
      ## The underlying operating system socket handle associated with the request client connection.
      ## May be closed; you should check by calling "closed" on this Request object before interacting with its client socket.

    contentLength*: Option[BiggestUInt]
      ## The request's content length, or none if no Content-Length header was provided

    requestID: uint
      ## Identifier used to distinguish requests

    when httpxUseStreams:
      requestBodyStream*: Option[AsyncStream[string]]
        ## The request's body stream, or none if the request does not (or cannot) have a body.
        ## Through this stream, a request body can be streamed without buffering its entirety to memory.
        ## Useful for file uploads and similar.

      responseStream*: AsyncStream[string]
        ## The response data stream.
        ## Useful for writing responses with an unknown size, such as data that is being generated on the fly.
        ## Note that writing to this before calling writeHeaders will require the caller to write HTTP headers manually, because this is not strictly a response body stream.

  OnRequest* = proc (req: Request): Future[void] {.gcsafe, gcsafe.}
    ## Callback used to handle HTTP requests

  Startup = proc () {.closure, gcsafe.}

  Settings* = object
    ## HTTP server settings
    
    port*: Port
      ## The port to bind to

    bindAddr*: string
      ## The address to bind to

    numThreads: int
      ## The number of threads to serve on

    startup: Startup

  HttpxDefect* = ref object of Defect
    ## Defect raised when something HTTPX-specific fails
  
  HttpxError* = ref object of CatchableError
    ## Error raised when something HTTPX-specific fails
  
  ClientClosedError* = object of HttpxError
    ## Error raised when interaction or a read is attempted on a closed client

when httpxSendServerDate:
  # We store the current server date here as a thread var and update it periodically to avoid checking the date each time we respond to a request.
  # The date is updated every second from within the event loop.
  var serverDate {.threadvar.}: string


when usePosixVersion:
  let osMaxFdCount = selectors.maxDescriptors()
    ## The maximum number of file descriptors allowed at one time by the OS

proc doNothing(): Startup {.gcsafe.} =
  result = proc () {.closure, gcsafe.} =
    discard

func initSettings*(port = Port(8080),
                   bindAddr = "",
                   numThreads = 0,
                   startup: Startup = doNothing(),
): Settings =
  ## Creates a new HTTP server Settings object with the provided options.

  result = Settings(
    port: port,
    bindAddr: bindAddr,
    numThreads: numThreads,
    startup: startup
  )

func initData(fdKind: FdKind, ip = ""): Data =
  when httpxUseStreams:
    return Data(fdKind: fdKind,
        data: "",
        headersFinished: false,
        headersFinishPos: -1, # By default we assume the fast case: end of data.
        ip: ip,
        contentLength: none[BiggestUInt](),
        requestBodyStream: newAsyncStream[string](httpxMaxStreamQueueLength),
        responseStream: newAsyncStream[string](httpxMaxStreamQueueLength),
    )
  else:
    return Data(fdKind: fdKind,
        sendQueue: "",
        bytesSent: 0,
        data: "",
        headersFinished: false,
        headersFinishPos: -1, ## By default we assume the fast case: end of data.
        ip: ip,
        contentLength: none[BiggestUInt](),
    )


template withRequestData(req: Request, body: untyped) =
  let requestData {.inject.} = addr req.selector.getData(req.client)
  body

#[ API start ]#

func closed*(req: Request): bool {.inline, raises: [].} =
  ## If the client has disconnected from the server or not.
  result = req.client notin req.selector

func genHttpResponse*(code: HttpCode, contentLength: Option[BiggestUInt]|Option[int], headers: HttpHeaders|string): string {.inline.} =
    ## Generates an HTTP response string (without a body) and returns it.
    ## Includes server name and current server date if enabled.
    ## 
    ## **IMPORTANT**: Headers are not sanitized. Do not use unsanitized user input as header names or values, otherwise a bad actor can forge responses.

    let otherHeaders =
      if likely(headers.len != 0):
        when headers is HttpHeaders:
          var str = "\c\L"

          # Append headers
          var isFirstHeader = true
          for (key, val) in headers.pairs:
            if likely(not isFirstHeader):
              str &= '\n'
            else:
              isFirstHeader = false

            str &= key & ": " & val

          str
        else:
          "\c\L" & headers
      else:
        ""
  
    result = "HTTP/1.1 " & $code
    if contentLength.isSome:
      result &= "\c\LContent-Length: "
      result.addInt(contentLength.unsafeGet())
    
    when httpxServerName != "":
      result &= "\c\LServer: " & httpxServerName
    
    when httpxSendServerDate:
      result &= "\c\LDate: " & serverDate
    
    result &= otherHeaders
    result &= "\c\L\c\L"

# There is a different API for streams
when httpxUseStreams:
  proc writeHeaders*(req: Request, code: HttpCode, contentLen: Option[BiggestUInt] = none[BiggestUInt](), headers: HttpHeaders|string = "") {.inline, async.} =
    ## Writes response headers, but does not complete the response stream.
    ## It is the responsibility of the caller to write any desired body data and to ultimately complete the response stream.
    ##
    ## Headers can be an instance of HttpHeaders, or a raw string.
    ##
    ## **IMPORTANT**: Headers are not sanitized by this proc.
    ## You should not use unsanitized user input for header names or values, otherwise a bad actor could manipulate responses.
    ## Specifically, headers containing control characters such as newlines or carriage returns are dangerous.
    
    await req.responseStream.write(genHttpResponse(code, contentLen, headers))

  proc respond*(req: Request, code: HttpCode, body: string = "", headers: HttpHeaders|string = "") {.inline, async.} =
    ## Sends a response with an HTTP status code, optionally with a response body, and completes the response.
    ## 
    ## If you want to write headers and then write your own response body using the response stream directly, use the writeHeaders proc and the responseStream property manually.
    ## 
    ## Headers can be an instance of HttpHeaders, or a raw string.
    ## 
    ## **IMPORTANT**: Headers are not sanitized by this proc.
    ## You should not use unsanitized user input for header names or values, otherwise a bad actor could manipulate responses.
    ## Specifically, headers containing control characters such as newlines or carriage returns are dangerous.
    
    # Write headers first
    await req.writeHeaders(
      code,
      contentLen = some body.len.BiggestUInt,
      headers = headers,
    )

    # Finally, write body.
    # We write the body as a second chunk because some clients may choose to disconnect before reading the body.
    await req.responseStream.completeWith(body)

else:
  proc unsafeSend*(req: Request, data: string) {.inline.} =
    ## Sends the specified data on the request socket.
    ##
    ## This function can be called as many times as necessary.
    ##
    ## It does not check whether the socket is in a state
    ## that can be written so be careful when using it.

    if req.closed:
      return

    withRequestData(req):
      requestData.sendQueue.add(data)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

  proc send*(req: Request, code: HttpCode, body: string, contentLength: Option[int], headers = "") {.inline.} =
    ## Responds with the specified HttpCode and body.
    ##
    ## **Warning:** This can only be called once in the OnRequest callback.

    if req.closed:
      return

    withRequestData(req):
      assert requestData.headersFinished, "Selector for $1 not ready to send." % $req.client.int
      if requestData.requestID != req.requestID:
        raise HttpxDefect(msg: "You are attempting to send data to a stale request.")

      let res = genHttpResponse(code, contentLength, headers)

      requestData.sendQueue.add(res & body)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

  proc send*(req: Request, code: HttpCode, body: string, contentLength: Option[string],
            headers = "") {.inline, deprecated: "Use Option[int] for contentLength parameter".} =
    req.send(code, body, some parseInt(contentLength.get($body.len)), headers)

  template send*(req: Request, code: HttpCode, body: sink string, headers = "") =
    ## Responds with the specified HttpCode and body.
    ##
    ## **Warning:** This can only be called once in the OnRequest callback.

    req.send(code, body, some body.len, headers)

  proc send*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    assert req.selector.getData(req.client).requestID == req.requestID
    req.send(code, $code)

  proc send*(req: Request, body: sink string, code = Http200) {.inline.} =
    ## Sends a HTTP 200 OK response with the specified body.
    ##
    ## **Warning:** This can only be called once in the OnRequest callback.
    req.send(code, body)

template tryAcceptClient() =
  ## Tries to accept a client, but does nothing if one cannot be accepted (due to file descriptor exhaustion, etc)

  let (client, address) = fd.SocketHandle.accept
  if client == osInvalidSocket:
    let lastError = osLastError()

    when usePosixVersion:
      if lastError.int32 == EMFILE:
        warn("Ignoring EMFILE error: ", osErrorMsg(lastError))
        return

    raiseOSError(lastError)

  setBlocking(client, false)

  template regHandle() =
    selector.registerHandle(client, {Event.Read}, initData(Client, ip = address))

  when usePosixVersion:
    # Only register the handle if the file descriptor count has not been reached
    if likely(client.int < osMaxFdCount):
      regHandle()
  else:
    regHandle()

proc closeClient(
  data: ptr Data,
  selector: Selector[Data],
  fd: SocketHandle,
  inLoop = true,
) {.inline.} =
  # TODO: Can POST body be sent with Connection: Close?

  var reqBodyStream = data.requestBodyStream

  template doClose() =
    fd.close()

    when httpxUseStreams:
      # Fail request body stream if not already finished
      if not reqBodyStream.isFinished:
        reqBodyStream.fail(newException(ClientClosedError, "Client connection was closed before the full request body could be received"))

  let isRequestComplete = data.reqFut.isNil or data.reqFut.finished
  if isRequestComplete:
    # The `onRequest` callback isn't in progress, so we can close the socket.
    selector.unregister(fd)
    doClose()
  else:
    # Close the socket only once the `onRequest` callback completes.
    data.reqFut.addCallback(
      proc (fut: Future[void]) =
        doClose()
    )
    # Unregister fd so that we don't receive any more events for it.
    # Once we do so the `data` will no longer be accessible.
    selector.unregister(fd)

  logging.debug("socket: " & $fd.int & " is closed!")

proc onRequestFutureComplete(theFut: Future[void],
                             selector: Selector[Data], fd: int) =
  if theFut.failed:
    raise theFut.error

template fastHeadersCheck(data: ptr Data): bool =
  let res = data.data[^1] == '\l' and data.data[^2] == '\c' and
             data.data[^3] == '\l' and data.data[^4] == '\c'
  if res: 
    data.headersFinishPos = data.data.len
  res

template methodNeedsBody(data: ptr Data): bool =
  # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
    # never need a body, so we just assume `start` at 0.
  let reqMthod = parseHttpMethod(data.data)
  reqMthod.isSome and (reqMthod.get in {HttpPost, HttpPut, HttpConnect, HttpPatch})

proc slowHeadersCheck(data: ptr Data): bool =
  if unlikely(methodNeedsBody(data)):
    # Look for \c\l\c\l inside data.
    data.headersFinishPos = 0
    template ch(i: int): char =
      let pos = data.headersFinishPos + i
      if pos >= data.data.len: 
        '\0'
      else:
        data.data[pos]

    while data.headersFinishPos < data.data.len:
      case ch(0)
      of '\c':
        if ch(1) == '\l' and ch(2) == '\c' and ch(3) == '\l':
          data.headersFinishPos.inc(4)
          return true
      else: 
        discard
      inc data.headersFinishPos

    data.headersFinishPos = -1

proc bodyInTransit(data: ptr Data): bool =
  # get, head, put, delete
  assert methodNeedsBody(data), "Calling bodyInTransit now is inefficient."
  assert data.headersFinished

  if data.headersFinishPos == -1: 
    return false

  if unlikely(data.contentLength.isNone):
    data.contentLength = some parseContentLength(data.data)

  let contentLen = data.contentLength.unsafeGet()

  let bodyLen =
    when httpxUseStreams:
      data.bodyBytesRead
    else:
      (data.data.len - data.headersFinishPos).BiggestUInt

  assert(not (bodyLen > contentLen))

  return bodyLen < contentLen

var requestCounter: uint = 0
proc genRequestID(): uint =
  if requestCounter == high(uint):
    requestCounter = 0
  requestCounter += 1
  return requestCounter

proc validateRequest(req: Request): bool {.gcsafe.}

proc processEvents(selector: Selector[Data],
                   events: array[64, ReadyKey], count: int,
                   onRequest: OnRequest) =

  var buf: array[httpxClientBufSize, char]

  for i in 0 ..< count:
    let fd = events[i].fd
    var data: ptr Data = addr(getData(selector, fd))
    # Handle error events first.
    if Event.Error in events[i].events:
      if isDisconnectionError({SocketFlag.SafeDisconn},
                              events[i].errorCode):

        when httpxUseStreams:
          data.requestBodyStream.complete()
        closeClient(data, selector, fd.SocketHandle)
        break
      raiseOSError(events[i].errorCode)

    case data.fdKind
    of Server:
      if Event.Read in events[i].events:
        tryAcceptClient()
      else:
        doAssert false, "Only Read events are expected for the server"
    of Dispatcher:
      # Run the dispatcher loop.
      when usePosixVersion:
        assert events[i].events == {Event.Read}
        asyncdispatch.poll(0)
      else:
        discard
    of Client:
      if Event.Read in events[i].events:
        let disp = getGlobalDispatcher()

        # Read until EAGAIN. We take advantage of the fact that the client
        # will wait for a response after they send a request. So we can
        # comfortably continue reading until the message ends with \c\l
        # \c\l.
        while true:
          # If the request body stream queue is full, wait until it stops being full
          when httpxUseStreams:
            if unlikely(data.requestBodyStream.queueLen >= httpxMaxStreamQueueLength):
              ## TODO Set callback
              break

          proc doRecv(fd: SocketHandle): (int, bool) =
            ## Tries to read from the socket and returns a tuple of the returned amount (or -1 if there was an error), and whether the loop it was called from (if any) should be broken from

            let ret = recv(fd, addr buf[0], httpxClientBufSize, 0.cint)

            template shouldBreak =
              return (ret, true)

            if ret == 0:
              closeClient(data, selector, fd)
              shouldBreak()

            if ret == -1:
              # Error!
              let lastError = osLastError()

              when usePosixVersion:
                if lastError.int32 in [EWOULDBLOCK, EAGAIN]:
                  shouldBreak()
              else:
                if lastError.int == WSAEWOULDBLOCK:
                  shouldBreak()

              if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
                closeClient(data, selector, fd)
                shouldBreak()
              raiseOSError(lastError)
            
            return (ret, false)

          let (ret, shouldBreak) = doRecv(fd.SocketHandle)
          if shouldBreak:
            break

          template writeBuf() =
            # Write buffer to our data.
            let origLen = data.data.len
            data.data.setLen(origLen + ret)
            for i in 0 ..< ret:
              data.data[origLen + i] = buf[i]

          when httpxUseStreams:
            if not data.headersFinished:
              writeBuf()
          else:
            writeBuf()

          if data.data.len >= 4 and (fastHeadersCheck(data) or slowHeadersCheck(data)):
            template createRequest(needsBody: bool = false) =
              data.requestID = genRequestID()

              let request =
                when httpxUseStreams:
                  Request(
                    selector: selector,
                    client: fd.SocketHandle,
                    requestID: data.requestID,
                    requestBodyStream:
                      if needsBody:
                        some data.requestBodyStream
                      else:
                        none[AsyncStream[string]](),
                    responseStream: newAsyncStream[string](httpxMaxStreamQueueLength)
                  )
                else:
                  Request(
                    selector: selector,
                    client: fd.SocketHandle,
                    requestID: data.requestID,
                  )

              when httpxUseStreams:
                data.createdRequest = true

              template validateResponse(data: ptr Data): untyped =
                if data.requestID == request.requestID:
                  data.headersFinished = false

              if validateRequest(request):
                data.reqFut = onRequest(request)
                if not data.reqFut.isNil:
                  capture data:
                    data.reqFut.addCallback(
                      proc (fut: Future[void]) =
                        onRequestFutureComplete(fut, selector, fd)
                        validateResponse(data)
                    )
                else:
                  validateResponse(data)

            # First line and headers for request received.
            data.headersFinished = true
            when not defined(release):
              when httpxUseStreams:
                if data.responseStream.queueLen != 0:
                  logging.warn("responseStream queue isn't empty")
              else:
                if data.sendQueue.len != 0:
                  logging.warn("sendQueue isn't empty.")
                if data.bytesSent != 0:
                  logging.warn("bytesSent isn't empty.")  

            when httpxUseStreams:
              if data.headersFinished and not data.createdRequest:
                createRequest(methodNeedsBody(data))

                # Write any part of the data past the headers to the body stream
                let bodyChunkLen = data.headersFinishPos - data.data.len
                if bodyChunkLen > 0:
                  var bodyChunk = data.data.substr(data.headersFinishPos, data.data.len)

                  # TODO Figure out what needs to be done here in terms of full queue
                  asyncCheck data.requestBodyStream.write(bodyChunk)
                  data.bodyBytesRead += bodyChunkLen.BiggestUInt

                  data.data.setLen(data.headersFinishPos)
              else:
                var chunk = newString(ret)
                for i in 0 ..< ret:
                  chunk[i] = buf[i]

                # TODO Figure out what needs to be done here in terms of full queu
                asyncCheck data.requestBodyStream.write(chunk)
                data.bodyBytesRead += ret.BiggestUInt

                if unlikely(disp.callbacks.len > 0):
                  asyncdispatch.poll(0)

            let waitingForBody = methodNeedsBody(data) and bodyInTransit(data)
            if likely(not waitingForBody):
              # For pipelined requests, we need to reset this flag.
              data.headersFinished = true
              
              when httpxUseStreams:
                data.requestBodyStream.complete()
              else:
                createRequest()

          if ret != httpxClientBufSize:
            # Assume there is nothing else for us right now and break.
            break
      elif Event.Write in events[i].events:
        # TODO Figure out best way to do this

        when httpxUseStreams:
          assert data.responseStream.queueLen > 0
        else:
          assert data.sendQueue.len > 0
          assert data.bytesSent < data.sendQueue.len

        # Write to the response.
        #
        # When streams are not enabled, a response buffer and a write cursor is stored.
        # This is fast to write, but the entire response must be kept in memory.
        # This means that responses cannot be streamed.
        #
        # When streams are enabled, a chunk is popped from the beginning of the stream queue.
        # If the chunk was only written partially, the remaining portion of the chunk will be pushed back to the beginning of the queue.
        # This means that very large chunks should not be written to the stream because it could lead to frequent truncation of chunks and then needing to prepend them back into the queue.
        # It is safe to truncate and move chunks back into the queue because if the write was successful, the OS has already copied those bytes into its internal buffer, and no longer needs to reference our chunk's memory.

        when httpxUseStreams:
          ## TODO
        else:
          let leftover =
            when usePosixVersion:
              data.sendQueue.len - data.bytesSent
            else:
              cint(data.sendQueue.len - data.bytesSent)
          let ret = fd.SocketHandle.send(addr data.sendQueue[data.bytesSent], leftover, 0)

          if ret == -1:
            # Error!
            let lastError = osLastError()

            when usePosixVersion:
              if lastError.int32 in [EWOULDBLOCK, EAGAIN]:
                break
            else:
              if lastError.int == WSAEWOULDBLOCK:
                break

            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              closeClient(data, selector, fd.SocketHandle)
              break
            raiseOSError(lastError)

          data.bytesSent.inc(ret)

          if data.sendQueue.len == data.bytesSent:
            data.bytesSent = 0
            data.sendQueue.setLen(0)
            data.data.setLen(0)
            selector.updateHandle(fd.SocketHandle,
                                  {Event.Read})
      else:
        assert false

when httpxSendServerDate:
  proc updateDate(fd: AsyncFD): bool =
    result = false # Returning true signifies we want timer to stop.
    serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc eventLoop(params: (OnRequest, Settings)) =
  let 
    (onRequest, settings) = params
    selector = newSelector[Data]()
    server = newSocket()

  if settings.startup != nil:
    settings.startup()

  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(settings.port, settings.bindAddr)
  server.listen()
  server.getFd.setBlocking(false)
  selector.registerHandle(server.getFd, {Event.Read}, initData(Server))

  when httpxSendServerDate:
    # Set up timer to get current date/time.
    discard updateDate(0.AsyncFD)
    asyncdispatch.addTimer(1000, false, updateDate)

  # Add dummy timer that ensures timers registered in request handlers are called
  asyncdispatch.addTimer(0, false, proc (fd: AsyncFD): bool = false)

  let disp = getGlobalDispatcher()

  when usePosixVersion:
    selector.registerHandle(disp.getIoHandler.getFd, {Event.Read},
                          initData(Dispatcher))

    var events: array[64, ReadyKey]
    while true:
      let ret = selector.selectInto(-1, events)
      processEvents(selector, events, ret, onRequest)

      # Ensure callbacks list doesn't grow forever in asyncdispatch.
      # See https://github.com/nim-lang/Nim/issues/7532.
      # Not processing callbacks can also lead to exceptions being silently
      # lost!
      if unlikely(disp.callbacks.len > 0):
        asyncdispatch.poll(0)
  else:
    var events: array[64, ReadyKey]
    while true:
      let ret =
        if disp.timers.len > 0:
          selector.selectInto((disp.timers[0].finishAt - getMonoTime()).inMilliseconds.int, events)
        else:
          selector.selectInto(20, events)

      if ret > 0:
        processEvents(selector, events, ret, onRequest)
      
      asyncdispatch.poll(0)

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).data)

proc path*(req: Request): Option[string] {.inline.} =
  ## Parses the request's data to find the request target.
  if unlikely(req.client notin req.selector):
    return
  parsePath(req.selector.getData(req.client).data)

proc headers*(req: Request): Option[HttpHeaders] =
  ## Parses the request's data to get the headers.
  if unlikely(req.client notin req.selector):
    return
  parseHeaders(req.selector.getData(req.client).data)

proc body*(req: Request): Option[string] =
  ## Retrieves the body of the request.
  let pos = req.selector.getData(req.client).headersFinishPos
  if pos == -1: 
    return none(string)
  result = some(req.selector.getData(req.client).data[pos .. ^1])

  when not defined(release):
    let length =
      if req.headers.get.hasKey("Content-Length"):
        req.headers.get["Content-Length"].parseInt
      else:
        0
    doAssert result.get.len == length

proc ip*(req: Request): string =
  ## Retrieves the IP address that the request was made from.
  req.selector.getData(req.client).ip

proc forget*(req: Request) =
  ## Unregisters the underlying request's client socket from httpx's
  ## event loop.
  ##
  ## This is useful when you want to register ``req.client`` in your own
  ## event loop, for example when wanting to integrate httpx into a
  ## websocket library.
  req.selector.unregister(req.client)

proc validateRequest(req: Request): bool =
  ## Handles protocol-mandated responses.
  ##
  ## Returns ``false`` when the request has been handled.
  result = true

  # From RFC7231: "When a request method is received
  # that is unrecognized or not implemented by an origin server, the
  # origin server SHOULD respond with the 501 (Not Implemented) status
  # code."
  if req.httpMethod.isNone:
    when httpxUseStreams:
      asyncCheck req.respond(Http501)
    else:
      req.send(Http501)
    result = false

proc run*(onRequest: OnRequest, settings: Settings) =
  ## Starts the HTTP server and calls `onRequest` for each request.
  ##
  ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
  ## unlike most asynchronous procedures in Nim, it can return ``nil``
  ## for better performance, when no async operations are needed.
  when not useWinVersion:
    when compileOption("threads"):
      let numThreads =
        if settings.numThreads == 0: 
          countProcessors()
        else: 
          settings.numThreads
    else:
      let numThreads = 1

    logging.debug("Starting ", numThreads, " threads")

    if numThreads > 1:
      when compileOption("threads"):
        var threads = newSeq[Thread[(OnRequest, Settings)]](numThreads)
        for i in 0 ..< numThreads:
          createThread[(OnRequest, Settings)](
            threads[i], eventLoop, (onRequest, settings)
          )
        
        logging.debug("Listening on port ",
            settings.port) # This line is used in the tester to signal readiness.
        
        joinThreads(threads)
      else:
        doAssert false, "Please enable threads when numThreads is greater than 1!"
    else:
      eventLoop((onRequest, settings))
  else:
    eventLoop((onRequest, settings))
    logging.debug("Starting ", 1, " threads")

proc run*(onRequest: OnRequest) {.inline.} =
  ## Starts the HTTP server with default settings. Calls `onRequest` for each
  ## request.
  ##
  ## See the other ``run`` proc for more info.
  run(onRequest, Settings(port: Port(8080), bindAddr: "", startup: doNothing()))

when false:
  proc close*(port: Port) =
    ## Closes an httpx server that is running on the specified port.
    ##
    ## **NOTE:** This is not yet implemented.

    doAssert false
    # TODO: Figure out the best way to implement this. One way is to use async
    # events to signal our `eventLoop`. Maybe it would be better not to support
    # multiple servers running at the same time?
