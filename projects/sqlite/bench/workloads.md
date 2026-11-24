# Workloads

Both sides (bench/sqlite.mjs, bench/wac.wac) run these in this order on the same generated data, time
each from inside the program, and print a digest of every row each query answered, so a fast wrong
answer shows up as a different digest.

Data: `events` is autonag's events table (text primary key, `UNIQUE (instance_id, seq)`, an index on
`(instance_id, seq)`), N rows over 8 instances; `instances` has those 8 rows.
Row i: id `e<i>`, instance `i<i % 8>`, seq `i / 8 + 1`, type one of 6 by `i % 6`, payload
`{"id":"t<i % 97>","n":<i>}`, timestamp `1700000000000 + i * 7`.
