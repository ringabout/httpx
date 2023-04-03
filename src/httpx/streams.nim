## Asynchronous stream implementation used by the server.
## For a description of how the stream works, see documentation on the AsyncBodyStream type.

import std/[deques, asyncdispatch, options]

{.experimental: "codeReordering".}

type AsyncBodyCb* = proc () {.closure, gcsafe.}
  ## A GC-safe closure callback used for AsyncBodyStream

type AsyncBodyStream* = ref object
  ## # Description
  ## An async body stream for requests and responses.
  ## Uses an internal queue of chunks with a maximum length.
  ## 
  ## ## Behavior of streams with full or empty queues
  ## Writes to a full queue will not complete until at least 1 slot becomes available.
  ## Reads to an empty queue will not complete until at least 1 chunk is written.
  ## 
  ## ## Behavior of finished/completed/failed streams
  ## A stream is considered to be **finished** if it was **completed** or **failed**.
  ## 
  ## If a stream is finished and still has chunks in its queue, the remaining chunks can be read, but no new chunks can be written.
  ## Subsequent reads to a completed stream with an empty queue will immediately return None.
  ## Subsequent reads to a failed stream with an empty queue will immediately raise the exception that the stream was failed with.
  ## 
  ## If a stream is failed, all pending writes will immediately raise the exception that was used to fail the stream.
  ## Subsequent writes to it will also raise the exception.
  ## 
  ## The general concept around finished streams is that queued chunks can be read without any unexpected behavior, but writes cannot be performed.
  ## The reasoning behind this design is that consumers should be able to read the entire stream up until the point where it was completed or failed.
  
  queue: Deque[string]
    ## The body data queue.
    ## The strings are chunks from the body, and their length never exceeds httpxClientBufDefaultSize, but is never smaller than 1.
  
  maxQueueLenInternal: int
    ## Internal property, see maxQueueLen getter

  readCbs: Deque[AsyncBodyCb]
    ## Callbacks to be called when the queue has new data to read.
    ## There is one callback per queue item, and callbacks are called in the order that they were registered.
    ## 
    ## Example scenario:
    ## The queue is empty.
    ## Proc 1 registers cb 1, and then proc 2 registers cb 2.
    ## 3 chunks of data are received.
    ## cb 1 is called for the first chunk, then cb 2 is called for the second chunk, finally the third chunk remains in the queue, ready to be read later.
    ## 
    ## All remaining callbacks will be called when the stream is finished.

  writeCbs: Deque[AsyncBodyCb]
    ## Callbacks to be called when the queue was full but now has a slot free.
    ## There is one callback per queue free slot, and callbacks are called in the order that they were registered.
    ## 
    ## Example scenario:
    ## The queue is full.
    ## Proc 1 registers cb 1, and then proc 2 registers cb 2.
    ## 3 chunks of data are read, and therefore those 3 slots become available.
    ## cb 1 is called for the first slot, then cb 2 is called for the slot chunk, finally the third slot remains free, ready to be written to later.
    ## 
    ## All remaining callbacks will be called when the stream is finished.

  isCompletedInternal: bool
    ## Internal property, see isCompleted getter

  exceptionInternal: Option[ref Exception]
    ## Internal property, see exception getter

proc newAsyncBodyStream*(maxQueueLen: range[1..high(int)]): AsyncBodyStream =
  ## Creates a new AsyncBodyStream
  
  result = new AsyncBodyStream
  result.queue = initDeque[string](maxQueueLen)
  result.maxQueueLenInternal = maxQueueLen
  result.readCbs = initDeque[AsyncBodyCb](1)
  result.writeCbs = initDeque[AsyncBodyCb](1)
  result.isCompletedInternal = false
  result.exceptionInternal = none[ref Exception]()

func isCompleted*(this: AsyncBodyStream): bool {.inline.} =
  ## Whether the stream is completed.
  ## If true, exception will be None.
  
  return this.isCompletedInternal

func isFailed*(this: AsyncBodyStream): bool {.inline.} =
  ## Whether the stream is failed.
  ## If true, exception will be Some.
  
  return this.exceptionInternal.isSome

func isFinished*(this: AsyncBodyStream): bool {.inline.} =
  ## Whether the body stream is either completed or failed.
  ## To check each individually, use isCompleted and isFailed, respectively.
  
  return this.isCompleted or this.isFailed

