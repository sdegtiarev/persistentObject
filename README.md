# persistentObject

Creates an object mapped to a file. The object is persistent and outlives the parent application. The file may be reopened and the object reused, it's value persists. This might be viewed as kind of binary serialization with the difference that access to the variable is almost as fast as any regular memory. The structure might be also used as memory shared between processes/threads, however, no built-in synchronization is provided. 
