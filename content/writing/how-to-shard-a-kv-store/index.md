---
title: "How to Shard a KV Store"
date: 2026-04-08
draft: false
tags: ["go", "distributed-systems", "concurrency", "performance"]
description: "Shard count, key routing, and what to defer: a practical walkthrough of the sharding decisions behind kvgo."
---

kvgo is a multithreaded, Redis-compatible KV store I'm building in Go. The first version was simple: a hash map behind a single lock. It worked, until I ran concurrent writes and watched every thread queue up waiting for access to the same structure.

This post walks through the three decisions that shaped the sharding architecture: how many shards, how to route keys, and what not to build yet.

These are in-process numbers: goroutines calling the sharded map directly, with no TCP. They isolate lock behaviour, so read them as such rather than as kvgo's throughput. Over the wire the same box serves about 180k reads per second, and writes land well below that, bound by durability rather than by locking.

All benchmarks below are `SET`-only workloads with pre-generated keys from a 1M key space, on a 10-core Linux box. Each point is the median of 10 runs of 500k operations.

## The Bottleneck

A naive KV store is a map behind a single mutex. Every operation, read or write, acquires that lock before touching the data.

On a single thread this is fine. But under concurrent load, threads pile up waiting for the lock even when they are operating on completely different keys. The lock becomes the bottleneck, and adding more CPU cores does not help:

{{< chart id="bottleneckChart" labels="1,2,4,8,16,32,64" x="concurrent workers" y="ops / sec" ymax="4500000" unit="ops/s" >}}
{
  label: 'single mutex',
  data: [2536511, 1847578, 1755190, 1685488, 1680981, 1725182, 1702716],
  borderDash: [6, 3]
}
{{< /chart >}}

Throughput drops the moment a second worker shows up, from 2.5M ops/sec down to 1.8M, and stays there no matter how many more you add. Every worker past the first spends its time queueing rather than working. The fix is sharding: split the map into N independent buckets, each with its own lock. Two writers hitting different keys in different shards no longer block each other.

## How Many Shards?

The idea is straightforward, but the first question is how many shards to create. Too few and you still get contention. Too many and you waste memory for negligible gain.

The natural anchor is the number of CPU cores. At peak concurrency, the OS can only run as many threads simultaneously as there are logical CPUs. One shard per core means that in the best case, every concurrent writer lands on a different shard with zero contention.

That best case is a floor, not a target. With random keys, two of eight writers landing on the same one of eight shards is not the exception but the rule, and the benchmark at the end of this post has 32 shards beating 8 on the same ten cores.

In kvgo, the shard count comes from a config value, defaulting to the number of cores, which keeps it easy to tune and benchmark. On the evidence below that default is too low, and I intend to raise it. Each shard holds its own map and its own `sync.RWMutex`, so reads can happen in parallel while writes get exclusive access per shard.

```go
type databaseShard struct {
    mu   sync.RWMutex
    data map[string]string
}

type Database struct {
    shards []databaseShard
}

func New(cfg *config.Config) *Database {
    db := &Database{
        shards: make([]databaseShard, cfg.ShardAmount),
    }
    for i := 0; i < cfg.ShardAmount; i++ {
        db.shards[i].data = make(map[string]string)
    }
    return db
}
```

The shard count is fixed at startup. Since kvgo runs on a single node, there is no resharding at runtime, so a static count is the right call.

## How to Route Keys

With shards in place, every operation needs to find the right shard for a given key. The requirements are simple: fast, uniform distribution, deterministic.

I went with FNV-64a. It is fast, has excellent distribution for short string keys, and is built into Go's standard library. MD5 or SHA would work too, but cryptographic properties are overkill here.

```go
func getShard(key string, shardAmount int) int {
    hasher := fnv.New64a()
    hasher.Write([]byte(key))
    return int(hasher.Sum64() % uint64(shardAmount))
}
```

Every operation calls `getShard` to find the right bucket, then locks only that shard. A write takes an exclusive lock, a read takes a shared one. Putting it all together, the full flow looks like this:

{{< figure src="kvgo-sharded.png" >}}

Here is the distribution across 8 shards on a workload of 100k keys with common prefixes and sequential suffixes (`user:0`, `user:1`, ..., `session:0`, etc.):

{{< chart id="distChart" type="bar" labels="0,1,2,3,4,5,6,7" x="shard" y="keys" ymax="15000" >}}
{
  label: 'keys per shard',
  data: [12438, 12587, 12526, 12491, 12553, 12472, 12509, 12424]
}
{{< /chart >}}

The distribution stays close to uniform even with structured key patterns. No shard is starved, no shard is overloaded.

## Why Not Consistent Hashing?

Consistent hashing is designed for dynamic clusters. Cassandra and DynamoDB use it so that when a node joins or leaves, only a fraction of keys need to move. In kvgo, the shard count is fixed at startup and nothing joins or leaves at runtime. `hash % n` is simpler and does the job.

What would change the answer is splitting the keyspace across several machines that come and go, the way TiKV and CockroachDB split data into ranges. There, `n` changes at runtime and `hash % n` remaps almost every key each time it does, so a ring with vnodes earns its place. That is a distribution problem, not a locking one.

## The Result

With all of this in place, here is the same benchmark again, this time comparing the single-mutex version against 8 and 32 shards:

{{< chart id="compChart" labels="1,2,4,8,16,32,64" x="concurrent workers" y="ops / sec" ymax="4500000" unit="ops/s" >}}
{
  label: 'single mutex',
  data: [2536511, 1847578, 1755190, 1685488, 1680981, 1725182, 1702716],
  borderDash: [6, 3]
},
{
  label: '8 shards',
  data: [2536789, 2115305, 2084147, 2211046, 2487386, 2934986, 3247284]
},
{
  label: '32 shards',
  data: [2508151, 2431019, 2234150, 2700516, 3098551, 3601657, 3832942]
}
{{< /chart >}}

Sharding works, and it works in the direction the single lock refuses to go: throughput climbs with concurrency instead of collapsing. At 64 workers, 8 shards nearly doubles the single lock, 3.2M against 1.7M ops/sec.

The gap between 8 and 32 shards is the more interesting one. Take the 8 worker point: 8 shards gives 2.2M ops/sec, 32 shards gives 2.7M on the same hardware, and the gap widens from there. One shard per core sounds like enough, but with random keys it is not. With 8 writers on 8 shards, the odds that no two land on the same shard are about 0.24%. Collisions are the rule, not the exception, and the cure is simply to have more shards than cores.

Thanks for reading :)

---

kvgo is on GitHub at [github.com/robin-vidal/kvgo](https://github.com/robin-vidal/kvgo). The sharding implementation is in `internal/database/database.go`.
