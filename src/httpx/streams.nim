# Because asyncstreams is too dangerous to use due to having no mechanism for limiting the maximum queue size
# TODO

import std/[deques]

type
  BodyStream* = ref object
    queue: Deque[string]
    finished: bool
    cb: proc () {.closure, gcsafe.}
    error*: ref Exception

# TODO Do we REALLY need this?
