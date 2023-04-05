## Asynchronous stream implementation used by the server.
## For a description of how the stream works, see documentation on the AsyncStream type.

import std/[deques, asyncdispatch, options]

type AsyncStreamCb* = proc () {.closure, gcsafe.}
  ## A GC-safe closure callback used for AsyncStream

type AsyncStream*[T] = ref object
  ## # Description
  ## An async stream backed by an internal queue.
  ## Uses an internal queue of items with a maximum length.
  ## 
  ## ## Behavior of streams with full or empty queues
  ## Writes to a full queue will not complete until at least 1 slot becomes available.
  ## Reads to an empty queue will not complete until at least 1 item is written.
  ## 
  ## ## Behavior of finished/completed/failed streams
  ## A stream is considered to be **finished** if it was **completed** or **failed**.
  ## 
  ## If a stream is finished and still has items in its queue, the remaining items can be read, but no new items can be written.
  ## Subsequent reads to a completed stream with an empty queue will immediately return None.
  ## Subsequent reads to a failed stream with an empty queue will immediately raise the exception that the stream was failed with.
  ## 
  ## If a stream is failed, all pending writes will immediately raise the exception that was used to fail the stream.
  ## Subsequent writes to it will also raise the exception.
  ## 
  ## The general concept around finished streams is that queued items can be read without any unexpected behavior, but writes cannot be performed.
  ## The reasoning behind this design is that consumers should be able to read the entire stream up until the point where it was completed or failed.
  
  queue: Deque[T]
    ## The data queue
  
  maxQueueLenInternal: int
    ## Internal property, see maxQueueLen getter

  readCbs: Deque[AsyncStreamCb]
    ## Callbacks to be called when the queue has new data to read.
    ## There is one callback per queue item, and callbacks are called in the order that they were registered.
    ## 
    ## Example scenario:
    ## The queue is empty.
    ## Proc 1 registers cb 1, and then proc 2 registers cb 2.
    ## 3 items are received.
    ## cb 1 is called for the first item, then cb 2 is called for the second item, finally the third item remains in the queue, ready to be read later.
    ## 
    ## All remaining callbacks will be called when the stream is finished.

  writeCbs: Deque[AsyncStreamCb]
    ## Callbacks to be called when the queue was full but now has a slot free.
    ## There is one callback per queue free slot, and callbacks are called in the order that they were registered.
    ## 
    ## Example scenario:
    ## The queue is full.
    ## Proc 1 registers cb 1, and then proc 2 registers cb 2.
    ## 3 items are read, and therefore those 3 slots become available.
    ## cb 1 is called for the first slot, then cb 2 is called for the second slot, finally the third slot remains free, ready to be written to later.
    ## 
    ## All remaining callbacks will be called when the stream is finished.

  afterReadCb: Option[AsyncStreamCb]
    ## Optional callback to be called after every read.
    ## Note that the read will already have been performed once this callback is called, and thus the queue will have already been modified.
  
  afterWriteCb: Option[AsyncStreamCb]
    ## Optional callback to be called after every write.
    ## Note that the write will already have been performed once this callback is called, and thus the queue will have already been modified.

  isCompletedInternal: bool
    ## Internal property, see isCompleted getter

  exceptionInternal: Option[ref Exception]
    ## Internal property, see exception getter

proc newAsyncStream*[T](
  maxQueueLen: range[1..high(int)],
  afterReadCb: Option[AsyncStreamCb] = none[AsyncStreamCb](),
  afterWriteCb: Option[AsyncStreamCb] = none[AsyncStreamCb](),
): AsyncStream[T] =
  ## Creates a new AsyncStream.
  ## 
  ## Arguments:
  ##  - `maxQueueLen`: The maximum queue length to use
  ##  - `afterReadCb`: Optional callback to be called after every read (defaults to None)
  ##  - `afterWriteCb`: Optional callback to be called after every write (defaults to None)

  result = new AsyncStream[T]
  result.queue = initDeque[T](maxQueueLen)
  result.maxQueueLenInternal = maxQueueLen
  result.readCbs = initDeque[AsyncStreamCb](1)
  result.writeCbs = initDeque[AsyncStreamCb](1)
  result.afterReadCb = afterReadCb
  result.afterWriteCb = afterWriteCb
  result.isCompletedInternal = false
  result.exceptionInternal = none[ref Exception]()