func exception*(this: AsyncBodyStream): Option[ref Exception] {.inline.} =
  ## The exception that was the cause of the stream failing to be written/read, or none if there was no exception.
  ## If an exception is present, any reads to the stream when the queue is empty will raise this exception.
  ## The isFinished property should be true if this is some.
  
  return this.exceptionInternal

func queueLen*(this: AsyncBodyStream): int {.inline.} =
  ## The current internal queue length

  return this.queue.len

func maxQueueLen*(this: AsyncBodyStream): int {.inline.} =
  ## The maximum queue length
  
  return this.maxQueueLenInternal

proc `=maxQueueLen`*(this: AsyncBodyStream, newLen: range[1..high(int)]) {.inline.} =
  ## Sets the maximum queue length.
  ## Raises ValueError if the new length is less than the current queue length.
  ## Lowering queue size while a stream is active is dangerous because it can lower stream performance.
  ## Changing maximum queue length is expensive because it will result in memory allocation or deallocation.
  
  if unlikely(newLen < this.queue.len):
    raise newException(ValueError, "Cannot lower max queue length lower than the current queue size")

  this.maxQueueLenInternal = newLen

proc write*(this: AsyncBodyStream, chunk: string): Future[void] =
  ## Tries to write the provided chunk to the stream, or raises ValueError if the stream is finished.
  ## If the stream is failed, the exception it failed with will be raised.
  ## If the queue is full, the returned Future will resolve when a queue slot becomes free, or when the stream is completed or failed.
  
  let resFut = newFuture[void]("AsyncBodyStream.write")

  proc mkComplExc(): ref Exception {.inline.} =
    newException(ValueError, "Cannot write to streams that are completed")

  template failAndReturn(exc: ref Exception, inCb: bool = false) =
    resFut.fail(exc)
    when inCb:
      return
    else:
      return resFut

  # Do completed check immediately because the stream may be completed even if the queue is full.
  # If we only did this when there's a free queue slot, then the future would only fail after some data is read, instead of failing immediately.
  if this.isCompleted:
    failAndReturn(mkComplExc())

  template doWrite() =
    # Add chunk to queue and complete future
    this.queue.addLast(chunk)
    resFut.complete()

    # If there is a read callback, run it now
    if this.readCbs.len > 0:
      let cb = this.readCbs.popFirst()
      cb()

  # Check if the queue is full
  if this.queueLen < this.maxQueueLen:
    # The queue has at least 1 free slot; add the chunk to the queue and complete the future (assuming the stream isn't failed).

    if this.isFailed:
      failAndReturn(this.exceptionInternal.unsafeGet())

    doWrite()
  else:
    # The queue is full; wait until there is a free slot, write to it, then complete future
    proc writeCb() {.closure, gcsafe.} =
      # Do necessary checks before writing
      if this.isFailed:
        failAndReturn(this.exceptionInternal.unsafeGet(), inCb = true)
      if this.isCompleted:
        failAndReturn(mkComplExc(), inCb = true)
      
      # We don't need to check whether the queue is full because this callback is only called when a slot becomes free
      doWrite()

    # Add callback to be called when a slot becomes free
    this.writeCbs.addLast(writeCb)
  
  return resFut

proc writeAll*(this: AsyncBodyStream, chunks: seq[string]) {.async.} =
  ## Tries to write the provided chunks to the stream.
  ## See docs on the `write` proc.
  
  for chunk in chunks:
    await this.write(chunk)

