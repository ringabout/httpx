# httpx
This project is based on Dom96's perfect work on [httpbeast](https://github.com/dom96/httpbeast) and adds windows support(based on `wepoll` namely IOCP).

It is also used by [prologue](https://github.com/planety/prologue).

## Installation

```
nimble install httpx
```

## Notes

Notes that multi-threads may be slower than single-thread!


## Usage

### Change server info name

```
-d:serverInfo:serverName
```

### Enable threads

```
--threads:on
```

## Hello world

```nim
import options, asyncdispatch

import httpx

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.send("Hello World")
    else:
      req.send(Http404)

run(onRequest)
```

## Websocket support
https://github.com/ringabout/websocketx

```
nimble install https://github.com/ringabout/websocketx
```