func isCompleted*[T](this: AsyncStream[T]): bool {.inline.} =
  ## Whether the stream is completed.
  ## If true, exception will be None.
  
  return this.isCompletedInternal

func isFailed*[T](this: AsyncStream[T]): bool {.inline.} =
  ## Whether the stream is failed.
  ## If true, exception will be Some.
  
  return this.exceptionInternal.isSome

func isFinished*[T](this: AsyncStream[T]): bool {.inline.} =
  ## Whether the stream is either completed or failed.
  ## To check each individually, use isCompleted and isFailed, respectively.
  
  return this.isCompleted or this.isFailed

func exception*[T](this: AsyncStream[T]): Option[ref Exception] {.inline.} =
  ## The exception that was the cause of the stream failing to be written/read, or none if there was no exception.
  ## If an exception is present, any reads to the stream when the queue is empty will raise this exception.
  ## The isFinished property should be true if this is some.
  
  return this.exceptionInternal

func queueLen*[T](this: AsyncStream[T]): int {.inline.} =
  ## The current internal queue length

  return this.queue.len

func maxQueueLen*[T](this: AsyncStream[T]): int {.inline.} =
  ## The maximum queue length
  
  return this.maxQueueLenInternal

func queue*[T](this: AsyncStream[T]): Deque[T] {.inline.} =
  ## The internal queue.
  ## 
  ## Warning: modifying the queue manually while there are pending reads or writes will cause a deadlock until a new read/write occurs.
  ## Exercise caution when modifying it!

proc `=maxQueueLen`*[T](this: AsyncStream[T], newLen: range[1..high(int)]) {.inline.} =
  ## Sets the maximum queue length.
  ## Raises ValueError if the new length is less than the current queue length.
  ## Lowering queue size while a stream is active is dangerous because it can lower stream performance.
  ## Changing maximum queue length is expensive because it will result in memory allocation or deallocation.
  
  if unlikely(newLen < this.queue.len):
    raise newException(ValueError, "Cannot lower max queue length lower than the current queue size")

  this.maxQueueLenInternal = newLen

proc write*[T](this: AsyncStream[T], item: sink T, prepend: bool|void = void): Future[void] =
  ## Tries to write the provided item to the stream, or raises ValueError if the stream is finished.
  ## If the stream is failed, the exception it failed with will be raised.
  ## If the queue is full, the returned Future will resolve when a queue slot becomes free, or when the stream is completed or failed.
  ## 
  ## If `prepend` is true, the item will be prepended to the queue instead of appended.
  ## Use this only if you need to return an item to the queue after reading it.
  ## In most cases, you will not need to use `prepend`.
  
  let resFut = newFuture[void]("AsyncStream.write")

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
    # Add item to queue and complete future
    when prepend is bool:
      if prepend:
        this.queue.addFirst(item)
      else:
        this.queue.addLast(item)
    else:
      this.queue.addLast(item)

    resFut.complete()

    # If there is a read callback, run it now
    if this.readCbs.len > 0:
      let cb = this.readCbs.popFirst()
      cb()
    
    # Call afterWriteCb if present
    if this.afterWriteCb.isSome:
      let cb = this.afterWriteCb.unsafeGet()
      cb()

  # Check if the queue is full
  if this.queueLen < this.maxQueueLen:
    # The queue has at least 1 free slot; add the item to the queue and complete the future (assuming the stream isn't failed).

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

proc writeAll*[T](this: AsyncStream[T], items: seq[T]) {.async, inline.} =
  ## Tries to write the provided items to the stream.
  ## See docs on the `write` proc.
  
  for item in items:
    await this.write(item)