proc read*(this: AsyncBodyStream): Future[Option[string]] =
  ## Reads from the stream.
  ## If the stream is complete, None is returned.
  
  let resFut = newFuture[Option[string]]("AsyncBodyStream.read")

  template failAndReturn(exc: ref Exception, inCb: bool = false) =
    resFut.fail(exc)
    when inCb:
      return
    else:
      return resFut
  
  template complAndReturn(val: Option[string], inCb: bool = false) =
    resFut.complete(val)
    when inCb:
      return
    else:
      return resFut

  template doRead() =
    # Add chunk to queue and complete future
    let chunk = this.queue.popFirst()
    resFut.complete(some chunk)

    # If there is a write callback, run it now
    if this.writeCbs.len > 0:
      let cb = this.writeCbs.popFirst()
      cb()

  # Check if the queue is empty
  if this.queueLen > 0:
    # The queue has at least 1 chunk; read the chunk and complete the future (assuming the stream isn't failed).

    if this.isFailed:
      failAndReturn(this.exceptionInternal.unsafeGet())

    doRead()
  elif this.isCompleted:
    # The queue is empty and the stream is completed; complete the future with None
    complAndReturn(none[string]())
  else:
    # The queue is empty; wait until there is a chunk, read it, then complete future
    proc readCb() {.closure, gcsafe.} =
      # Do necessary checks before reading
      if this.isFailed:
        failAndReturn(this.exceptionInternal.unsafeGet(), inCb = true)
      if this.isCompleted and this.queueLen < 1:
        complAndReturn(none[string](), inCb = true)
      
      # We don't need to check whether the queue is empty because this callback is only called when a chunk is written
      doRead()

    # Add callback to be called when a chunk is written
    this.readCbs.addLast(readCb)
  
  return resFut

proc readAll*(this: AsyncBodyStream, expectedLen: Natural = 0): Future[seq[string]] {.async.} =
  ## Reads the entire stream into a seq and returns it.
  ## Note that this proc will use as much memory as the entire result of the stream.
  ## For very large streams or streams of unknown length, this can cause memory exhaustion.
  ## 
  ## If you have an expected stream length, you can provide it as `expectedLen` so that the memory for the seq can be allocated up-front.
  ## Note that this length represents the number of chunks, not the length of the stream result in bytes.
  ## 
  ## See docs on the `read` proc.
  
  var res = newSeq[string](expectedLen)

  while true:
    let chunk = await this.read()

    if chunk.isSome:
      res.add(chunk.unsafeGet())
    else:
      break
  
  return res

proc readToString*(this: AsyncBodyStream, expectedLen: Natural = 0): Future[string] {.async.} =
  ## Reads the entire stream into a string and returns it.
  ## Note that this proc will use as much memory as the entire result of the stream.
  ## For very large streams or streams of unknown length, this can cause memory exhaustion.
  ## 
  ## If you have an expected stream result length in bytes, you can provide it as `expectedLen` so that the memory for the string can be allocated up-front.
  ## 
  ## See docs on the `read` proc.

  var res = newStringOfCap(expectedLen)

  while true:
    let chunk = await this.read()

    if chunk.isSome:
      res.add(chunk.unsafeGet())
    else:
      break
  
  return res

proc complete*(this: AsyncBodyStream) =
  ## Completes the stream.
  ## All pending reads and writes will be immediately failed.
  ## There will only be pending reads if the queue was empty, so subsequent reads to a non-empty queue will still function as normal.
  
  if this.isFinished:
    raise newException(ValueError, "Tried to complete a stream that was already finished")

  this.isCompletedInternal = true

  # Call remaining read and write callbacks now.
  # Calling read callbacks is ok because there should only be read callbacks if the queue is empty.
  while this.readCbs.len > 0:
    let cb = this.readCbs.popFirst()
    cb()
  while this.writeCbs.len > 0:
    let cb = this.writeCbs.popFirst()
    cb()

proc completeWith*(this: AsyncBodyStream, chunk: string) {.async.} =
  ## Writes the provided chunk and then completes the stream.
  ## See docs on the `complete` proc.
  
  await this.write(chunk)
  this.complete()

proc completeWithAll*(this: AsyncBodyStream, chunks: seq[string]) {.async.} =
  ## Writes the provided chunks and then completes the stream.
  ## See docs on the `complete` proc.
  
  await this.writeAll(chunks)
  this.complete()

proc fail*(this: AsyncBodyStream, exc: ref Exception) =
  ## Fails the stream with an exception.
  ## All pending reads and writes will be immediately failed with the provided exception.
  ## There will only be pending reads if the queue was empty, so subsequent reads to a non-empty queue will still function as normal.
  
  if this.isFinished:
    raise newException(ValueError, "Tried to fail a stream that was already finished")

  # Set exception
  this.exceptionInternal = some exc

  # Call remaining read and write callbacks now.
  # Calling read callbacks is ok because there should only be read callbacks if the queue is empty.
  while this.readCbs.len > 0:
    let cb = this.readCbs.popFirst()
    cb()
  while this.writeCbs.len > 0:
    let cb = this.writeCbs.popFirst()
    cb()
