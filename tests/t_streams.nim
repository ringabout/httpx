import std/[unittest, asyncdispatch, options]
import ../src/httpx/[streams]

const defaultStreamQueueLen = 4

const dummySource = @["abc", "def", "ghi"]

template asyncSuite(name: string, body: untyped) =
    ## Wrapper around `suite` that allows use of async/await

    suite name:
        # Dummy timer is required to make async work when no I/O is going on
        addTimer(0, false, proc (fd: AsyncFD): bool = false)

        proc main() {.async.} =
            body
        
        waitFor main()

asyncSuite "Streams can be written and read in order":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    await stream.completeWithAll(dummySource)

    let res = await stream.readAll()

    check(res == dummySource)
    
asyncSuite "Stream reads can wait on writes":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    proc slowWrite() {.async.} =
        for chunk in dummySource:
            await sleepAsync(1000)
            await stream.write(chunk)
        stream.complete()
    
    asyncCheck slowWrite()

    let res = await stream.readAll()

    check(res == dummySource)

asyncSuite "Stream writes can wait on reads":
    # Stream can't hold entire source
    var stream = newAsyncStream[string](dummySource.len - 1)

    var res = newSeq[string]()

    let readFinishFuture = newFuture[void]("main")

    proc slowRead() {.async.} =
        while true:
            await sleepAsync(1000)

            let chunk = await stream.read()

            if chunk.isSome:
                res.add(chunk.unsafeGet())
            else:
                break
        
        readFinishFuture.complete()

    # Start read loop before writing to avoid deadlock
    asyncCheck slowRead()

    # Write to entire stream
    await stream.completeWithAll(dummySource)

    # The write operation should only have had to wait 1 second since only one slot was missing, so the data should not have all been read yet
    check(res.len < dummySource.len)

    # Wait for read to finish
    await readFinishFuture

    check(res == dummySource)

# TODO Test reading queue after complete

# TODO Test reading queue after fail

# TODO Test writes fail on completed stream

# TODO Test reads on completed stream with empty queue

# TODO Test reads fail on failed stream with empty queue

# TODO Test writes fail on failed stream