proc read*[T](this: AsyncStream[T]): Future[Option[T]] =
  ## Reads from the stream.
  ## If the stream is complete, None is returned.
  
  let resFut = newFuture[Option[T]]("AsyncStream.read")

  template failAndReturn(exc: ref Exception, inCb: bool = false) =
    resFut.fail(exc)
    when inCb:
      return
    else:
      return resFut
  
  template complAndReturn(val: Option[T], inCb: bool = false) =
    resFut.complete(val)
    when inCb:
      return
    else:
      return resFut

  template doRead() =
    # Add item to queue and complete future
    let item = this.queue.popFirst()
    resFut.complete(some item)

    # If there is a write callback, run it now
    if this.writeCbs.len > 0:
      let cb = this.writeCbs.popFirst()
      cb()
    
    # Call afterReadCb if present
    if this.afterReadCb.isSome:
      let cb = this.afterReadCb.unsafeGet()
      cb()

  # Check if the queue is empty
  if this.queueLen > 0:
    # The queue has at least 1 item; read the item and complete the future

    doRead()
  elif this.isCompleted:
    # The queue is empty and the stream is completed; complete the future with None
    complAndReturn(none[T]())
  else:
    # The queue is empty; wait until there is an item, read it, then complete future (assuming the stream hasn't been failed)

    # Do fail check immediately, otherwise a failed stream with no data will hang forever
    if this.isFailed:
      failAndReturn(this.exceptionInternal.unsafeGet())

    proc readCb() {.closure, gcsafe.} =
      # Do necessary checks before reading
      if this.isFailed:
        failAndReturn(this.exceptionInternal.unsafeGet(), inCb = true)
      if this.isCompleted and this.queueLen < 1:
        complAndReturn(none[T](), inCb = true)
      
      # We don't need to check whether the queue is empty because this callback is only called when an item is written
      doRead()

    # Add callback to be called when an item is written
    this.readCbs.addLast(readCb)
  
  return resFut

proc readAll*[T](this: AsyncStream[T], expectedLen: Natural = 0): Future[seq[T]] {.async, inline.} =
  ## Reads the entire stream into a seq and returns it.
  ## Note that this proc will use as much memory as the entire result of the stream.
  ## For very large streams or streams of unknown length, this can cause memory exhaustion.
  ## 
  ## If you have an expected stream length, you can provide it as `expectedLen` so that the memory for the seq can be allocated up-front.
  ## Note that this length represents the number of items, not the length of the stream result in bytes.
  ## 
  ## See docs on the `read` proc.
  
  var res = newSeq[T](expectedLen)

  while true:
    let item = await this.read()

    if item.isSome:
      res.add(item.unsafeGet())
    else:
      break
  
  return res

proc readToString*[T: string|char](this: AsyncStream[T], expectedLen: Natural = 0): Future[string] {.async.} =
  ## Reads the entire stream into a string and returns it.
  ## Note that this proc will use as much memory as the entire result of the stream.
  ## For very large streams or streams of unknown length, this can cause memory exhaustion.
  ## 
  ## If you have an expected stream result length in bytes, you can provide it as `expectedLen` so that the memory for the string can be allocated up-front.
  ## 
  ## See docs on the `read` proc.

  var res = newStringOfCap(expectedLen)

  while true:
    let item = await this.read()

    if item.isSome:
      res.add(item.unsafeGet())
    else:
      break
  
  return res

proc complete*[T](this: AsyncStream[T]) =
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

proc completeWith*[T](this: AsyncStream, item: T) {.async, inline.} =
  ## Writes the provided item and then completes the stream.
  ## See docs on the `complete` proc.
  
  await this.write(item)
  this.complete()

proc completeWithAll*[T](this: AsyncStream, items: seq[T]) {.async, inline.} =
  ## Writes the provided items and then completes the stream.
  ## See docs on the `complete` proc.
  
  await this.writeAll(items)
  this.complete()

proc fail*(this: AsyncStream, exc: ref Exception) =
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
