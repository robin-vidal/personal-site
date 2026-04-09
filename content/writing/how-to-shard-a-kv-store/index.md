---
title: "How to Shard a KV Store"
date: 2026-04-08
draft: false
tags: ["go", "distributed-systems", "concurrency", "performance"]
description: "Shard count, key routing, and what to defer: a practical walkthrough of the sharding decisions behind kvgo."
---

[kvgo](https://github.com/robin-vidal/kvgo) is a multithreaded, Redis-compatible KV store I'm building in Go. The first version was simple: a hash map behind a single lock. It worked, until I ran concurrent writes and watched every thread queue up waiting for access to the same structure.

This post walks through the three decisions that shaped the sharding architecture: how many shards, how to route keys, and what not to build yet.

All benchmarks below are SET-only workloads with random keys from a 1M key space, measured over 2 seconds on an 8-core machine.

## The Bottleneck

A naive KV store is a map behind a single mutex. Every operation, read or write, acquires that lock before touching the data.

On a single thread this is fine. But under concurrent load, threads pile up waiting for the lock even when they are operating on completely different keys. The lock becomes the bottleneck, and adding more CPU cores does not help:

{{< chart id="bottleneckChart" labels="1,2,4,8,16,32,64" x="concurrent workers" y="ops / sec" ymax="6000000" unit="ops/s" >}}
{
  label: 'single mutex',
  data: [2399158, 2171374, 2250882, 2239014, 2204556, 2070426, 2145718],
  borderDash: [6, 3]
}
{{< /chart >}}

Throughput stays flat around 2M ops/sec regardless of how many workers are running. The fix is sharding: split the map into N independent buckets, each with its own lock. Two writers hitting different keys in different shards no longer block each other.

## How Many Shards?

The idea is straightforward, but the first question is how many shards to create. Too few and you still get contention. Too many and you waste memory for negligible gain.

The natural anchor is the number of CPU cores. At peak concurrency, the OS can only run as many threads simultaneously as there are logical CPUs. One shard per core means that in the best case, every concurrent writer lands on a different shard with zero contention.

In kvgo, the shard count comes from a config value (defaulting to the number of cores). This keeps it easy to tune and benchmark with different values. Each shard holds its own map and its own `sync.RWMutex`, so reads can happen in parallel while writes get exclusive access per shard.

One detail worth noting: shards are stored as a slice of values (`[]databaseShard`), not a slice of pointers. This keeps them contiguous in memory and avoids an extra indirection on every operation.

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

I went with [FNV-64a](https://en.wikipedia.org/wiki/Fowler%E2%80%93Noll%E2%80%93Vo_hash_function) (Fowler-Noll-Vo, 64-bit alternate variant). It is fast, has excellent distribution for short string keys, and is built into Go's standard library. MD5 or SHA would work too, but cryptographic properties are overkill here.

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

This will change when kvgo gets Raft replication and nodes become dynamic. At that point `hash % n` breaks when `n` changes, and a virtual ring with vnodes becomes necessary.

## The Result

With all of this in place, here is the same benchmark again, this time comparing the single-mutex version against 8 shards:

{{< chart id="compChart" labels="1,2,4,8,16,32,64" x="concurrent workers" y="ops / sec" ymax="6000000" unit="ops/s" >}}
{
  label: 'single mutex',
  data: [2399158, 2171374, 2250882, 2239014, 2204556, 2070426, 2145718],
  borderDash: [6, 3]
},
{
  label: '8 shards',
  data: [2071924, 3178312, 4136862, 4306504, 4963470, 4981994, 5068701]
}
{{< /chart >}}

Sharding works. Throughput scales linearly up to 8 workers, which is both the number of shards and the number of cores on this machine. Past that point the CPU itself becomes the limit, not the locks.

Thanks for reading.

---

kvgo is on GitHub at [github.com/robin-vidal/kvgo](https://github.com/robin-vidal/kvgo). The sharding implementation is in `internal/database/database.go`.
