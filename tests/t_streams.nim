import std/[unittest, asyncdispatch, options]
import ../src/httpx/asyncstream

type DummyError = object of CatchableError

func newDummyError(): ref DummyError =
    newException(DummyError, "Dummy stream error")

const defaultStreamQueueLen = 4

const dummySource = @["abc", "def", "ghi"]

const skipSlowTests {.booldefine.} = false
    ## Set this to true to skip slow tests.
    ## Only useful when you're writing tests and don't want to wait for slow ones to complete while making your own.

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

when not skipSlowTests:
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
            var chunk: Option[string]

            while true:
                await sleepAsync(1000)

                chunk = await stream.read()

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
    
    asyncSuite "Throughput test":
        let testSeconds = 10

        var stream = newAsyncStream[string](defaultStreamQueueLen)

        var writeCounter = 0
        var readCounter = 0

        proc writer() {.async.} =
            try:
                while true:
                    await stream.write("count" & $writeCounter)
                    writeCounter += 1
            except ValueError:
                break
        
        proc reader() {.async.} =
            var chunkRes: Option[string]

            while true:
                # Allow asyncdispatch to poll
                await sleepAsync(0)

                chunkRes = await stream.read()

                if chunkRes.isNone:
                    break
                
                readCounter += 1
        
        addTimer(testSeconds * 1_000, false, proc (fd: AsyncFD): bool = stream.complete())

        asyncCheck writer()
        await reader()

        echo "Tested throughput for ", testSeconds, "s"
        echo "Writes: ", writeCounter
        echo "Reads: ", readCounter


asyncSuite "Stream reads to a completed stream return None":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    stream.complete()

    let res = await stream.read()

    check(res == none[string]())

asyncSuite "Reading failed stream raises exception":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    stream.fail(newDummyError())

    var caughtErr = false

    try:
        discard await stream.read()
    except DummyError:
        caughtErr = true

    require(caughtErr)

asyncSuite "Writing to a completed stream rauses exception":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    stream.complete()

    var caughtErr = false

    try:
        await stream.write("chunk")
    except ValueError:
        caughtErr = true
    
    require(caughtErr)

asyncSuite "Writing to a failed stream raises exception":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    stream.fail(newDummyError())

    var caughtErr = false

    try:
        await stream.write("chunk")
    except DummyError:
        caughtErr = true
    
    require(caughtErr)

asyncSuite "Can read queued chunks from completed stream":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    const sourceChunk = "chunk"

    await stream.completeWith(sourceChunk)
    
    let resChunk1 = await stream.read()
    let resChunk2 = await stream.read()

    check(resChunk1 == some sourceChunk)
    check(resChunk2 == none[string]())

asyncSuite "Can read queued chunks from failed stream, then raise exception":
    var stream = newAsyncStream[string](defaultStreamQueueLen)

    await stream.writeAll(dummySource)
    stream.fail(newDummyError())

    var res = newSeqOfCap[string](dummySource.len)
    var caughtErr = false

    try:
        var chunk: Option[string]

        while true:
            chunk = await stream.read()
            require(chunk.isSome)
            res.add(chunk.unsafeGet())
    except DummyError:
        caughtErr = true
    
    check(res == dummySource)
    require(caughtErr)
