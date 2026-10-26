# Raptor

## A Ruby 4 Web Server

<img src="./assets/startup_output.svg" width="60%" align="right" alt="The README's complete Raptor startup output, including log prefixes, the process tree, and all ten worker boot messages." />

<img src="./assets/profile_picture.png" width="200" alt="Joshua Young" />

_Joshua Young ([`@joshuay03`](https://github.com/joshuay03))_

_Senior Software Engineer at [Buildkite](https://buildkite.com/)_

_[Rails](https://github.com/rails/rails) Issues team member_

_[Puma](https://github.com/puma/puma), [Concurrent Ruby](https://github.com/ruby-concurrency/concurrent-ruby), and [Vernier](https://github.com/jhawthorn/vernier) maintainer_

<hr width="35%" align="left">

_[BrisRails](https://luma.com/t3l24s8h) · August 2026_

_[Ruby Melbourne](https://www.meetup.com/ruby-melbourne/events/313408465/) · October 2026_

<br clear="all" />

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## How Raptor started

<big>Working on Puma made me curious about what a web server built around Ractors could look like.</big>

<big>That became Raptor. It runs Rack apps, Rails included, and parses HTTP in parallel using Ractors.</big>

<big>**Your app doesn't need to be Ractor-safe.** It runs on ordinary threads,
with the same thread-safety requirements as multithreaded Puma.</big>

<big>It's still young, and I'd love more people to try it on their apps and tell me what works and what doesn't.</big>

Today we'll look inside Raptor at its Ractors, lock-free queues, red-black trees,
shared memory, and a tiny program running inside Linux.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## What a web server actually does

[Rack](https://github.com/rack/rack) gives us a small boundary between the server and your app.

```ruby
# A complete Rack app. Nothing more is needed.
run ->(env) { [200, { "content-type" => "text/plain" }, ["hello\n"]] }
```

<big>Your app responds to `call`. It takes a request hash, the "Rack env", and returns `[status, headers, body]`.</big>

```mermaid
sequenceDiagram
    participant C as Client
    participant K as Kernel
    participant S as Web server
    participant A as Your Rack app

    C->>K: Open a TCP connection
    K->>S: accept() hands over a connected socket
    C->>S: GET /users/42 HTTP/1.1
    S->>S: Parse the bytes into a Rack env
    S->>A: app.call(env)
    A->>S: [200, headers, body]
    S->>C: HTTP/1.1 200 OK ...
    Note over C,S: Close, or keep the connection open for the next request
```

<big>The kernel handles TCP. The server handles HTTP.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The two servers you already know

**[Puma](https://github.com/puma/puma)**

<big>Worker processes, each with a pool of threads. It's HTTP/1.1 only, battle-tested, and the one I know best.</big>

**[Falcon](https://github.com/socketry/falcon)**

<big>Built on [`async`](https://github.com/socketry/async). It uses fibers instead of a thread pool, speaks HTTP/2, and is great at streaming.</big>

Fibers are another concurrency model. Raptor keeps your thread-safe Puma app on ordinary threads,
without requiring app changes.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The Ruby 4 opening

<big>Ractors have been around since Ruby 3.0, but the API kept changing, so most of us never touched them.</big>

<big>[Ruby 4.0](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/#ractor-improvements) introduced `Ractor::Port`.
Many Ractors can send to one receiver. A good fit for "many workers, one collector".</big>

<big>They're still marked experimental, but [Ruby 4.1 adds Ractor-local garbage collection](https://www.ruby-lang.org/en/news/2026/10/12/ruby-4-1-0-preview1-released/#ractor-improvements), so most collections no longer stop all the Ractors.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Ractors in one slide

Ruby threads normally share a Global VM Lock (GVL), so only one of them can run Ruby code at a time.

A Ractor is an isolated area of Ruby with **its own GVL**, so two Ractors can run Ruby on two cores at the same time.

The catch is isolation. A Ractor can't reach into its surroundings.

```ruby
data = { name: "hello" }

Ractor.new { puts data }
# Error: the block accesses an outer variable (data).
```

Instead, Ractors pass messages.

```ruby
port = Ractor::Port.new

worker = Ractor.new(port) do |port|
  loop { port.send("processed: #{Ractor.receive}") }
end

worker.send("hello")
port.receive # => "processed: hello"
```

<big>Shareable values, like deeply frozen arrays and hashes, are shared as is. Mutable values are copied, or moved with `move: true` so the sender can no longer use them.</big>

<big>Isolation keeps ordinary mutable objects from being changed by two Ractors at once.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## What Ractors are good for

They won't make your Rails app parallel on their own. Rails and many of its gems aren't Ractor-safe.

<big>They suit small, CPU-heavy jobs that are easy to hand off, without relying on global state or Ractor-unsafe gems.</big>

That describes HTTP parsing exactly.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The idea

In Puma, parsing and your app share the worker's GVL, even when they run on different threads.

If parsing runs in a Ractor instead, it gets its own GVL.

```mermaid
---
config:
    gantt:
        leftPadding: 220
---
gantt
    title One worker process, over time (illustrative)
    dateFormat x
    axisFormat %L ms

    section Puma (one GVL)
    Parse request A     :0, 2
    App handles A       :2, 8
    Parse request B     :8, 10
    App handles B       :10, 16

    section Raptor (app GVL)
    App handles A       :2, 8
    App handles B       :8, 14

    section Raptor (parser Ractor GVL)
    Parse request A     :0, 2
    Parse request B     :2, 4
```

<big>While your app handles request A, a Ractor is already parsing request B. Your app stays on normal threads, so it doesn't need to be Ractor-safe.</big>

If a whole request arrives in one read, Raptor skips the Ractor and parses it straight away.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Raptor at a glance

```mermaid
flowchart TB
    M["Master<br/>starts and watches workers"]

    subgraph W["Worker process (one of many)"]
        SRV["Server thread<br/>accepts sockets"]
        RCT["Reactor thread<br/>waits for bytes"]
        RP["Parser Ractors<br/>HTTP/1.1 and HTTP/2"]
        COL["Collector threads"]
        APP["App threads<br/>Rack + response"]

        SRV -->|"complete request"| APP
        SRV -->|"incomplete"| RCT
        RCT -->|"bytes"| RP
        RP --> COL
        COL -->|"ready"| APP
        COL -->|"incomplete"| RCT
    end

    M -->|"fork"| W
```

Let's walk through each piece.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The Ractor pools

Each protocol gets its own pool of parser Ractors.
With multiple parsers, a coordinator hands work to whichever is free.

```mermaid
sequenceDiagram
    box Main Ractor
        participant R as Reactor thread
        participant L as Collector thread
    end
    box Coordinator Ractor
        participant C as Coordinator thread
    end
    box One parser Ractor
        participant P as Parser thread
    end

    P->>C: "I'm free" (sends itself)
    R->>C: raw bytes for a connection
    C->>P: forward to the free parser
    P->>P: parse on its own GVL
    P->>L: parsed request via Ractor::Port
    P->>C: "I'm free" again
    L->>L: hand it to the app thread pool
```

<big>Idle parsers send **themselves** back to the coordinator, so it always knows who's free without polling or busy-waiting.</big>

<big>The parsers are Ractor-safe C extensions, and common header names are created once and reused.</big>

I pulled this pattern out into its own gem, **[`ractor-pool`](https://github.com/joshuay03/ractor-pool)**.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The app thread pool

This is where your Rack app runs.

Puma's work queue is guarded by a `Mutex`. Adding and taking work both acquire it.

Raptor's work queue has **no mutex**. To explain how, we need one tiny CPU instruction.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Compare-and-swap (CAS)

"Set this value to **new**, but only if it's still **expected**." The CPU does it as one indivisible step.

```mermaid
sequenceDiagram
    participant A as Thread A
    participant M as Memory holding count
    participant B as Thread B

    Note over M: count = 42
    A->>M: CAS(expected 42, new 43)
    M-->>A: ✅ swapped, count is now 43
    B->>M: CAS(expected 42, new 43)
    M-->>B: ❌ failed, count is 43 not 42
    B->>M: retry CAS(expected 43, new 44)
    M-->>B: ✅ swapped, count is now 44
```

<big>Nobody waits on a lock. The loser just retries with the fresh value.</big>

<big>The catch is that it works on one value at a time, like a counter, a flag, or the head of a queue.</big>

A mutex is still simpler for bigger critical sections. CAS pays off on hot paths.

I wrote a native gem that brings these primitives to Ruby, **[`atomic-ruby`](https://github.com/joshuay03/atomic-ruby)**.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## A queue with no lock

Raptor's work queue is [`atomic-ruby`](https://github.com/joshuay03/atomic-ruby)'s `AtomicQueue`, a lock-free linked list where each step is a single CAS.

**Adding work C**

```mermaid
flowchart LR
    H(["head"]) --> S["sentinel"] --> A["work A"] --> B["work B"]
    T(["tail"]) --> B
    B -. "① CAS links C after B" .-> C["work C"]
    T -. "② CAS moves tail" .-> C
```

**Taking work**

```mermaid
flowchart LR
    H(["head"]) --> S["sentinel"] --> A["work A"] --> B["work B"]
    H -. "CAS moves head to A, returns A's work<br/>(A becomes the new sentinel)" .-> A
```

<big>Adding and taking never block each other. If two threads race, one CAS wins and the other retries.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## No mutexes in Raptor's own code

There isn't a single `Mutex` in Raptor's own code. Shared state is either owned by one thread, passed along as a message, or updated with CAS.

That's not only about speed. Under the GVL, a thread can be switched out at almost any point,
including while it's holding a lock.

```mermaid
sequenceDiagram
    participant A as Thread A
    participant M as Mutex
    participant B as Thread B

    A->>M: lock
    Note over A: switched out while still holding it
    B->>M: lock
    Note over B: has to sleep, even though it's ready to run
    Note over A: scheduled again, eventually
    A->>M: unlock
    M-->>B: wake up and take the lock
```

<big>Now every thread that needs the lock is waiting on one that isn't even running.</big>

<big>CAS has nothing to hold. A thread switched out mid-update can't block anyone, and if it lost the race, it just retries.</big>

It also means there's no lock ordering to get wrong, removing one source of deadlocks.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## How many threads?

Thread counts are hard to tune. Too few leave requests queued. Too many can compete for the GVL.
The right count changes with the workload.

[`atomic-ruby`](https://github.com/joshuay03/atomic-ruby)'s pool uses CRuby's thread-event API
to measure time holding the GVL, waiting for it, and blocked outside it, such as during I/O.

It combines those timings with CPU time to decide whether more threads would help.

```mermaid
flowchart LR
    Q{"Work queued?"}
    Q -->|"yes"| W{"Where is time<br/>being spent?"}
    Q -->|"no"| I{"Queue empty<br/>for 5 seconds?"}
    W -->|"waiting on I/O<br/>(database, network)"| Add["Add more threads"]
    W -->|"Ruby CPU saturated"| Trim["Trim back towards<br/>the base size"]
    I -->|"no"| Stay["Keep the current size"]
    I -->|"yes"| Retire["Retire extra threads<br/>after their current work"]
```

<big>It starts at `threads` (3 per worker by default) and adapts to the workload,
with no hard maximum. You don't have to choose one fixed thread count.</big>

<big>Set `max_threads` to fit your database pool or other resource limits, or match `threads` for a fixed pool.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The reactor

Slow clients, half-sent requests, and idle keep-alive connections aren't ready to be read yet. The reactor watches all of them at once.

<big>Like Puma, it uses [`nio4r`](https://github.com/socketry/nio4r), backed by `epoll` on Linux
and `kqueue` on macOS.</big>

<big>The HTTP/1.1 defaults are 30 seconds for the first bytes,
10 seconds between request chunks, and 65 seconds idle on keep-alive.</big>

As bytes arrive, deadlines move. The reactor needs to keep **thousands of them in order**.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Keeping deadlines in order

**Puma** keeps an `Array` and sorts it after changes. Sorting is O(n log n), and removing a specific connection means scanning the whole list.

**Raptor** keeps a **red-black tree**, a binary search tree that rebalances itself as it changes.

```mermaid
flowchart TB
    R["deadline 100"] --> L["deadline 50"]
    R --> RR["deadline 150"]
    L --> LL["deadline 25<br/>(soonest, always the leftmost)"]
    L --> LR["deadline 75"]

    classDef black fill:#222,color:#fff,stroke:#000
    classDef red fill:#c62828,color:#fff,stroke:#8e0000
    class R,L,RR black
    class LL,LR red
```

<big>Inserting and removing are O(log n). Finding the soonest deadline is O(1), because it's cached.</big>

The reactor removes expired deadlines from the front. Keeping this cheap matters with thousands of connections.

That one became another gem, **[`red-black-tree`](https://github.com/joshuay03/red-black-tree)**.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Writing the response

Once your app returns, the response still has to become bytes on the socket.
Here's the common HTTP/1.1 path with an array body.

```mermaid
flowchart LR
    subgraph P["Puma"]
        direction TB
        PH["status line + headers<br/>(built in Ruby)"] --> PB["one buffer"]
        PBody["small body"] -->|"copied in"| PB
        PB -->|"write"| PS(["socket"])
    end

    subgraph R["Raptor"]
        direction TB
        RH["cached status line<br/>+ headers formatted in C"] --> RV["writev"]
        RBody["body"] --> RV
        RV -->|"headers + body together"| RS(["socket"])
    end

    P ~~~ R
```

<big>Puma formats headers in Ruby and copies small bodies into the same buffer. It asks the OS to batch separate writes.</big>

<big>Raptor formats headers in C. `writev` sends headers and body without joining them into one string, in one syscall when possible.</big>
<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## HTTP/2 in one slide

HTTP/1.1 sends one request at a time on a connection. HTTP/2 sends many at once,
split into small binary frames.

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server

    Note over C,S: All on one TCP connection
    C->>S: HEADERS (stream 1): GET /users
    C->>S: HEADERS (stream 3): GET /posts
    C->>S: HEADERS + DATA (stream 5): POST /log
    S->>C: HEADERS + DATA (stream 3): 200
    S->>C: HEADERS + DATA (stream 1): 200
    S->>C: HEADERS (stream 5): 201
```

<big>**Multiplexing** lets many requests share one connection. **Header compression** reuses earlier headers. **Flow control** limits how much data each side can send.</big>

Raptor speaks HTTP/2 natively, and so does Falcon. Puma [leaves it to a proxy](https://github.com/puma/puma/issues/2697) like nginx.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## HTTP/2 in Raptor

<big>HTTP/2 gets its own C parser and Ractor pool. Each stream is its own job, so one connection can use several app threads.</big>

<big>For established connections, the reactor owns socket writes. App threads queue frames rather than competing to write to the same socket.</big>

```mermaid
flowchart LR
    A1["App thread<br/>(stream 1)"] -->|"frames"| Q["Reactor's lock-free queue<br/>(AtomicQueue)"]
    A2["App thread<br/>(stream 3)"] -->|"frames"| Q
    A3["App thread<br/>(stream 5)"] -->|"frames"| Q
    Q --> R["Reactor writes<br/>when the socket is ready"]
    R --> S(["socket"])
```

<big>An ordinary response can still wait for HTTP/2 flow control. Long-lived streams need a way to release the app thread too.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Streams that outlive the request

SSE and gRPC responses can stay open for minutes. `Raptor::DetachedBody` lets them release the app thread.

```ruby
run ->(env) {
  body = Raptor::DetachedBody.new
  body.on_open { Subscribers.add(body) }
  body.on_close { Subscribers.remove(body) }
  [200, { "content-type" => "text/event-stream" }, body]
}
# Later, from any thread
Subscribers.each { |body| body.try_write("data: update\n\n") }
```

```mermaid
sequenceDiagram
    participant A as App thread
    participant R as Reactor thread
    participant P as Your publisher
    participant C as Client

    A->>R: hand over the headers and the body
    P->>R: try_write(message)
    R->>C: write when the socket is ready
    C--xR: client disconnects
    R->>A: schedule on_close on the app pool
```

<big>`try_write` never waits for the client. It returns `:accepted`, `:full` (no buffer space), or `:closed`. Your publisher decides whether to retry or drop an update.</big>

Cleanup runs on the app pool via `on_close`. This works over HTTP/1.1 and HTTP/2.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Enough HTTP/2 for gRPC

Raptor provides the HTTP/2 pieces for unary and server-streaming gRPC.
`DetachedBody` streams the response after the request body arrives in full.

```ruby
if body.try_write(encoded_message) == :accepted
  body.close(trailers: { "grpc-status" => "0" })
end # On :full, retry later rather than losing the message.
```

<big>**Trailers** carry gRPC's final status after the body. **Cancellation** closes abandoned streams, and **PINGs** help detect dead connections.</big>

<big>On shutdown, `GOAWAY` tells clients to stop opening streams while existing ones finish.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Zooming out to the processes

So far we've been inside one worker. Let's look at how the workers live together.

With **preforking**, the master loads your app once, then forks a copy for each worker.

```mermaid
flowchart TB
    M["Master<br/>loads your app once"] -->|"fork"| W0["Worker 0"]
    M -->|"fork"| W1["Worker 1"]
    M -->|"fork"| W2["Worker 2"]

    W0 -.-> SP[("Shared memory pages<br/>(your loaded app)")]
    W1 -.-> SP
    W2 -.-> SP
```

<big>Every worker starts out sharing the same memory, and a page is only copied when someone changes it. That's copy-on-write.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Refork

Copy-on-write savings fade as workers warm caches, compile YJIT code, and load gems lazily. Workers can lose much of that sharing as they warm up independently.

The fix is to fork replacement workers from a **warm** worker instead of the master.

```mermaid
sequenceDiagram
    participant M as Master
    participant W as Warm worker
    participant N as New workers

    Note over M: Warm worker reaches the configured request threshold
    M->>W: You're the seed now
    W->>W: Finish in-flight requests
    M->>W: Fork replacement workers
    W->>N: fork()
    Note over N: Start with the warm caches and YJIT code,<br/>shared copy-on-write
```

<big>The idea comes from Shopify's [Pitchfork](https://github.com/Shopify/pitchfork). Puma has experimental `fork_worker` support too.</big>

<big>I recently added [`mold_worker`](https://github.com/puma/puma/pull/4038) on Puma's main branch. Like Raptor's seed, the mold stops serving requests and only forks replacements.</big>

Raptor uses Linux's `PR_SET_CHILD_SUBREAPER` so the master can adopt workers it didn't fork.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Shared memory for stats

The master needs to know how each worker is doing. Puma's workers report through pipes, while Raptor's write straight into shared memory.

```mermaid
flowchart LR
    W0["Worker 0"] -->|"writes"| S0
    W1["Worker 1"] -->|"writes"| S1
    W2["Worker 2"] -->|"writes"| S2

    subgraph SHM["Shared memory, created before forking"]
        S0["slot 0"]
        S1["slot 1"]
        S2["slot 2"]
    end

    S0 -.->|"reads"| M["Master"]
    S1 -.-> M
    S2 -.-> M
```

<big>The master creates the region with `mmap` before forking, so every worker inherits it. Each worker owns one 49-byte slot, so writes never clash.</big>

<big>Updating stats is a write to shared memory, with no pipe or syscall to send the update.</big>

That's where **[`mmap-ruby`](https://github.com/joshuay03/mmap-ruby)** came from.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Which worker gets the next connection?

With Linux's `SO_REUSEPORT`, workers get separate listeners on the same port. The kernel hashes connection details to pick one, without knowing which workers are busy.

In Puma, busier workers pause briefly before accepting new connections. This gives less busy workers more chance to accept them.

On Linux, Raptor can use **BPF** to route plain TCP connections using real load.

<big>BPF lets you run tiny, kernel-verified programs inside Linux. It's the same technology behind `bpftrace` and Cilium.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Raptor's BPF program

```mermaid
flowchart LR
    New(["new connection"]) --> Hash["hash picks two workers"]
    Hash --> A["Worker 0<br/>load 5"]
    Hash --> B["Worker 3<br/>load 6"]
    A --> Pick{"pick the less busy one"}
    B --> Pick
    Pick -->|"reserve 5 → 6"| W0["Worker 0 accepts it"]
```

<big>A kernel-readable map tracks each worker's load, including pending connections.
The program compares two workers and picks the quieter one.</big>

<big>Checking every worker adds work to every connection. The "power of two choices"
helps avoid busy workers without scanning the whole cluster.</big>

It reserves the connection straight away, so the next arrival sees the updated load.

The program is about 70 lines of C, loaded through **[`libbpf-ruby`](https://github.com/joshuay03/libbpf-ruby)**.
Without the optional dependencies, Raptor uses normal listeners.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Pinning workers to cores

Moving workers between cores can lose warm CPU caches.

<big>On Linux, `cpu_affinity` pins workers to cores when enough are available.
Puma doesn't have a built-in setting for this.</big>

<big>It's opt-in, because a pinned worker's threads and Ractors share one core.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The numbers over HTTP/1.1 without keep-alive

Scaling uses 3–16 threads per worker. Fixed uses 3. Falcon uses unbounded fibers.

**I/O-bound requests**

<big>With scaling threads, Raptor matches Puma on throughput and p95.
Falcon has 38% higher throughput than Raptor, with lower p95.
With 3 fixed threads, Raptor has over twice Puma's throughput.</big>

**CPU-bound requests**

<big>With scaling threads, Raptor gets about 23% more throughput than Puma, with 10% higher p95.
With 3 fixed threads, the throughput lead is 10%. Falcon leads on both metrics.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The numbers over HTTP/1.1 keep-alive

Scaling uses 3–16 threads per worker. Fixed uses 3. Falcon uses unbounded fibers.

**I/O-bound requests**

<big>With scaling threads, Raptor matches Puma and Falcon on throughput and p95.
With 3 fixed threads, Raptor has over twice Puma's throughput.</big>

**CPU-bound requests**

<big>With scaling threads, Raptor gets 7% more throughput and 20% lower p95 than scaling Puma.
With 3 fixed threads, Puma leads on both metrics.
Falcon has higher throughput, but Raptor's p95 is lower.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## The numbers over HTTP/2

Raptor vs Falcon. Puma has no native HTTP/2.

**I/O-bound requests**

<big>With scaling threads, Raptor matches Falcon's throughput, with p95 around 30 ms versus 27 ms.
With 3 fixed threads, throughput is 78% lower than Falcon.</big>

**CPU-bound requests**

<big>With scaling threads, Raptor gets 21% more throughput than Falcon at about half the p95.
With 3 fixed threads, the throughput lead is 33%.</big>

Full results and the setup are in the [README](../README.md#micro-benchmarks).

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## What you give up

<big>Raptor has less **battle-testing**. Puma has years of production Rails use. Raptor is less than a year old.</big>

<big>It needs **Ruby 4.0 or newer**. Ractors add overhead on 4.0 that I don't see in my 4.1 measurements.</big>

<big>**Debugging server internals** can involve tracing work across threads and Ractors.
Most app developers won't need to do that. Your app stays on ordinary threads.</big>

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Why it's worth being curious

I'd love you to try Raptor, but I also hope you leave curious about what's possible from Ruby now.

<big>Raptor combines Ractors, lock-free queues, shared memory, and BPF in one Rack server.</big>

<big>Let the pool adapt instead of choosing one fixed thread count.
Your app still runs on ordinary Rack threads.</big>

In these tests, scaling threads match Falcon's I/O throughput over keep-alive HTTP/1.1 and HTTP/2.

<big>Native HTTP/2 and detached streaming are there when you need them.</big>

Try your own workload to see how these pieces work together.

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Try it

```
bundle add raptor            # Ruby 4.0+
bundle exec raptor           # boots config.ru
bundle exec rails server -u raptor
```

<big>The CLI mirrors Puma's on purpose. Try it on your app.
Feedback and bug reports are very welcome.</big>

Test your real traffic, then try a small production canary with an easy way back to Puma.

For a detailed comparison of Raptor and Puma's designs, see [`docs/raptor-vs-puma.md`](raptor-vs-puma.md).

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

---

<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>

## Thanks

**Raptor**

[github.com/joshuay03/raptor](https://github.com/joshuay03/raptor)

**The gems that came out of it**

[`ractor-pool`](https://github.com/joshuay03/ractor-pool) provides Ractor workers.

[`atomic-ruby`](https://github.com/joshuay03/atomic-ruby) provides lock-free primitives and the thread pool.

[`red-black-tree`](https://github.com/joshuay03/red-black-tree) keeps deadlines in order.

[`mmap-ruby`](https://github.com/joshuay03/mmap-ruby) provides shared memory.

[`libbpf-ruby`](https://github.com/joshuay03/libbpf-ruby) loads BPF programs from Ruby.

_Questions?_
