import std/[deques, asyncdispatch, options]

{.experimental: "codeReordering".}

type AsyncBodyCb = proc () {.closure, gcsafe.}
  ## A GC-safe closure callback used for AsyncBodyStream

type AsyncBodyStream* = ref object
  ## An async body stream for requests and responses.
  ## We use this instead of FutureStream because we need more fine-grained and stable control over the stream and how it behaves.
  
  queue: Deque[string]
    ## The body data queue.
    ## The strings are chunks from the body, and their length never exceeds httpxClientBufDefaultSize, but is never smaller than 1.
  
  maxQueueLenInternal: int
    ## The maximum queue length

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

  isFinishedInternal: bool
    ## Internal property, see isFinished getter

  exceptionInternal: Option[ref Exception]
    ## Internal property, see exception getter

proc newAsyncBodyStream*(maxQueueLen: range[1..high(int)]): AsyncBodyStream =
  ## Creates a new AsyncBodyStream
  
  result = new AsyncBodyStream
  result.queue = initDeque[string](maxQueueLen)
  result.readCbs = initDeque[AsyncBodyCb](1)
  result.writeCbs = initDeque[AsyncBodyCb](1)
  result.isFinishedInternal = false
  result.exceptionInternal = none[ref Exception]()

func isFailed*(this: AsyncBodyStream): bool {.inline.} =
  ## Whether the stream is failed.
  ## If true, exception will be Some.
  
  return this.exceptionInternal.isSome

func isFinished*(this: AsyncBodyStream): bool {.inline.} =
  ## Whether the body stream is marked as finished (including if it was failed), and no more data will be written to it.
  ## Any data remaining in the queue can still be read if the stream was not failed, but no new data will be written.
  ## Additionally, any subsequent reads to the stream after the queue is empty will return None, indicating that the stream is finished.
  
  return this.isFinishedInternal or this.isFailed

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

proc `=maxQueueLen`*(this: AsyncBodyStream, newLen: range[1..high(int)]) {.inline.} =
  ## Sets the maximum queue length.
  ## Raises ValueError if the new length is less than the current queue length.
  ## Lowering queue size while a stream is active is dangerous because it can lower stream performance.
  ## Changing maximum queue length is expensive because it will result in memory allocation or deallocation.
  
  if unlikely(newLen < this.queue.len):
    raise newException(ValueError, "Cannot lower max queue length lower than the current queue size")

  this.maxQueueLenInternal = newLen

proc fail*(this: AsyncBodyStream, exc: ref Exception) {.inline.} =
  ## Fails the stream with an exception.
  ## All pending reads and writes will be immediately failed with the provided exception.
  
  when not defined(release):
    doAssert(not this.isFinished, "Tried to fail a stream that is already finished or failed")

  # Set exception
  this.exceptionInternal = some exc

  # Call remaining read and write callbacks now
  while this.readCbs.len > 0:
    let cb = this.readCbs.popFirst()
    cb()
  while this.writeCbs.len > 0:
    let cb = this.writeCbs.popFirst()
    cb()

proc write*(this: AsyncBodyStream, chunk: string): Future[void] =
  ## Tries to write to the stream, or raises ValueError if the stream is finished.
  ## If the stream is failed, the exception it failed with will be raised.
  ## If the queue is full, the returned Future will resolve when a queue slot becomes free, or when the stream is completed or failed.
  
  let resFut = newFuture[void]("AsyncBodyStream.write")

  proc mkFinishedExc(): ref Exception {.inline.} =
    newException(ValueError, "Cannot wrote to streams that are finished")

  # Do finished check immediately because the stream may be finished even if the queue is full.
  # If we only did this when there's a free queue slot, then the future would only fail due to the stream being finished after some data is read, instead of failing immediately.
  if this.isFinishedInternal:
    raise mkFinishedExc()

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
      raise this.exceptionInternal.unsafeGet()

    doWrite()
  else:
    # The queue is full; wait until there is a free slot, write to it, then complete future
    proc writeCb() {.closure, gcsafe.} =
      # Do necessary checks before writing
      if this.isFailed:
        resFut.fail(this.exceptionInternal.unsafeGet())
        return
      if this.isFinishedInternal:
        resFut.fail(mkFinishedExc())
        return
      
      # We don't need to check whether the queue is full, because this callback is called when a slot becomes free
      doWrite()

    # Add callback to be called when a slot becomes free
    this.writeCbs.addLast(writeCb)
  
  return resFut

proc read*(this: AsyncBodyStream): Future[Option[string]] =
  ## Reads from the stream
  
  let resFut = newFuture[Option[string]]("AsyncBodyStream.read")

  # TODO

  return resFut

proc complete(this: AsyncBodyStream) =
  ## Completes the stream
  
  when not defined(release):
    doAssert(this.exceptionInternal.isNone, "Tried to complete an already-failed stream")

  this.isFinishedInternal = true

  # Clear drain callback
  this.drainCb = none[AsyncBodyCb[void]]()

  # TODO Call remaining callbacks, make sure they're equipped to handle finished responses
  for cb in this.readCbs:
    cb(this)

  this.readCbs.clear()